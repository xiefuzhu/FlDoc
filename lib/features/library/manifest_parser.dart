import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/natural_sort.dart';
import 'front_matter.dart';
import 'models.dart';

class LibraryLoadException implements Exception {
  LibraryLoadException(this.message);
  final String message;
  @override
  String toString() => message;
}

final RegExp libIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');
final RegExp versionIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$');

/// Parses manifest.json of a contract library.
Library parseManifest(String libDir, String root, String jsonText) {
  Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw LibraryLoadException('manifest.json 不是合法 JSON：${e.message}');
  }
  if (decoded is! Map<String, dynamic>) throw LibraryLoadException('manifest.json 顶层必须是对象');
  final m = decoded;
  String req(String k) {
    final v = m[k];
    if (v is! String || v.isEmpty) throw LibraryLoadException('manifest.json 缺少字段 $k');
    return v;
  }

  final id = req('id');
  final name = req('name');
  final versionsRaw = m['versions'];
  if (versionsRaw is! List || versionsRaw.isEmpty) throw LibraryLoadException('manifest.json 缺少 versions');
  final versions = <LibraryVersion>[];
  for (final v in versionsRaw) {
    if (v is! Map<String, dynamic>) continue;
    final vid = v['id'];
    if (vid is! String || vid.isEmpty) continue;
    final dir = (v['dir'] as String?) ?? vid;
    versions.add(LibraryVersion(
      id: vid,
      label: (v['label'] as String?) ?? vid,
      dir: dir,
      absDir: p.normalize(p.join(libDir, dir)),
      toc: parseToc(v['toc']),
      sourceUrl: v['sourceUrl'] as String?,
      scope: v['scope'] as String?,
      crawledAt: v['crawledAt'] as String?,
      translated: v['translated'] == true,
      pageCountHint: (v['pageCount'] as num?)?.toInt(),
    ));
  }
  if (versions.isEmpty) throw LibraryLoadException('manifest.json 中没有可用版本');
  var def = m['defaultVersion'] as String? ?? versions.first.id;
  if (!versions.any((v) => v.id == def)) def = versions.first.id;
  final icon = m['icon'] as String?;
  String? iconPath;
  if (icon != null && icon.isNotEmpty) {
    final abs = p.normalize(p.join(libDir, icon));
    if (p.isWithin(libDir, abs) && File(abs).existsSync()) iconPath = abs;
  }
  return Library(
    id: id,
    name: name,
    dir: libDir,
    root: root,
    format: LibraryFormat.contract,
    versions: versions,
    defaultVersionId: def,
    description: m['description'] as String?,
    homepage: m['homepage'] as String?,
    iconPath: iconPath,
    updatedAt: m['updatedAt'] as String?,
    sourceLanguage: m['sourceLanguage'] as String?,
  );
}

List<TocNode> parseToc(Object? raw) {
  if (raw is! List) return const [];
  final out = <TocNode>[];
  for (final n in raw) {
    if (n is! Map) continue;
    final title = n['title'];
    if (title is! String) continue;
    final page = n['page'];
    out.add(TocNode(
      title: title,
      page: page is String && page.isNotEmpty ? page.replaceAll('\\', '/') : null,
      icon: n['icon'] as String?,
      children: parseToc(n['children']),
    ));
  }
  return out;
}

/// Reads only the head of a file (enough for front matter and first heading).
String readHead(String path, {int maxBytes = 8192}) {
  final f = File(path).openSync();
  try {
    final len = f.lengthSync();
    final bytes = f.readSync(len < maxBytes ? len : maxBytes);
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    f.closeSync();
  }
}

/// Fills [LibraryVersion.pages] metadata from front matter (contract library).
/// Uses a lightweight line scanner for the common YAML keys so 5,000+ pages
/// hydrate rapidly without running a full YAML parser on every file.
void loadPageMetas(LibraryVersion v) {
  for (final page in v.orderedPages) {
    final abs = v.absPath(page);
    if (!p.isWithin(v.absDir, abs)) continue;
    try {
      final f = File(abs);
      if (!f.existsSync()) continue;
      final head = readHead(abs, maxBytes: 1024);
      final fast = _fastFrontMatter(head);
      if (fast != null) {
        v.pages[page] = PageMeta(
          path: page,
          title: fast.title ?? v.titleOf(page) ?? p.basenameWithoutExtension(page),
          sourceUrl: fast.sourceUrl,
          fetchedAt: fast.fetchedAt,
          original: fast.original,
          translated: fast.translated,
        );
      } else {
        final fm = parseFrontMatter(head);
        v.pages[page] = PageMeta(
          path: page,
          title: fm.str('title') ?? v.titleOf(page) ?? p.basenameWithoutExtension(page),
          sourceUrl: fm.str('source_url'),
          fetchedAt: fm.str('fetched_at'),
          original: fm.str('original'),
          translated: fm.boolean('translated') ?? false,
          tags: (fm.data['tags'] is List) ? (fm.data['tags'] as List).map((e) => e.toString()).toList() : const [],
        );
      }
    } catch (_) {
      // Missing / unreadable pages are reported by the validator.
    }
  }
}

