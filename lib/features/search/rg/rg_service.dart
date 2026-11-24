import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../../core/log.dart';
import '../../../core/paths.dart';
import '../../library/models.dart';
import '../../reader/markdown/md_model.dart';
import '../../reader/markdown/md_parser.dart';
import '../models.dart';

part 'local_markdown_search.dart';

/// Cancellation handle for an in-flight full-text search.
class RgCancelToken {
  bool _cancelled = false;
  final List<Process> _procs = [];
  final Set<void Function()> _onCancel = {};

  bool get isCancelled => _cancelled;

  void attach(Process proc) {
    if (_cancelled) {
      proc.kill();
    } else {
      _procs.add(proc);
    }
  }

  void cancel() {
    _cancelled = true;
    for (final p in _procs) {
      try {
        p.kill();
      } catch (_) {}
    }
    _procs.clear();
    for (final stop in _onCancel) {
      stop();
    }
    _onCancel.clear();
  }
}

/// Raw parsed ripgrep match event (per file).
class RgRawFileHits {
  RgRawFileHits(this.filePath);

  final String filePath;
  final List<RgRawMatch> matches = [];
}

class RgRawMatch {
  RgRawMatch({
    required this.lineNumber,
    required this.lineText,
    required this.submatches,
    this.contextBefore = const [],
    this.contextAfter = const [],
  });

  final int lineNumber;
  final String lineText;
  final List<SubmatchRange> submatches;
  final List<String> contextBefore;
  final List<String> contextAfter;
}

class RgParseOutput {
  const RgParseOutput(this.files, {this.totalMatches = 0, this.truncated = false});
  final List<RgRawFileHits> files;
  final int totalMatches;
  final bool truncated;
}

/// Resolves the ripgrep binary path: user setting -> exe dir -> dev third_party -> PATH.
String resolveRgPath(String configuredPath) {
  final custom = configuredPath.trim();
  if (custom.isNotEmpty) return custom;
  final bundled = AppPaths.bundledRgPath;
  if (File(bundled).existsSync()) return bundled;
  if (Platform.isWindows) {
    final devPath = p.join(Directory.current.path, 'third_party', 'ripgrep', 'rg.exe');
    if (File(devPath).existsSync()) return devPath;
    return 'rg.exe';
  }
  if (Platform.isMacOS) {
    for (final path in ['/opt/homebrew/bin/rg', '/usr/local/bin/rg', '/opt/local/bin/rg']) {
      if (File(path).existsSync()) return path;
    }
  }
  return 'rg';
}

/// Reads `rg --version` first line, or null if unavailable.
Future<String?> getRgVersion(String configuredPath) async {
  if (Platform.isAndroid) return null;
  try {
    final res = await Process.run(resolveRgPath(configuredPath), const ['--version'], runInShell: false);
    if (res.exitCode != 0) return null;
    final lines = res.stdout.toString().split(RegExp(r'\r?\n'));
    return lines.isEmpty ? null : lines.first.trim();
  } catch (_) {
    return null;
  }
}

Future<String> getSearchEngineLabel(String configuredPath) async {
  if (Platform.isAndroid) return '内置离线搜索';
  return await getRgVersion(configuredPath) ??
      (Platform.isMacOS && configuredPath.trim().isEmpty ? '内置离线搜索' : 'ripgrep 未找到');
}

/// Builds the argument list for ripgrep without shell interpolation (NFR-05).
List<String> buildRgArgs({
  required String query,
  required List<String> searchDirs,
  required String caseMode, // smart | sensitive | ignore
  bool wholeWord = false,
  bool regex = false,
  int contextLines = 1,
  int maxCount = 50,
}) {
  final args = <String>[
    '--json',
    '--no-config',
    '--no-ignore',
    '--glob',
    '*.md',
    '--glob',
    '!**/assets/**',
    '--max-columns',
    '400',
    '--max-columns-preview',
    '--max-count',
    '$maxCount',
  ];
  if (contextLines > 0) {
    args.addAll(['-C', '$contextLines']);
  }
  switch (caseMode) {
    case 'sensitive':
      args.add('--case-sensitive');
    case 'ignore':
      args.add('--ignore-case');
    default:
      args.add('--smart-case');
  }
  if (wholeWord) args.add('--word-regexp');
  if (!regex) args.add('--fixed-strings');
  args.addAll(['-e', query, '--', ...searchDirs]);
  return args;
}

