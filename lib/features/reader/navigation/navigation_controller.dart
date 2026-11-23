import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/providers.dart';
import '../../../core/log.dart';
import '../../library/library_controller.dart';
import '../../library/models.dart';
import '../../settings/settings_controller.dart';
import '../markdown/md_model.dart';
import '../markdown/md_parser.dart';

enum AppView { home, reader, settings }

class PageData {
  PageData({
    required this.lib,
    required this.version,
    required this.page,
    required this.doc,
    required this.filePath,
    required this.lang,
    required this.originalMissing,
    this.meta,
  });

  final Library lib;
  final LibraryVersion version;
  final String page;
  final MdDocument doc;
  final String filePath;

  /// 'zh' or 'original'.
  final String lang;

  /// Original requested but not available; showing Chinese.
  final bool originalMissing;
  final PageMeta? meta;

  String get title =>
      (doc.frontMatter['title']?.toString()) ?? meta?.title ?? version.titleOf(page) ?? p.basenameWithoutExtension(page);

  String? get sourceUrl => doc.frontMatter['source_url']?.toString() ?? meta?.sourceUrl;
  String? get fetchedAt => doc.frontMatter['fetched_at']?.toString() ?? meta?.fetchedAt;
}

/// Where the reader should scroll after a page is shown.
class ScrollRequest {
  ScrollRequest({this.anchor, this.line, this.ratio, this.blockIndex, this.highlight});

  final String? anchor;
  final int? line;
  final double? ratio;
  final int? blockIndex;
  final String? highlight;
  final int token = _next++;
  static int _next = 0;
}

class NavState {
  const NavState({
    this.view = AppView.home,
    this.location,
    this.page,
    this.loading = false,
    this.error,
    this.scroll,
    this.canBack = false,
    this.canForward = false,
    this.settingsSection,
  });

  final AppView view;
  final DocLocation? location;
  final PageData? page;
  final bool loading;
  final String? error;
  final ScrollRequest? scroll;
  final bool canBack;
  final bool canForward;
  final String? settingsSection;

  NavState copyWith({
    AppView? view,
    DocLocation? location,
    PageData? page,
    bool? loading,
    String? error,
    ScrollRequest? scroll,
    bool? canBack,
    bool? canForward,
    String? settingsSection,
    bool clearError = false,
  }) =>
      NavState(
        view: view ?? this.view,
        location: location ?? this.location,
        page: page ?? this.page,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        scroll: scroll ?? this.scroll,
        canBack: canBack ?? this.canBack,
        canForward: canForward ?? this.canForward,
        settingsSection: settingsSection ?? this.settingsSection,
      );
}

class _Entry {
  _Entry(this.view, [this.loc]);
  final AppView view;
  DocLocation? loc;
}

final navigationProvider = NotifierProvider<NavigationController, NavState>(NavigationController.new);

/// Current location, history stacks and reading-position persistence.
class NavigationController extends Notifier<NavState> {
  final List<_Entry> _back = [];
  final List<_Entry> _forward = [];
  _Entry _current = _Entry(AppView.home);

  /// Latest reading position reported by the reader.
  String? _posAnchor;
  double _posRatio = 0;
  int? _posBlock;
  Timer? _saveTimer;

  @override
  NavState build() {
    ref.listen(settingsProvider.select((s) => s.language), (a, b) {
      if (a != b) reloadCurrent(keepPosition: true);
    });
    ref.listen(libraryProvider.select((s) => s.generation), (a, b) => _onLibrariesChanged());
    ref.onDispose(() => _saveTimer?.cancel());
    return const NavState();
  }

  // ---------------------------------------------------------------- views

  void goHome({bool push = true}) => _goView(AppView.home, push: push);

  void openSettings({String? section}) {
    _goView(AppView.settings, push: true);
    if (section != null) state = state.copyWith(settingsSection: section);
  }

  void _goView(AppView view, {required bool push}) {
    if (_current.view == view && view != AppView.reader) return;
    _captureCurrentPosition();
    if (push) {
      _back.add(_current);
      _forward.clear();
    }
    _current = _Entry(view);
    state = NavState(
      view: view,
      location: state.location,
      page: state.page,
      canBack: _back.isNotEmpty,
      canForward: _forward.isNotEmpty,
    );
  }

