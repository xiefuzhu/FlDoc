import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../library/library_controller.dart';
import '../../library/models.dart';
import '../../library/symbols.dart';
import '../../settings/settings_controller.dart';
import '../models.dart';
import '../rg/rg_service.dart';

class IndexedSymbol {
  IndexedSymbol({
    required this.lib,
    required this.version,
    required this.entry,
    required this.pageTitle,
  })  : nameLower = entry.name.toLowerCase(),
        qualifiedLower = entry.qualifiedName?.toLowerCase() ?? '',
        aliasesLower = entry.aliases.map((a) => a.toLowerCase()).toList(),
        acronym = _camelAcronym(entry.name),
        qualifiedAcronym = _camelAcronym(entry.qualifiedName ?? '');

  final Library lib;
  final LibraryVersion version;
  final SymbolEntry entry;
  final String pageTitle;
  final String nameLower;
  final String qualifiedLower;
  final List<String> aliasesLower;
  final String acronym;
  final String qualifiedAcronym;
}

String _camelAcronym(String s) {
  if (s.isEmpty) return '';
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    final prev = i > 0 ? s[i - 1] : '';
    final isUpper = c.toUpperCase() == c && c.toLowerCase() != c;
    final afterSep = prev == '.' || prev == '_' || prev == '-' || prev == ' ';
    if (i == 0 || isUpper || afterSep) {
      if (RegExp(r'[A-Za-z0-9]').hasMatch(c)) buf.write(c.toLowerCase());
    }
  }
  return buf.toString();
}

/// In-memory symbol index loaded from all libraries' `symbols.json`.
class SymbolIndex {
  final List<IndexedSymbol> _items = [];
  final Set<String> _versionsWithSymbols = {};

  int get length => _items.length;

  bool hasSymbolsFor(Library lib, LibraryVersion version) =>
      _versionsWithSymbols.contains('${lib.key}|${version.id}');

  void loadLibraries(List<Library> libraries) {
    _items.clear();
    _versionsWithSymbols.clear();
    for (final lib in libraries) {
      for (final v in lib.versions) {
        final file = File(p.join(v.absDir, 'symbols.json'));
        if (!file.existsSync()) continue;
        try {
          final parsed = parseSymbols(file.readAsStringSync());
          if (parsed.symbols.isNotEmpty) {
            _versionsWithSymbols.add('${lib.key}|${v.id}');
            for (final e in parsed.symbols) {
              _items.add(IndexedSymbol(
                lib: lib,
                version: v,
                entry: e,
                pageTitle: v.titleOf(e.page) ?? p.basenameWithoutExtension(e.page),
              ));
            }
          }
        } catch (_) {}
      }
    }
  }

  /// Scores and returns matching symbols from `symbols.json` (spec 06 §3).
  /// Score order: exact > prefix > camelCase acronym > substring > fuzzy.
  List<SymbolSearchHit> search(
    String query, {
    SearchScope scope = SearchScope.allLibraries,
    Library? currentLibrary,
    LibraryVersion? currentVersion,
    int limit = 50,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      // Return first N symbols in scope when query is empty.
      return _inScope(scope, currentLibrary, currentVersion)
          .take(limit)
          .map((it) => SymbolSearchHit(
                lib: it.lib,
                version: it.version,
                page: it.entry.page,
                pageTitle: it.pageTitle,
                score: 0,
                entry: it.entry,
              ))
          .toList();
    }

    final hits = <SymbolSearchHit>[];
    for (final it in _inScope(scope, currentLibrary, currentVersion)) {
      final score = scoreSymbol(q, it);
      if (score <= 0) continue;
      hits.add(SymbolSearchHit(
        lib: it.lib,
        version: it.version,
        page: it.entry.page,
        pageTitle: it.pageTitle,
        score: score,
        entry: it.entry,
      ));
    }
    hits.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      return a.displayName.length.compareTo(b.displayName.length);
    });
    return hits.take(limit).toList();
  }

  /// Searches symbols and falls back to ripgrep code-block matching if empty
  /// or if target library has no symbols.json.
  Future<List<SymbolSearchHit>> searchWithFallback(
    String query, {
    required List<Library> libraries,
    required SearchScope scope,
    Library? currentLibrary,
    LibraryVersion? currentVersion,
    String rgPath = '',
    RgCancelToken? cancelToken,
  }) async {
    final direct = search(query, scope: scope, currentLibrary: currentLibrary, currentVersion: currentVersion);
    if (direct.isNotEmpty || query.trim().isEmpty) return direct;
    final rg = RgService(configuredPath: rgPath);
    return rg.searchCodeFallback(
      query: query,
      libraries: libraries,
      scope: scope,
      currentLibrary: currentLibrary,
      currentVersion: currentVersion,
      cancelToken: cancelToken,
    );
  }

  Iterable<IndexedSymbol> _inScope(SearchScope scope, Library? currentLib, LibraryVersion? currentVer) {
    if (scope == SearchScope.currentLibrary && currentLib != null) {
      final vid = (currentVer ?? currentLib.defaultVersion).id;
      return _items.where((it) => it.lib.key == currentLib.key && it.version.id == vid);
    }
    return _items.where((it) => it.version.id == it.lib.defaultVersionId);
  }

  static int scoreSymbol(String q, IndexedSymbol it) {
    var best = 0;
    void check(int s) {
      if (s > best) best = s;
    }

    // 1. Exact
    if (it.nameLower == q) check(1000);
    if (it.qualifiedLower == q) check(980);
    for (final a in it.aliasesLower) {
      if (a == q) check(950);
    }

    // 2. Prefix
    if (it.nameLower.startsWith(q)) check(750);
    if (it.qualifiedLower.startsWith(q)) check(720);
    for (final a in it.aliasesLower) {
      if (a.startsWith(q)) check(700);
    }

    // 3. CamelCase acronym (e.g. PS -> ProviderScope)
    if (q.length >= 2) {
      if (it.acronym == q) check(580);
      if (it.acronym.startsWith(q)) check(540);
      if (it.qualifiedAcronym == q || it.qualifiedAcronym.startsWith(q)) check(520);
    }

    // 4. Substring
    if (it.nameLower.contains(q)) check(350);
    if (it.qualifiedLower.contains(q)) check(320);
    for (final a in it.aliasesLower) {
      if (a.contains(q)) check(300);
    }

    // 5. Fuzzy subsequence
    if (best == 0 && _isSubsequence(q, it.nameLower)) check(150);
    if (best == 0 && _isSubsequence(q, it.qualifiedLower)) check(120);

    return best;
  }

  static bool _isSubsequence(String needle, String haystack) {
    if (needle.isEmpty || haystack.isEmpty) return false;
    var j = 0;
    for (var i = 0; i < haystack.length && j < needle.length; i++) {
      if (haystack.codeUnitAt(i) == needle.codeUnitAt(j)) j++;
    }
    return j == needle.length;
  }
}

final symbolIndexProvider = Provider<SymbolIndex>((ref) {
  final libs = ref.watch(libraryProvider.select((s) => s.libraries));
  return SymbolIndex()..loadLibraries(libs);
});

final rgServiceProvider = Provider<RgService>((ref) {
  final rgPath = ref.watch(settingsProvider.select((s) => s.rgPath));
  return RgService(configuredPath: rgPath);
});
