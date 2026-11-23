import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/log.dart';
import '../../core/paths.dart';
import '../reader/links/link_resolver.dart';
import '../settings/settings_controller.dart';
import 'models.dart';
import 'scanner.dart';

class LibraryState {
  LibraryState({
    this.libraries = const [],
    this.errors = const {},
    this.loading = false,
    this.loadedOnce = false,
    UrlIndex? urls,
    this.generation = 0,
  }) : urls = urls ?? UrlIndex();

  final List<Library> libraries;
  final Map<String, String> errors;
  final bool loading;
  final bool loadedOnce;
  final UrlIndex urls;

  /// Incremented on each reload; lets dependants refresh (e.g. open page).
  final int generation;

  /// Directories changed in the most recent incremental reload.
  Set<String> lastChangedDirs = const {};

  Library? byKey(String key) {
    for (final l in libraries) {
      if (l.key == key) return l;
    }
    return null;
  }

  LibraryVersion? version(String libKey, String versionId) => byKey(libKey)?.version(versionId);
}

final libraryProvider = NotifierProvider<LibraryController, LibraryState>(LibraryController.new);

class LibraryController extends Notifier<LibraryState> {
  LibraryWatcher? _watcher;
  List<String> _roots = const [];
  int _gen = 0;
  Future<void>? _inFlight;

  @override
  LibraryState build() {
    _roots = ref.read(settingsProvider).libraryRoots;
    ref.listen(settingsProvider.select((s) => s.libraryRoots.join('|')), (prev, next) {
      _roots = ref.read(settingsProvider).libraryRoots;
      reload();
    });
    _watcher = LibraryWatcher(_onFsChange);
    ref.onDispose(() => _watcher?.stop());
    Future.microtask(reload);
    return LibraryState(loading: true);
  }

  List<String> get roots => _roots;

  Future<void> reload() async {
    final prev = _inFlight;
    if (prev != null) await prev;
    final c = Completer<void>();
    _inFlight = c.future;
    try {
      _ensureDefaultRoot();
      state = LibraryState(
        libraries: state.libraries,
        errors: state.errors,
        loading: true,
        loadedOnce: state.loadedOnce,
        urls: state.urls,
        generation: state.generation,
      );
      final previous = {for (final l in state.libraries) l.dir: l};
      // Phase 1: fast manifest-only scan so Home becomes interactive well under NFR-01 (<2s).
      final fastResult = await LibraryScanner.scanAsync(_roots, previous: previous, eagerPageMetas: false);
      _publish(fastResult, null);
      _watcher?.watch(_roots);
      // Phase 2: hydrate front-matter PageMeta & UrlIndex asynchronously in background.
      final needsHydrate = fastResult.libraries.any((l) => l.format == LibraryFormat.contract && l.versions.any((v) => v.pages.isEmpty));
      if (needsHydrate) {
        final expectedGen = _gen;
        unawaited(LibraryScanner.hydrateMetasAsync(fastResult.libraries).then((hydrated) {
          if (_gen == expectedGen) {
            _publish(ScanResult(hydrated, fastResult.errors), null, bumpGeneration: false);
          }
        }).catchError((Object e, StackTrace st) {
          Log.warn('background meta hydration failed: $e');
        }));
      }
    } catch (e, st) {
      Log.error('library reload failed', e, st);
    } finally {
      c.complete();
      _inFlight = null;
    }
  }

  void _ensureDefaultRoot() {
    final def = p.normalize(AppPaths.defaultLibraryRoot);
    for (final r in _roots) {
      if (p.equals(p.normalize(r), def)) {
        try {
          Directory(def).createSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<void> _onFsChange(Set<String> dirs, bool rootsChanged) async {
    final prev = _inFlight;
    if (prev != null) await prev;
    final previous = {for (final l in state.libraries) l.dir: l};
    try {
      final result = await LibraryScanner.scanAsync(
        _roots,
        previous: previous,
        onlyDirs: rootsChanged ? null : dirs,
      );
      _publish(result, dirs);
      Log.info('libraries reloaded: ${dirs.join(', ')}');
    } catch (e, st) {
      Log.error('incremental reload failed', e, st);
    }
  }

  void _publish(ScanResult result, Set<String>? changed, {bool bumpGeneration = true}) {
    final urls = UrlIndex();
    for (final l in result.libraries) {
      urls.addLibrary(l);
    }
    if (bumpGeneration) _gen++;
    state = LibraryState(
      libraries: result.libraries,
      errors: result.errors,
      loading: false,
      loadedOnce: true,
      urls: urls,
      generation: _gen,
    )..lastChangedDirs = changed ?? const {};
  }
}