/// Converts a UTF-8 byte offset inside [text] to a Dart UTF-16 code-unit index.
int utf8ByteOffsetToStringIndex(String text, int byteOffset) {
  if (byteOffset <= 0) return 0;
  var bytes = 0;
  var i = 0;
  for (final rune in text.runes) {
    final runeBytes = rune < 0x80
        ? 1
        : rune < 0x800
            ? 2
            : rune < 0x10000
                ? 3
                : 4;
    if (bytes >= byteOffset) return i;
    bytes += runeBytes;
    i += rune >= 0x10000 ? 2 : 1;
  }
  return text.length;
}

/// Stateful incremental parser for `rg --json` lines.
class RgJsonParser {
  RgJsonParser({this.maxResults = 300});

  final int maxResults;
  final List<RgRawFileHits> files = [];
  RgRawFileHits? _curFile;
  final List<String> _pendingBefore = [];
  RgRawMatch? _lastMatch;
  int totalMatches = 0;
  bool truncated = false;

  /// Processes one JSON line. Returns true if [maxResults] was reached.
  bool feedLine(String line) {
    if (line.trim().isEmpty) return truncated;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return truncated;
    }
    if (decoded is! Map<String, dynamic>) return truncated;
    final type = decoded['type'];
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) return truncated;

    switch (type) {
      case 'begin':
        final path = _textOf(data['path']);
        if (path != null) {
          _curFile = RgRawFileHits(path);
          files.add(_curFile!);
        }
        _pendingBefore.clear();
        _lastMatch = null;
      case 'context':
        final txt = (_textOf(data['lines']) ?? '').trimRight();
        final ln = (data['line_number'] as num?)?.toInt();
        final last = _lastMatch;
        if (last != null && ln != null && ln > last.lineNumber) {
          last.contextAfter.add(txt);
        } else {
          _pendingBefore.add(txt);
        }
      case 'match':
        final path = _textOf(data['path']);
        if (_curFile == null && path != null) {
          _curFile = RgRawFileHits(path);
          files.add(_curFile!);
        }
        final ln = (data['line_number'] as num?)?.toInt() ?? 1;
        final txt = (_textOf(data['lines']) ?? '').trimRight();
        final subs = <SubmatchRange>[];
        final rawSubs = data['submatches'];
        if (rawSubs is List) {
          for (final s in rawSubs) {
            if (s is Map) {
              final bStart = (s['start'] as num?)?.toInt() ?? 0;
              final bEnd = (s['end'] as num?)?.toInt() ?? 0;
              final cStart = utf8ByteOffsetToStringIndex(txt, bStart);
              final cEnd = utf8ByteOffsetToStringIndex(txt, bEnd);
              if (cEnd > cStart) subs.add(SubmatchRange(cStart, cEnd));
            }
          }
        }
        final match = RgRawMatch(
          lineNumber: ln,
          lineText: txt,
          submatches: subs,
          contextBefore: List<String>.of(_pendingBefore),
          contextAfter: <String>[],
        );
        _pendingBefore.clear();
        _curFile?.matches.add(match);
        _lastMatch = match;
        totalMatches++;
        if (totalMatches >= maxResults) {
          truncated = true;
          return true;
        }
      case 'end':
        _curFile = null;
        _pendingBefore.clear();
        _lastMatch = null;
    }
    return truncated;
  }

  String? _textOf(Object? v) {
    if (v is Map) return v['text'] as String?;
    return null;
  }

  RgParseOutput finish() => RgParseOutput(
        files.where((f) => f.matches.isNotEmpty).toList(),
        totalMatches: totalMatches,
        truncated: truncated,
      );
}

class _DirTarget {
  _DirTarget(this.lib, this.version, this.dir);
  final Library lib;
  final LibraryVersion version;
  final String dir;
}

class RgService {
  RgService({this.configuredPath = ''}) : _useLocal = Platform.isAndroid;

  RgService.local() : configuredPath = '', _useLocal = true;

  final String configuredPath;
  final bool _useLocal;
  bool get _canFallBack => Platform.isMacOS && configuredPath.trim().isEmpty;

