import '../library/models.dart';
import '../library/symbols.dart';

enum SearchScope { currentLibrary, allLibraries }

class SubmatchRange {
  const SubmatchRange(this.start, this.end);
  final int start;
  final int end;
}

class RgHit {
  const RgHit({
    required this.lineNumber,
    required this.lineText,
    required this.submatches,
    this.contextBefore = const [],
    this.contextAfter = const [],
    this.isHeadingHit = false,
    this.isOriginal = false,
  });

  /// 1-based line number in the matched file.
  final int lineNumber;
  final String lineText;
  final List<SubmatchRange> submatches;
  final List<String> contextBefore;
  final List<String> contextAfter;
  final bool isHeadingHit;
  final bool isOriginal;
}

class PageSearchGroup {
  const PageSearchGroup({
    required this.lib,
    required this.version,
    required this.page,
    required this.pageTitle,
    required this.hits,
    this.hasTitleHit = false,
    required this.hasHeadingHit,
    required this.hasCurrentLangHit,
    required this.tocOrder,
  });

  final Library lib;
  final LibraryVersion version;

  /// Canonical (Chinese) page path relative to version dir.
  final String page;
  final String pageTitle;
  final List<RgHit> hits;
  final bool hasTitleHit;
  final bool hasHeadingHit;
  final bool hasCurrentLangHit;
  final int tocOrder;
}

class RgSearchResult {
  const RgSearchResult({
    this.groups = const [],
    this.totalHits = 0,
    this.truncated = false,
    this.error,
  });

  final List<PageSearchGroup> groups;
  final int totalHits;
  final bool truncated;
  final String? error;
}

class SymbolSearchHit {
  const SymbolSearchHit({
    required this.lib,
    required this.version,
    required this.page,
    required this.pageTitle,
    required this.score,
    this.entry,
    this.line,
    this.snippet,
    this.isCodeFallback = false,
  });

  final Library lib;
  final LibraryVersion version;
  final String page;
  final String pageTitle;
  final int score;
  final SymbolEntry? entry;
  final int? line;
  final String? snippet;
  final bool isCodeFallback;

  String get displayName => entry?.display ?? snippet ?? pageTitle;
  String? get anchor => entry?.anchor;
}
