import 'package:path/path.dart' as p;

enum LibraryFormat { contract, plain }

enum IssueLevel { error, warning }

/// A validation or load problem with location info.
class LibraryIssue {
  const LibraryIssue({
    required this.code,
    required this.level,
    required this.message,
    this.libId,
    this.versionId,
    this.file,
    this.page,
    this.line,
  });

  final String code; // V01..V20 or LOAD
  final IssueLevel level;
  final String message;
  final String? libId;
  final String? versionId;

  /// Absolute file path.
  final String? file;

  /// Page path relative to version dir (pages/...).
  final String? page;
  final int? line;

  bool get isError => level == IssueLevel.error;

  @override
  String toString() => '[$code ${isError ? 'E' : 'W'}] $message${file != null ? ' ($file${line != null ? ':$line' : ''})' : ''}';
}

class TocNode {
  TocNode({required this.title, this.page, this.children = const [], this.icon});

  final String title;

  /// Page path relative to the version dir (e.g. `pages/a/b.md`).
  final String? page;
  final List<TocNode> children;
  final String? icon;

  Iterable<TocNode> walk() sync* {
    yield this;
    for (final c in children) {
      yield* c.walk();
    }
  }
}

class PageMeta {
  PageMeta({
    required this.path,
    required this.title,
    this.sourceUrl,
    this.fetchedAt,
    this.original,
    this.translated = false,
    this.tags = const [],
  });

  /// Relative to version dir.
  final String path;
  final String title;
  final String? sourceUrl;
  final String? fetchedAt;

  /// Original-language file name in the same directory (contract `original`).
  final String? original;
  final bool translated;
  final List<String> tags;
}

class LibraryVersion {
  LibraryVersion({
    required this.id,
    required this.label,
    required this.dir,
    required this.absDir,
    required this.toc,
    this.sourceUrl,
    this.scope,
    this.crawledAt,
    this.translated = false,
    this.pageCountHint,
  });

  final String id;
  final String label;
  final String dir;

  /// Absolute directory of this version.
  final String absDir;
  final List<TocNode> toc;
  final String? sourceUrl;
  final String? scope;
  final String? crawledAt;
  final bool translated;
  final int? pageCountHint;

  /// Pages keyed by path, populated by the scanner (front matter metadata).
  final Map<String, PageMeta> pages = {};

  /// Pages in toc order (each at most once).
  late final List<String> orderedPages = () {
    final seen = <String>{};
    final out = <String>[];
    for (final n in toc) {
      for (final x in n.walk()) {
        final pg = x.page;
        if (pg != null && seen.add(pg)) out.add(pg);
      }
    }
    return out;
  }();

  String? get firstPage => orderedPages.isEmpty ? null : orderedPages.first;

  /// Directory that rg should search (pages/ for contract, version dir for plain).
  String get searchDir {
    final pagesDir = p.join(absDir, 'pages');
    return dir == '.' ? absDir : pagesDir;
  }

  String absPath(String page) => p.normalize(p.join(absDir, page));

  String? titleOf(String page) {
    final m = pages[page];
    if (m != null) return m.title;
    for (final n in toc) {
      for (final x in n.walk()) {
        if (x.page == page) return x.title;
      }
    }
    return null;
  }
}

class Library {
  Library({
    required this.id,
    required this.name,
    required this.dir,
    required this.root,
    required this.format,
    required this.versions,
    required this.defaultVersionId,
    this.description,
    this.homepage,
    this.iconPath,
    this.updatedAt,
    this.sourceLanguage,
  });

  final String id;
  final String name;

  /// Absolute library directory.
  final String dir;

  /// Library root this library was found in.
  final String root;
  final LibraryFormat format;
  final List<LibraryVersion> versions;
  final String defaultVersionId;
  final String? description;
  final String? homepage;

  /// Absolute icon path if present.
  final String? iconPath;
  final String? updatedAt;
  final String? sourceLanguage;

  /// Set by the scanner when another library with the same id exists in an
  /// earlier root (FR-LIB-07). Used as the unique key in that case.
  String? duplicateOfRoot;

  /// Warning shown on the card (e.g. manifest failed, stale state kept).
  String? loadWarning;

  /// Unique key across roots.
  String get key => duplicateOfRoot == null ? id : '$id@$root';

  LibraryVersion get defaultVersion =>
      versions.firstWhere((v) => v.id == defaultVersionId, orElse: () => versions.first);

  LibraryVersion? version(String id) {
    for (final v in versions) {
      if (v.id == id) return v;
    }
    return null;
  }

  int get pageCount => versions.fold(0, (a, v) => a + v.orderedPages.length);

  String? get latestCrawl {
    String? best;
    for (final v in versions) {
      final c = v.crawledAt;
      if (c != null && (best == null || c.compareTo(best) > 0)) best = c;
    }
    return best ?? updatedAt;
  }
}

/// A position in the library space.
class DocLocation {
  const DocLocation({
    required this.libKey,
    required this.versionId,
    required this.page,
    this.anchor,
    this.line,
    this.highlight,
  });

  final String libKey;
  final String versionId;
  final String page;
  final String? anchor;

  /// 1-based source line (search hit) to scroll to.
  final int? line;

  /// Text to highlight after opening.
  final String? highlight;

  DocLocation copyWith({String? anchor, int? line, String? highlight, bool clearExtras = false}) => DocLocation(
        libKey: libKey,
        versionId: versionId,
        page: page,
        anchor: clearExtras ? null : (anchor ?? this.anchor),
        line: clearExtras ? null : (line ?? this.line),
        highlight: clearExtras ? null : (highlight ?? this.highlight),
      );

  bool samePage(DocLocation o) => o.libKey == libKey && o.versionId == versionId && o.page == page;

  Map<String, dynamic> toJson() => {'lib': libKey, 'ver': versionId, 'page': page, 'anchor': ?anchor};

  static DocLocation? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final lib = j['lib'], ver = j['ver'], page = j['page'];
    if (lib is! String || ver is! String || page is! String) return null;
    return DocLocation(libKey: lib, versionId: ver, page: page, anchor: j['anchor'] as String?);
  }

  @override
  String toString() => '$libKey/$versionId/$page${anchor != null ? '#$anchor' : ''}';
}