  // ---------------------------------------------------------------- pages

  Future<void> open(DocLocation loc, {bool push = true}) async {
    _captureCurrentPosition();
    final same = state.view == AppView.reader && state.location != null && state.location!.samePage(loc);
    if (push && !(same && loc.anchor == null && loc.line == null)) {
      _back.add(_current);
      _forward.clear();
    }
    _current = _Entry(AppView.reader, loc);
    if (same && state.page != null) {
      // In-page navigation: just scroll.
      state = state.copyWith(
        view: AppView.reader,
        location: loc,
        scroll: ScrollRequest(anchor: loc.anchor, line: loc.line, highlight: loc.highlight),
        canBack: _back.isNotEmpty,
        canForward: _forward.isNotEmpty,
      );
      return;
    }
    await _load(loc);
  }

  /// Opens the first page of a library (default version unless given).
  Future<void> openLibrary(Library lib, {String? versionId}) async {
    final v = (versionId != null ? lib.version(versionId) : null) ?? lib.defaultVersion;
    final first = v.firstPage;
    if (first == null) return;
    ref.read(uiStateProvider).lastLibraryId = lib.key;
    await open(DocLocation(libKey: lib.key, versionId: v.id, page: first));
  }

  /// Switches version keeping the same page path if it exists (FR-LIB-03).
  Future<void> switchVersion(String versionId) async {
    final loc = state.location;
    if (loc == null) return;
    final lib = ref.read(libraryProvider).byKey(loc.libKey);
    final v = lib?.version(versionId);
    if (lib == null || v == null) return;
    final samePath = File(v.absPath(loc.page)).existsSync() && p.isWithin(v.absDir, v.absPath(loc.page));
    final page = samePath ? loc.page : v.firstPage;
    if (page == null) return;
    await open(DocLocation(libKey: loc.libKey, versionId: versionId, page: page));
  }

  Future<void> back() async {
    if (_back.isEmpty) return;
    _captureCurrentPosition();
    _forward.add(_current);
    _current = _back.removeLast();
    await _restoreEntry(_current);
  }

  Future<void> forward() async {
    if (_forward.isEmpty) return;
    _captureCurrentPosition();
    _back.add(_current);
    _current = _forward.removeLast();
    await _restoreEntry(_current);
  }

  Future<void> _restoreEntry(_Entry e) async {
    if (e.view != AppView.reader || e.loc == null) {
      state = NavState(
        view: e.view,
        location: state.location,
        page: state.page,
        canBack: _back.isNotEmpty,
        canForward: _forward.isNotEmpty,
      );
      return;
    }
    final loc = e.loc!;
    if (state.page != null && state.location != null && state.location!.samePage(loc)) {
      state = state.copyWith(
        view: AppView.reader,
        location: loc,
        scroll: ScrollRequest(anchor: loc.anchor, line: loc.line),
        canBack: _back.isNotEmpty,
        canForward: _forward.isNotEmpty,
      );
      return;
    }
    await _load(loc);
  }

  Future<void> reloadCurrent({bool keepPosition = true}) async {
    final loc = state.location;
    if (loc == null || state.page == null) return;
    final anchored = keepPosition
        ? DocLocation(libKey: loc.libKey, versionId: loc.versionId, page: loc.page, anchor: _posAnchor)
        : loc;
    await _load(anchored, keepRatio: keepPosition ? _posRatio : null);
  }

  void _onLibrariesChanged() {
    final libs = ref.read(libraryProvider);
    final page = state.page;
    if (page == null) return;
    final changed = libs.lastChangedDirs;
    if (changed.isEmpty || changed.any((d) => p.isWithin(d, page.filePath) || p.equals(d, page.lib.dir))) {
      if (File(page.filePath).existsSync()) {
        reloadCurrent(keepPosition: true);
      }
    }
  }

  static Future<MdDocument> _parseMarkdownInIsolate(String text) => Isolate.run(() => MdParser.parse(text));