({String? title, String? sourceUrl, String? fetchedAt, String? original, bool translated})? _fastFrontMatter(String head) {
  var src = head;
  if (src.startsWith('\uFEFF')) src = src.substring(1);
  if (!src.startsWith('---\n') && !src.startsWith('---\r\n')) return null;
  final endIdx = src.indexOf('\n---', 3);
  if (endIdx < 0) return null;
  final block = src.substring(4, endIdx);
  String? title, sourceUrl, fetchedAt, original;
  var translated = false;
  for (final rawLine in block.split('\n')) {
    final line = rawLine.trimRight();
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim();
    var val = line.substring(colon + 1).trim();
    if (val.length >= 2 && ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'")))) {
      val = val.substring(1, val.length - 1);
    }
    switch (key) {
      case 'title':
        title = val;
      case 'source_url':
        sourceUrl = val;
      case 'fetched_at':
        fetchedAt = val;
      case 'original':
        original = val;
      case 'translated':
        translated = val.toLowerCase() == 'true';
    }
  }
  return (title: title, sourceUrl: sourceUrl, fetchedAt: fetchedAt, original: original, translated: translated);
}

final RegExp _h1 = RegExp(r'^#\s+(.+?)\s*#*\s*$', multiLine: true);

/// Builds a single-version library from a folder of Markdown files.
Library buildPlainLibrary(String libDir, String root) {
  final id = p.basename(libDir);
  final rawToc = _plainToc(libDir, libDir);
  final metas = <String, PageMeta>{};
  for (final page in [for (final n in rawToc) ...n.walk().map((e) => e.page).whereType<String>()]) {
    final abs = p.normalize(p.join(libDir, page));
    String title = p.basenameWithoutExtension(page);
    String? sourceUrl;
    try {
      final head = readHead(abs);
      final fm = parseFrontMatter(head);
      final fmTitle = fm.str('title');
      sourceUrl = fm.str('source_url');
      if (fmTitle != null && fmTitle.isNotEmpty) {
        title = fmTitle;
      } else {
        final m = _h1.firstMatch(fm.body);
        if (m != null) title = m.group(1)!.replaceAll(RegExp(r'\s*\{#[^}]*\}$'), '');
      }
    } catch (_) {}
    metas[page] = PageMeta(path: page, title: title, sourceUrl: sourceUrl);
  }
  final version = LibraryVersion(
    id: 'default',
    label: 'default',
    dir: '.',
    absDir: libDir,
    toc: retitleToc(rawToc, metas),
  );
  version.pages.addAll(metas);
  return Library(
    id: id,
    name: id,
    dir: libDir,
    root: root,
    format: LibraryFormat.plain,
    versions: [version],
    defaultVersionId: 'default',
  );
}

bool _isOriginalVariant(String name) => name.toLowerCase().endsWith('.en.md');

List<TocNode> _plainToc(String base, String dir) {
  final entries = Directory(dir).listSync(followLinks: false);
  final dirs = <Directory>[];
  final files = <File>[];
  for (final e in entries) {
    final name = p.basename(e.path);
    if (name.startsWith('.')) continue;
    if (e is Directory) {
      if (name == 'assets' || name == 'node_modules') continue;
      dirs.add(e);
    } else if (e is File && name.toLowerCase().endsWith('.md') && !_isOriginalVariant(name)) {
      files.add(e);
    }
  }
  int byName(FileSystemEntity a, FileSystemEntity b) => naturalCompare(p.basename(a.path), p.basename(b.path));
  files.sort((a, b) {
    // index / README first
    int rank(File f) {
      final n = p.basenameWithoutExtension(f.path).toLowerCase();
      return n == 'index' || n == 'readme' ? 0 : 1;
    }

    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : byName(a, b);
  });
  dirs.sort(byName);
  final out = <TocNode>[];
  for (final f in files) {
    final rel = p.relative(f.path, from: base).replaceAll('\\', '/');
    out.add(TocNode(title: p.basenameWithoutExtension(f.path), page: rel));
  }
  for (final d in dirs) {
    final children = _plainToc(base, d.path);
    if (children.isEmpty) continue;
    out.add(TocNode(title: p.basename(d.path), children: children));
  }
  return out;
}

/// Replaces plain toc titles with page titles after metadata load.
List<TocNode> retitleToc(List<TocNode> toc, Map<String, PageMeta> metas) => [
      for (final n in toc)
        TocNode(
          title: n.page != null ? (metas[n.page!]?.title ?? n.title) : n.title,
          page: n.page,
          icon: n.icon,
          children: retitleToc(n.children, metas),
        ),
    ];

/// Whether the directory contains at least one .md file (recursively).
bool containsMarkdown(String dir) {
  try {
    for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
      if (e is File && e.path.toLowerCase().endsWith('.md')) return true;
    }
  } catch (_) {}
  return false;
}
