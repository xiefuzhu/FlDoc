import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/slug.dart';
import '../../../core/url_normalize.dart';
import '../../reader/markdown/md_model.dart';
import '../../reader/markdown/md_parser.dart';
import '../front_matter.dart';
import '../manifest_parser.dart';
import '../models.dart';
import '../symbols.dart';

class ValidationSummary {
  const ValidationSummary({
    required this.libKey,
    required this.issues,
    this.crawlReports = const {},
  });

  final String libKey;
  final List<LibraryIssue> issues;

  /// Map of versionId -> crawl-report.md content if present.
  final Map<String, String> crawlReports;

  int get errorCount => issues.where((i) => i.isError).length;
  int get warningCount => issues.where((i) => !i.isError).length;
  bool get ok => errorCount == 0 && warningCount == 0;
}

/// Validates libraries against contract rules V01..V20 (doc 03 §9).
class LibraryValidator {
  static const _htmlWhitelist = {'kbd', 'sub', 'sup', 'br', 'details', 'summary', 'a'};

  static final _mdLink = RegExp(r'(!?)\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
  static final _fenceLine = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
  static final _headingLine = RegExp(r'^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$');
  static final _htmlTag = RegExp(r'<\s*/?\s*([A-Za-z][A-Za-z0-9-]*)(?:\s[^>]*)?/?>');

  /// Validates a single library; pass [allLibraries] to also check cross-root duplicate IDs (V02).
  static ValidationSummary validateLibrary(Library lib, {List<Library> allLibraries = const []}) {
    final issues = <LibraryIssue>[];
    final crawlReports = <String, String>{};
    final libDir = lib.dir;

    void add(
      String code,
      IssueLevel level,
      String msg, {
      String? versionId,
      String? file,
      String? page,
      int? line,
    }) {
      issues.add(LibraryIssue(
        code: code,
        level: level,
        message: msg,
        libId: lib.id,
        versionId: versionId,
        file: file,
        page: page,
        line: line,
      ));
    }

    if (lib.format == LibraryFormat.plain) {
      // Plain libraries only validate UTF-8/BOM (V20) and local links/images (V11/V13) gently.
      for (final v in lib.versions) {
        for (final pg in v.orderedPages) {
          final abs = v.absPath(pg);
          _checkUtf8AndBom(abs, (code, msg) => add(code, IssueLevel.warning, msg, versionId: v.id, file: abs, page: pg));
        }
      }
      return ValidationSummary(libKey: lib.key, issues: issues);
    }

    // ---- V01: manifest.json valid JSON & schema ----
    final manifestPath = p.join(libDir, 'manifest.json');
    final manifestBytes = _checkUtf8AndBom(
      manifestPath,
      (code, msg) => add(code, IssueLevel.warning, msg, file: manifestPath),
    );
    if (manifestBytes == null) {
      add('V01', IssueLevel.error, 'manifest.json 不存在或不可读', file: manifestPath);
      return ValidationSummary(libKey: lib.key, issues: issues);
    }

    Object? decoded;
    try {
      decoded = jsonDecode(manifestBytes);
    } on FormatException catch (e) {
      add('V01', IssueLevel.error, 'manifest.json 不是合法 JSON：${e.message}', file: manifestPath);
      return ValidationSummary(libKey: lib.key, issues: issues);
    }
    if (decoded is! Map<String, dynamic>) {
      add('V01', IssueLevel.error, 'manifest.json 顶层必须是对象', file: manifestPath);
      return ValidationSummary(libKey: lib.key, issues: issues);
    }
    final m = decoded;
    if (m['schema'] != 'fldoc.library/1') {
      add('V01', IssueLevel.error, 'manifest.json schema 应为 fldoc.library/1，实际为 ${m['schema']}', file: manifestPath);
    }

    // ---- V02: id format, matches dir name, unique across roots ----
    final id = m['id'];
    final dirName = p.basename(libDir);
    if (id is! String || !libIdPattern.hasMatch(id)) {
      add('V02', IssueLevel.error, 'manifest.id 格式不符合规范：$id', file: manifestPath);
    } else if (id != dirName) {
      add('V02', IssueLevel.error, 'manifest.id ($id) 与目录名 ($dirName) 不一致', file: manifestPath);
    }
    if (lib.duplicateOfRoot != null ||
        allLibraries.where((other) => other.id == lib.id && !p.equals(other.dir, lib.dir)).isNotEmpty) {
      add('V02', IssueLevel.error, '库 ID "${lib.id}" 与其他库根目录冲突', file: manifestPath);
    }

    // ---- V03: versions unique, defaultVersion exists, dir exists ----
    final rawVersions = m['versions'];
    final defVer = m['defaultVersion'];
    final seenVerIds = <String>{};
    final validVersions = <(String id, String dir, String absDir, List<TocNode> toc)>[];
    if (rawVersions is! List || rawVersions.isEmpty) {
      add('V03', IssueLevel.error, 'manifest.versions 为空或缺失', file: manifestPath);
    } else {
      for (final rv in rawVersions) {
        if (rv is! Map<String, dynamic>) continue;
        final vid = rv['id'] as String?;
        final vdir = (rv['dir'] as String?) ?? vid ?? '';
        if (vid == null || !versionIdPattern.hasMatch(vid)) {
          add('V03', IssueLevel.error, '版本 id 格式无效：$vid', file: manifestPath);
          continue;
        }
        if (!seenVerIds.add(vid)) {
          add('V03', IssueLevel.error, '版本 id 重复：$vid', versionId: vid, file: manifestPath);
        }
        final absDir = p.normalize(p.join(libDir, vdir));
        if (!(p.equals(libDir, absDir) || p.isWithin(libDir, absDir)) || !Directory(absDir).existsSync()) {
          add('V03', IssueLevel.error, '版本目录不存在：$vdir', versionId: vid, file: manifestPath);
        } else {
          validVersions.add((vid, vdir, absDir, parseToc(rv['toc'])));
        }
      }
      if (defVer is! String || !seenVerIds.contains(defVer)) {
        add('V03', IssueLevel.error, 'defaultVersion ($defVer) 不在 versions 列表中', file: manifestPath);
      }
    }

    // ---- Validate each version ----
    for (final (vid, vdir, absDir, toc) in validVersions) {
      final reportFile = File(p.join(absDir, 'crawl-report.md'));
      if (reportFile.existsSync()) {
        try {
          crawlReports[vid] = reportFile.readAsStringSync();
        } catch (_) {}
      }

      // V04 & V05: toc pages exist, don't escape, no duplicates
      final tocPages = <String>{};
      for (final node in toc) {
        for (final n in node.walk()) {
          final pg = n.page;
          if (pg == null) continue;
          if (!tocPages.add(pg)) {
            add('V05', IssueLevel.warning, '页面在 toc 中重复出现：$pg', versionId: vid, file: manifestPath, page: pg);
          }
          final abs = p.normalize(p.join(absDir, pg));
          if (!p.isWithin(absDir, abs)) {
            add('V04', IssueLevel.error, 'toc 页面路径越出版本目录：$pg', versionId: vid, file: manifestPath, page: pg);
          } else if (!File(abs).existsSync()) {
            add('V04', IssueLevel.error, 'toc 引用的页面文件不存在：$pg', versionId: vid, file: manifestPath, page: pg);
          }
        }
      }

      // V06: orphan Chinese pages under pages/
      final pagesRoot = vdir == '.' ? absDir : p.join(absDir, 'pages');
      if (Directory(pagesRoot).existsSync()) {
        for (final e in Directory(pagesRoot).listSync(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final low = e.path.toLowerCase();
          if (!low.endsWith('.md') || low.endsWith('.en.md')) continue;
          final rel = p.relative(e.path, from: absDir).replaceAll('\\', '/');
          if (!tocPages.contains(rel)) {
            add('V06', IssueLevel.warning, '孤儿页面（未被 toc 引用）：$rel', versionId: vid, file: e.path, page: rel);
          }
        }
      }

      // Parse all pages in toc for cross-page checks (V07..V14, V17..V20)
      final pageDocs = <String, MdDocument>{};
      final pageTexts = <String, String>{};
      final sourceUrlOwners = <String, String>{};

      for (final pg in tocPages) {
        final abs = p.normalize(p.join(absDir, pg));
        if (!p.isWithin(absDir, abs) || !File(abs).existsSync()) continue;

        final text = _checkUtf8AndBom(
          abs,
          (code, msg) => add(code, IssueLevel.warning, msg, versionId: vid, file: abs, page: pg),
        );
        if (text == null) continue;
        pageTexts[pg] = text;

        // V07: front matter parse & required fields
        final fm = parseFrontMatter(text);
        if (!fm.present || fm.error != null) {
          add('V07', IssueLevel.error, fm.error ?? '页面缺少 front matter', versionId: vid, file: abs, page: pg, line: 1);
        } else {
          final requiredFields = ['title', 'source_url', 'lang', 'source_lang', 'translated', 'fetched_at', 'source_sha256'];
          for (final k in requiredFields) {
            if (!fm.data.containsKey(k) || fm.data[k] == null || fm.data[k].toString().trim().isEmpty) {
              add('V07', IssueLevel.error, 'front matter 缺少必填字段：$k', versionId: vid, file: abs, page: pg, line: 1);
            }
          }
        }

        final doc = MdParser.parse(text);
        pageDocs[pg] = doc;

        // V19: duplicate normalized source_url
        final srcUrl = fm.str('source_url');
        if (srcUrl != null && srcUrl.isNotEmpty) {
          final norm = normalizeUrl(srcUrl);
          if (norm != null) {
            final prev = sourceUrlOwners[norm];
            if (prev != null && prev != pg) {
              add('V19', IssueLevel.warning, 'source_url 规范化后与 $prev 重复：$srcUrl',
                  versionId: vid, file: abs, page: pg, line: 1);
            } else {
              sourceUrlOwners[norm] = pg;
            }
          }
        }

        // V08 & V09: translated original file check + anchor set parity
        if (fm.boolean('translated') == true) {
          final origName = fm.str('original');
          if (origName == null || origName.isEmpty) {
            add('V08', IssueLevel.error, 'translated 为 true 但缺少 original 字段',
                versionId: vid, file: abs, page: pg, line: 1);
          } else {
            final origAbs = p.normalize(p.join(p.dirname(abs), origName));
            if (!p.isWithin(absDir, origAbs) || !File(origAbs).existsSync()) {
              add('V08', IssueLevel.error, '原文文件不存在：$origName', versionId: vid, file: abs, page: pg, line: 1);
            } else {
              final origText = _checkUtf8AndBom(
                origAbs,
                (code, msg) => add(code, IssueLevel.warning, msg, versionId: vid, file: origAbs, page: pg),
              );
              if (origText != null) {
                final origFm = parseFrontMatter(origText);
                final origUrl = origFm.str('source_url');
                if (srcUrl != null && origUrl != null && normalizeUrl(srcUrl) != normalizeUrl(origUrl)) {
                  add('V08', IssueLevel.error, '原文页 source_url ($origUrl) 与中文页 ($srcUrl) 不一致',
                      versionId: vid, file: origAbs, page: pg, line: 1);
                }
                final origDoc = MdParser.parse(origText);
                final zhAnchors = doc.outline.map((o) => o.anchor).toSet();
                final enAnchors = origDoc.outline.map((o) => o.anchor).toSet();
                if (zhAnchors.length != enAnchors.length || !zhAnchors.containsAll(enAnchors)) {
                  add('V09', IssueLevel.warning, '中文页与原文页的锚点 id 集合不一致',
                      versionId: vid, file: abs, page: pg);
                }
              }
            }
          }
        }

        // Line-based checks: V10 (anchors), V14 (code fence lang), V17 (untranslated), V18 (HTML whitelist)
        _checkPageBody(
          body: fm.body,
          bodyStartLine: fm.bodyStartLine,
          absFile: abs,
          versionId: vid,
          page: pg,
          add: add,
        );
      }

      // V11, V12, V13: relative links & local images (needs all pageDocs parsed first)
      for (final entry in pageTexts.entries) {
        final pg = entry.key;
        final abs = p.normalize(p.join(absDir, pg));
        final fm = parseFrontMatter(entry.value);
        _checkLinksAndImages(
          body: fm.body,
          bodyStartLine: fm.bodyStartLine,
          absDir: absDir,
          libDir: libDir,
          absFile: abs,
          versionId: vid,
          page: pg,
          pageDocs: pageDocs,
          add: add,
        );
      }

      // V15 & V16: symbols.json
      final symFile = File(p.join(absDir, 'symbols.json'));
      if (symFile.existsSync()) {
        final symText = _checkUtf8AndBom(
          symFile.path,
          (code, msg) => add(code, IssueLevel.warning, msg, versionId: vid, file: symFile.path),
        );
        if (symText != null) {
          final parsed = parseSymbols(symText);
          for (final err in parsed.errors) {
            add('V15', IssueLevel.error, err, versionId: vid, file: symFile.path);
          }
          for (final s in parsed.symbols) {
            final targetAbs = p.normalize(p.join(absDir, s.page));
            if (!p.isWithin(absDir, targetAbs) || !File(targetAbs).existsSync()) {
              add('V15', IssueLevel.error, '符号 ${s.display} 引用的页面不存在：${s.page}',
                  versionId: vid, file: symFile.path, page: s.page);
            } else if (s.anchor != null && s.anchor!.isNotEmpty) {
              var targetDoc = pageDocs[s.page];
              targetDoc ??= MdParser.parse(File(targetAbs).readAsStringSync());
              if (targetDoc.blockForAnchor(s.anchor!) == null) {
                add('V16', IssueLevel.warning, '符号 ${s.display} 的锚点 #${s.anchor} 在 ${s.page} 中不存在',
                    versionId: vid, file: symFile.path, page: s.page);
              }
            }
          }
        }
      }
    }

    return ValidationSummary(libKey: lib.key, issues: issues, crawlReports: crawlReports);
  }

  static String? _checkUtf8AndBom(String path, void Function(String code, String msg) onWarn) {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = f.readAsBytesSync();
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      onWarn('V20', '文件包含 UTF-8 BOM');
    }
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      return text;
    } on FormatException {
      onWarn('V20', '文件编码不是有效的 UTF-8');
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static void _checkPageBody({
    required String body,
    required int bodyStartLine,
    required String absFile,
    required String versionId,
    required String page,
    required void Function(String code, IssueLevel level, String msg,
            {String? versionId, String? file, String? page, int? line})
        add,
  }) {
    final lines = body.replaceAll('\r\n', '\n').split('\n');
    var inFence = false;
    String? fenceChar;
    var fenceLen = 0;
    final seenAnchors = <String>{};
    final proseBuf = StringBuffer();

    for (var i = 0; i < lines.length; i++) {
      final lineNo = bodyStartLine + i;
      final line = lines[i];

      final fm = _fenceLine.firstMatch(line);
      if (!inFence && fm != null) {
        final marker = fm.group(1)!;
        final info = fm.group(2)!.trim();
        inFence = true;
        fenceChar = marker[0];
        fenceLen = marker.length;
        if (info.isEmpty) {
          add('V14', IssueLevel.warning, '代码块未标注语言',
              versionId: versionId, file: absFile, page: page, line: lineNo);
        }
        continue;
      }
      if (inFence) {
        final t = line.trim();
        if (t.startsWith(fenceChar! * fenceLen) && t.replaceAll(fenceChar, '').isEmpty) {
          inFence = false;
        }
        continue;
      }

      // V10: heading anchor check
      final hm = _headingLine.firstMatch(line);
      if (hm != null) {
        final headingText = hm.group(2)!;
        final (_, explicitId) = splitExplicitAnchor(headingText);
        if (explicitId == null) {
          add('V10', IssueLevel.warning, '标题缺少显式锚点 {#id}：$headingText',
              versionId: versionId, file: absFile, page: page, line: lineNo);
        } else {
          if (!seenAnchors.add(explicitId)) {
            add('V10', IssueLevel.warning, '同页锚点 id 重复：#$explicitId',
                versionId: versionId, file: absFile, page: page, line: lineNo);
          }
        }
      }

      // Strip inline code & link URLs for V18 and V17
      var clean = line.replaceAll(RegExp(r'`[^`]*`'), ' ');
      clean = clean.replaceAllMapped(_mdLink, (m) => m.group(2) ?? '');

      // V18: HTML tags outside whitelist
      for (final tagMatch in _htmlTag.allMatches(clean)) {
        final tag = tagMatch.group(1)!.toLowerCase();
        // Ignore autolinks like <https://...> or <user@host>
        final full = tagMatch.group(0)!;
        if (full.contains('://') || full.contains('@')) continue;
        if (!_htmlWhitelist.contains(tag)) {
          add('V18', IssueLevel.warning, '存在 HTML 白名单外的标签：<$tag>',
              versionId: versionId, file: absFile, page: page, line: lineNo);
        }
      }

      proseBuf.writeln(clean);
    }

    // V17: English character ratio > 60% in Chinese page prose
    final prose = proseBuf
        .toString()
        .replaceAll(RegExp(r'\{#[A-Za-z0-9_-]+\}'), ' ')
        .replaceAll(_htmlTag, ' ')
        .replaceAll(RegExp(r'https?://\S+'), ' ');
    var asciiLetters = 0;
    var nonAsciiLetters = 0;
    for (final r in prose.runes) {
      if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        asciiLetters++;
      } else if (r >= 0x4E00 && r <= 0x9FFF) {
        nonAsciiLetters++;
      }
    }
    final totalLetters = asciiLetters + nonAsciiLetters;
    if (totalLetters >= 40 && (asciiLetters / totalLetters) > 0.60) {
      final pct = ((asciiLetters / totalLetters) * 100).round();
      add('V17', IssueLevel.warning, '中文页正文英文字符占比 $pct%（超过 60%），疑似漏翻译',
          versionId: versionId, file: absFile, page: page);
    }
  }

  static void _checkLinksAndImages({
    required String body,
    required int bodyStartLine,
    required String absDir,
    required String libDir,
    required String absFile,
    required String versionId,
    required String page,
    required Map<String, MdDocument> pageDocs,
    required void Function(String code, IssueLevel level, String msg,
            {String? versionId, String? file, String? page, int? line})
        add,
  }) {
    final lines = body.replaceAll('\r\n', '\n').split('\n');
    var inFence = false;
    String? fenceChar;
    var fenceLen = 0;

    for (var i = 0; i < lines.length; i++) {
      final lineNo = bodyStartLine + i;
      final line = lines[i];
      final fm = _fenceLine.firstMatch(line);
      if (!inFence && fm != null) {
        inFence = true;
        fenceChar = fm.group(1)![0];
        fenceLen = fm.group(1)!.length;
        continue;
      }
      if (inFence) {
        final t = line.trim();
        if (t.startsWith(fenceChar! * fenceLen) && t.replaceAll(fenceChar, '').isEmpty) {
          inFence = false;
        }
        continue;
      }

      final stripped = line.replaceAll(RegExp(r'`[^`]*`'), '');
      for (final m in _mdLink.allMatches(stripped)) {
        final isImg = m.group(1) == '!';
        final rawTarget = m.group(3)!.trim();
        if (rawTarget.isEmpty) continue;
        if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(rawTarget)) continue; // absolute URL

        if (isImg) {
          // V13: local image exists
          final pathPart = Uri.decodeComponent(rawTarget.split('#').first.split('?').first);
          final targetAbs = p.normalize(p.join(p.dirname(absFile), pathPart));
          if (!p.isWithin(libDir, targetAbs) || !File(targetAbs).existsSync()) {
            add('V13', IssueLevel.error, '引用的本地图片不存在：$rawTarget',
                versionId: versionId, file: absFile, page: page, line: lineNo);
          }
          continue;
        }

        // Link: split path & anchor
        var pathPart = rawTarget;
        String? anchor;
        final hash = rawTarget.indexOf('#');
        if (hash >= 0) {
          pathPart = rawTarget.substring(0, hash);
          anchor = Uri.decodeComponent(rawTarget.substring(hash + 1));
          if (anchor.isEmpty) anchor = null;
        }
        pathPart = pathPart.split('?').first;

        if (pathPart.isEmpty) {
          // In-page anchor (V12)
          if (anchor != null) {
            final curDoc = pageDocs[page];
            if (curDoc != null && curDoc.blockForAnchor(anchor) == null) {
              add('V12', IssueLevel.warning, '页内锚点不存在：#$anchor',
                  versionId: versionId, file: absFile, page: page, line: lineNo);
            }
          }
          continue;
        }

        // V11: relative link target file exists
        final decodedPath = Uri.decodeComponent(pathPart);
        final targetAbs = p.normalize(p.join(p.dirname(absFile), decodedPath));
        if (!p.isWithin(absDir, targetAbs) || !File(targetAbs).existsSync()) {
          add('V11', IssueLevel.error, '相对链接目标文件不存在：$rawTarget',
              versionId: versionId, file: absFile, page: page, line: lineNo);
          continue;
        }

        // V12: relative link anchor exists in target page
        if (anchor != null && targetAbs.toLowerCase().endsWith('.md')) {
          final targetRel = p.relative(targetAbs, from: absDir).replaceAll('\\', '/');
          var targetDoc = pageDocs[targetRel];
          targetDoc ??= MdParser.parse(File(targetAbs).readAsStringSync());
          if (targetDoc.blockForAnchor(anchor) == null) {
            add('V12', IssueLevel.warning, '相对链接锚点在目标页中不存在：$rawTarget',
                versionId: versionId, file: absFile, page: page, line: lineNo);
          }
        }
      }
    }
  }
}

/// Cached validation summaries keyed by `lib.key`.
final validationResultsProvider = NotifierProvider<ValidationResultsNotifier, Map<String, ValidationSummary>>(
  ValidationResultsNotifier.new,
);

class ValidationResultsNotifier extends Notifier<Map<String, ValidationSummary>> {
  @override
  Map<String, ValidationSummary> build() => const {};

  ValidationSummary runFor(Library lib, List<Library> allLibraries) {
    final summary = LibraryValidator.validateLibrary(lib, allLibraries: allLibraries);
    state = {...state, lib.key: summary};
    return summary;
  }

  List<ValidationSummary> runAll(List<Library> allLibraries) {
    final next = <String, ValidationSummary>{};
    final out = <ValidationSummary>[];
    for (final lib in allLibraries) {
      final s = LibraryValidator.validateLibrary(lib, allLibraries: allLibraries);
      next[lib.key] = s;
      out.add(s);
    }
    state = next;
    return out;
  }
}