  Future<void> _load(DocLocation loc, {double? keepRatio}) async {
    final libs = ref.read(libraryProvider);
    final lib = libs.byKey(loc.libKey);
    final version = lib?.version(loc.versionId);
    if (lib == null || version == null) {
      state = state.copyWith(view: AppView.reader, location: loc, error: '找不到文档库或版本：${loc.libKey}/${loc.versionId}');
      return;
    }
    state = state.copyWith(view: AppView.reader, location: loc, loading: true, clearError: true);
    final settings = ref.read(settingsProvider);
    final zhPath = version.absPath(loc.page);
    if (!p.isWithin(version.absDir, zhPath)) {
      state = state.copyWith(loading: false, error: '页面路径越出文档库目录');
      return;
    }
    var filePath = zhPath;
    var lang = 'zh';
    var originalMissing = false;
    final meta = version.pages[loc.page];
    if (settings.language == 'original') {
      final origName = meta?.original ??
          (loc.page.toLowerCase().endsWith('.md') ? '${p.basenameWithoutExtension(loc.page)}.en.md' : null);
      final orig = origName == null ? null : p.normalize(p.join(p.dirname(zhPath), origName));
      if (orig != null && p.isWithin(version.absDir, orig) && File(orig).existsSync()) {
        filePath = orig;
        lang = 'original';
      } else {
        originalMissing = true;
      }
    }
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        state = state.copyWith(loading: false, error: '页面文件不存在：${loc.page}');
        return;
      }
      final text = await file.readAsString();
      final doc = text.length > 60000 ? await _parseMarkdownInIsolate(text) : MdParser.parse(text);
      final data = PageData(
        lib: lib,
        version: version,
        page: loc.page,
        doc: doc,
        filePath: filePath,
        lang: lang,
        originalMissing: originalMissing,
        meta: meta,
      );
      ScrollRequest scroll;
      if (loc.anchor != null || loc.line != null) {
        scroll = ScrollRequest(anchor: loc.anchor, line: loc.line, highlight: loc.highlight, ratio: keepRatio);
      } else if (keepRatio != null) {
        scroll = ScrollRequest(blockIndex: 0, ratio: keepRatio);
      } else if (settings.rememberPosition) {
        final pos = ref.read(databaseProvider).readingPosition(lib.key, version.id, loc.page);
        scroll = pos == null ? ScrollRequest(blockIndex: 0) : ScrollRequest(anchor: pos.anchor, ratio: pos.ratio, blockIndex: pos.anchor == null ? 0 : null);
      } else {
        scroll = ScrollRequest(blockIndex: 0);
      }
      _posAnchor = null;
      _posRatio = 0;
      _posBlock = null;
      ref.read(uiStateProvider).lastLocation = loc.toJson();
      state = NavState(
        view: AppView.reader,
        location: loc,
        page: data,
        scroll: scroll,
        canBack: _back.isNotEmpty,
        canForward: _forward.isNotEmpty,
      );
    } catch (e, st) {
      Log.error('open page failed', e, st);
      state = state.copyWith(loading: false, error: '打开页面失败：$e');
    }
  }

  // ---------------------------------------------------------------- position

  /// Called by the reader as the user scrolls.
  /// [anchor] is the nearest heading above the viewport top, [ratio] the
  /// offset of the top block relative to the section, [blockIndex] the top block.
  void reportPosition({String? anchor, required double ratio, required int blockIndex}) {
    _posAnchor = anchor;
    _posRatio = ratio;
    _posBlock = blockIndex;
    final settings = ref.read(settingsProvider);
    if (!settings.rememberPosition) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _persistPosition);
  }

  void _persistPosition() {
    final page = state.page;
    if (page == null) return;
    try {
      ref.read(databaseProvider).saveReadingPosition(page.lib.key, page.version.id, page.page, _posAnchor, _posRatio);
    } catch (e) {
      Log.warn('save position failed: $e');
    }
  }

  void _captureCurrentPosition() {
    if (_current.view == AppView.reader && _current.loc != null && state.page != null) {
      final l = _current.loc!;
      _current.loc = DocLocation(libKey: l.libKey, versionId: l.versionId, page: l.page, anchor: _posAnchor ?? l.anchor);
      _saveTimer?.cancel();
      if (ref.read(settingsProvider).rememberPosition) _persistPosition();
    }
  }

  /// Current reading anchor (for "AI: 就当前页提问" etc.).
  String? get currentAnchor => _posAnchor;
  int? get currentBlock => _posBlock;
}