  /// Runs global full-text search across [targets] and returns page-grouped,
  /// spec-sorted results.
  Future<RgSearchResult> search({
    required String query,
    required List<Library> libraries,
    required SearchScope scope,
    Library? currentLibrary,
    LibraryVersion? currentVersion,
    required String currentLang, // 'zh' | 'original'
    String caseMode = 'smart',
    bool wholeWord = false,
    bool regex = false,
    int contextLines = 1,
    int maxResults = 300,
    RgCancelToken? cancelToken,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const RgSearchResult();

    final targets = _resolveTargets(libraries, scope, currentLibrary, currentVersion);
    if (targets.isEmpty) return const RgSearchResult();

    final raw = await _runSearch(
      query: trimmed,
      searchDirs: targets.map((t) => t.dir).toList(),
      caseMode: caseMode,
      wholeWord: wholeWord,
      regex: regex,
      contextLines: contextLines,
      maxResults: maxResults,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCancelled ?? false) return const RgSearchResult();
    if (raw.error != null) return RgSearchResult(error: raw.error);

    final out = raw.output!;
    final lowerQuery = trimmed.toLowerCase();
    // Group by canonical (lib.key, version.id, zhPagePath).
    final grouped = <String, _GroupBuilder>{};
    for (final fileHits in out.files) {
      final mapped = _mapFileToPage(fileHits.filePath, targets);
      if (mapped == null) continue;
      final key = '${mapped.lib.key}|${mapped.version.id}|${mapped.canonicalPage}';
      final b = grouped.putIfAbsent(
        key,
        () => _GroupBuilder(
          lib: mapped.lib,
          version: mapped.version,
          page: mapped.canonicalPage,
          pageTitle: mapped.version.titleOf(mapped.canonicalPage) ?? p.basenameWithoutExtension(mapped.canonicalPage),
          tocOrder: mapped.version.orderedPages.indexOf(mapped.canonicalPage),
        ),
      );
      if (b.pageTitle.toLowerCase().contains(lowerQuery)) {
        b.hasTitleHit = true;
      }
      for (final m in fileHits.matches) {
        final trimmedLine = m.lineText.trimLeft();
        final isHeading = _isHeadingOrTitleLine(m.lineText);
        final isCurLang = (currentLang == 'original') == mapped.isOriginal;
        if (trimmedLine.startsWith('title:') || trimmedLine.startsWith('# ')) {
          b.hasTitleHit = true;
        }
        if (isHeading) b.hasHeadingHit = true;
        if (isCurLang) b.hasCurrentLangHit = true;
        b.hits.add(RgHit(
          lineNumber: m.lineNumber,
          lineText: m.lineText,
          submatches: m.submatches,
          contextBefore: m.contextBefore,
          contextAfter: m.contextAfter,
          isHeadingHit: isHeading,
          isOriginal: mapped.isOriginal,
        ));
      }
    }

    final groups = grouped.values.map((b) {
      // Current language hits first within a page.
      b.hits.sort((a, c) {
        final al = ((currentLang == 'original') == a.isOriginal) ? 0 : 1;
        final cl = ((currentLang == 'original') == c.isOriginal) ? 0 : 1;
        if (al != cl) return al.compareTo(cl);
        if (a.isHeadingHit != c.isHeadingHit) return a.isHeadingHit ? -1 : 1;
        return a.lineNumber.compareTo(c.lineNumber);
      });
      return PageSearchGroup(
        lib: b.lib,
        version: b.version,
        page: b.page,
        pageTitle: b.pageTitle,
        hits: b.hits,
        hasTitleHit: b.hasTitleHit,
        hasHeadingHit: b.hasHeadingHit,
        hasCurrentLangHit: b.hasCurrentLangHit,
        tocOrder: b.tocOrder < 0 ? 1 << 20 : b.tocOrder,
      );
    }).toList();

    // Sort: page title hit > heading hit > current language > hit count desc > toc order.
    groups.sort((a, b) {
      if (a.hasTitleHit != b.hasTitleHit) return a.hasTitleHit ? -1 : 1;
      if (a.hasHeadingHit != b.hasHeadingHit) return a.hasHeadingHit ? -1 : 1;
      if (a.hasCurrentLangHit != b.hasCurrentLangHit) return a.hasCurrentLangHit ? -1 : 1;
      if (a.hits.length != b.hits.length) return b.hits.length.compareTo(a.hits.length);
      return a.tocOrder.compareTo(b.tocOrder);
    });

    return RgSearchResult(
      groups: groups,
      totalHits: out.totalMatches,
      truncated: out.truncated,
    );
  }

  /// Multi-keyword parallel rg recall for AI hybrid retrieval (spec 06 §4.2).
  /// Runs up to 8 keywords with concurrency 4.
  Future<Map<String, List<RgRawFileHits>>> searchKeywords({
    required List<String> keywords,
    required List<String> searchDirs,
    RgCancelToken? cancelToken,
  }) async {
    final kws = keywords.map((k) => k.trim()).where((k) => k.isNotEmpty).toSet().take(8).toList();
    if (kws.isEmpty || searchDirs.isEmpty) return {};

    Future<Map<String, List<RgRawFileHits>>> localKeywords() async {
      final local = await _runLocalSearch(
        (queries: kws, dirs: searchDirs, caseMode: 'ignore', wholeWord: false,
          regex: false, context: 0, fileLimit: 25, totalLimit: 200),
        cancelToken,
      );
      return {
        if (local is List<RgParseOutput>)
          for (var i = 0; i < kws.length; i++) kws[i]: local[i].files,
      };
    }
    if (_useLocal) return localKeywords();

    final result = <String, List<RgRawFileHits>>{};
    const maxConcurrent = 4;
    var next = 0;
    var useFallback = false;
    Future<void> worker() async {
      while (next < kws.length && !useFallback) {
        if (cancelToken?.isCancelled ?? false) return;
        final kw = kws[next++];
        final args = buildRgArgs(
          query: kw,
          searchDirs: searchDirs,
          caseMode: 'ignore',
          regex: false,
          contextLines: 0,
          maxCount: 25,
        );
        final raw = await _runRg(args, maxResults: 200, cancelToken: cancelToken);
        if (raw.startFailed && _canFallBack) useFallback = true;
        if (raw.output != null) {
          result[kw] = raw.output!.files;
        }
      }
    }

    await Future.wait([for (var i = 0; i < maxConcurrent && i < kws.length; i++) worker()]);
    return useFallback ? localKeywords() : result;
  }

  /// Code-block regex fallback for Symbol search (spec 06 §3).
  Future<List<SymbolSearchHit>> searchCodeFallback({
    required String query,
    required List<Library> libraries,
    required SearchScope scope,
    Library? currentLibrary,
    LibraryVersion? currentVersion,
    RgCancelToken? cancelToken,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final targets = _resolveTargets(libraries, scope, currentLibrary, currentVersion);
    if (targets.isEmpty) return const [];

    final esc = RegExp.escape(q);
    final pattern = r'\b' + esc + r'\b\s*[(<{:=]|class\s+' + esc + r'|' + esc + r'\s*\(';
    final raw = await _runSearch(
      query: pattern,
      searchDirs: targets.map((t) => t.dir).toList(),
      caseMode: 'sensitive',
      regex: true,
      contextLines: 0,
      maxCount: 10,
      maxResults: 80,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCancelled ?? false) return const [];
    if (raw.output == null) return const [];

    final hits = <SymbolSearchHit>[];
    for (final fh in raw.output!.files) {
      final mapped = _mapFileToPage(fh.filePath, targets);
      if (mapped == null) continue;
      // Only keep hits inside fenced code blocks.
      List<(int, int)> codeRanges;
      try {
        final doc = MdParser.parse(await File(fh.filePath).readAsString());
        codeRanges = [
          for (final b in doc.blocks)
            if (b.kind == BlockKind.code) (b.startLine, b.endLine),
        ];
      } catch (_) {
        continue;
      }
      if (codeRanges.isEmpty) continue;
      final pageTitle = mapped.version.titleOf(mapped.canonicalPage) ?? p.basenameWithoutExtension(mapped.canonicalPage);
      for (final m in fh.matches) {
        final inCode = codeRanges.any((r) => m.lineNumber >= r.$1 && m.lineNumber <= r.$2);
        if (!inCode) continue;
        hits.add(SymbolSearchHit(
          lib: mapped.lib,
          version: mapped.version,
          page: mapped.canonicalPage,
          pageTitle: pageTitle,
          score: 50,
          line: m.lineNumber,
          snippet: m.lineText.trim(),
          isCodeFallback: true,
        ));
        if (hits.length >= 40) return hits;
      }
    }
    return hits;
  }

  List<_DirTarget> _resolveTargets(
    List<Library> libraries,
    SearchScope scope,
    Library? currentLibrary,
    LibraryVersion? currentVersion,
  ) {
    final targets = <_DirTarget>[];
    if (scope == SearchScope.currentLibrary && currentLibrary != null) {
      final v = currentVersion ?? currentLibrary.defaultVersion;
      final dir = v.searchDir;
      if (Directory(dir).existsSync()) targets.add(_DirTarget(currentLibrary, v, dir));
    } else {
      for (final l in libraries) {
        final v = l.defaultVersion;
        final dir = v.searchDir;
        if (Directory(dir).existsSync()) targets.add(_DirTarget(l, v, dir));
      }
    }
    return targets;
  }

  ({Library lib, LibraryVersion version, String canonicalPage, bool isOriginal})? _mapFileToPage(
    String filePath,
    List<_DirTarget> targets,
  ) {
    final norm = p.normalize(filePath);
    for (final t in targets) {
      if (p.isWithin(t.version.absDir, norm)) {
        var rel = p.relative(norm, from: t.version.absDir).replaceAll('\\', '/');
        var isOrig = false;
        if (rel.toLowerCase().endsWith('.en.md')) {
          isOrig = true;
          rel = '${rel.substring(0, rel.length - 6)}.md';
        }
        return (lib: t.lib, version: t.version, canonicalPage: rel, isOriginal: isOrig);
      }
    }
    return null;
  }

  bool _isHeadingOrTitleLine(String line) {
    final t = line.trimLeft();
    return t.startsWith('#') || t.startsWith('title:');
  }

  Future<({RgParseOutput? output, String? error})> _runSearch({
    required String query,
    required List<String> searchDirs,
    required String caseMode,
    bool wholeWord = false,
    bool regex = false,
    required int contextLines,
    int maxCount = 50,
    required int maxResults,
    RgCancelToken? cancelToken,
  }) async {
    if (!_useLocal) {
      final args = buildRgArgs(
        query: query, searchDirs: searchDirs, caseMode: caseMode,
        wholeWord: wholeWord, regex: regex, contextLines: contextLines, maxCount: maxCount,
      );
      final raw = await _runRg(args, maxResults: maxResults, cancelToken: cancelToken);
      if (!raw.startFailed || !_canFallBack) return (output: raw.output, error: raw.error);
    }
    final local = await _runLocalSearch(
      (queries: [query], dirs: searchDirs, caseMode: caseMode, wholeWord: wholeWord,
        regex: regex, context: contextLines, fileLimit: maxCount, totalLimit: maxResults),
      cancelToken,
    );
    return local is List<RgParseOutput>
        ? (output: local.single, error: null)
        : (output: null, error: local as String);
  }

  Future<({RgParseOutput? output, String? error, bool startFailed})> _runRg(
    List<String> args, {
    required int maxResults,
    RgCancelToken? cancelToken,
  }) async {
    final bin = resolveRgPath(configuredPath);
    Process proc;
    try {
      proc = await Process.start(bin, args, runInShell: false);
    } catch (e) {
      Log.warn('rg start failed ($bin): $e');
      return (output: null, error: '无法启动 ripgrep（$bin）：$e', startFailed: true);
    }
    cancelToken?.attach(proc);

    final parser = RgJsonParser(maxResults: maxResults);
    final stderrBuf = StringBuffer();
    final errDone = proc.stderr.transform(utf8.decoder).listen(stderrBuf.write).asFuture<void>();

    try {
      await for (final line in proc.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
        if (cancelToken?.isCancelled ?? false) {
          proc.kill();
          break;
        }
        if (parser.feedLine(line)) {
          proc.kill();
          break;
        }
      }
    } catch (_) {
      // Process killed on cancel/truncation.
    }
    final code = await proc.exitCode;
    await errDone.catchError((_) {});

    // rg returns 0 (matches), 1 (no matches), 2 (error - e.g. invalid regex).
    if (code == 2 && !parser.truncated && !(cancelToken?.isCancelled ?? false)) {
      final msg = stderrBuf.toString().trim();
      return (output: null, error: msg.isEmpty ? '搜索表达式无效' : msg, startFailed: false);
    }
    return (output: parser.finish(), error: null, startFailed: false);
  }
}

class _GroupBuilder {
  _GroupBuilder({
    required this.lib,
    required this.version,
    required this.page,
    required this.pageTitle,
    required this.tocOrder,
  });

  final Library lib;
  final LibraryVersion version;
  final String page;
  final String pageTitle;
  final int tocOrder;
  final List<RgHit> hits = [];
  bool hasTitleHit = false;
  bool hasHeadingHit = false;
  bool hasCurrentLangHit = false;
}
