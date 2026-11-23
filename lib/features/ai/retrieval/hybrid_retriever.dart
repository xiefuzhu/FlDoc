import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/log.dart';
import '../../library/models.dart';
import '../../reader/markdown/md_parser.dart';
import '../../search/models.dart';
import '../../search/rg/rg_service.dart';
import '../../search/symbols/symbol_index.dart';
import '../chunker.dart';
import '../client/openai_client.dart';
import '../index/embed_indexer.dart';

enum RetrievalSource { keyword, semantic, symbol }

class RetrievedChunk {
  const RetrievedChunk({
    required this.libKey,
    required this.libName,
    required this.versionId,
    required this.page,
    required this.pageTitle,
    required this.lang,
    required this.anchor,
    required this.breadcrumb,
    required this.text,
    required this.score,
    required this.sources,
  });

  final String libKey;
  final String libName;
  final String versionId;
  final String page;
  final String pageTitle;
  final String lang;
  final String anchor;
  final String breadcrumb;
  final String text;
  final double score;
  final Set<RetrievalSource> sources;

  String get mergeKey => '$libKey|$versionId|$page|$anchor';
}

class HybridSearchResult {
  const HybridSearchResult({
    this.chunks = const [],
    this.vectorNotice,
    this.rewrittenKeywords = const [],
    this.rewrittenSymbols = const [],
    this.error,
  });

  final List<RetrievedChunk> chunks;
  final String? vectorNotice;
  final List<String> rewrittenKeywords;
  final List<String> rewrittenSymbols;
  final String? error;
}

/// Hybrid retrieval: LLM query rewrite + parallel rg + vector TopN + symbol boost + RRF (doc 06 §4).
class HybridRetriever {
  HybridRetriever({
    required this.rgService,
    required this.symbolIndex,
    OpenAiClient? client,
  }) : _client = client ?? OpenAiClient();

  final RgService rgService;
  final SymbolIndex symbolIndex;
  final OpenAiClient _client;

  static const _rewriteSystemPrompt = '''你是文档检索助手。把用户的问题改写为用于全文检索的关键词。
只输出 JSON：{"keywords": [...], "symbols": [...]}。
keywords：3-8 个，中英文都要，包含同义词与英文技术术语；
symbols：问题中涉及的 API/类/函数名，没有则为空数组。''';

  /// Simple CJK/word fallback tokenizer when chat rewrite is unavailable or fails.
  static List<String> fallbackTokenize(String query) {
    final tokens = <String>{};
    // Split English identifiers / numbers and CJK runs.
    final matches = RegExp(r'[A-Za-z0-9_.\-]{2,}|[\u4E00-\u9FFF]{2,}').allMatches(query);
    for (final m in matches) {
      final t = m.group(0)!.trim();
      if (t.isNotEmpty) tokens.add(t);
    }
    if (tokens.isEmpty && query.trim().isNotEmpty) {
      tokens.add(query.trim());
    }
    return tokens.take(8).toList();
  }

  /// Parses JSON output from the rewrite model (tolerating markdown code fences).
  static ({List<String> keywords, List<String> symbols})? parseRewriteJson(String raw) {
    var s = raw.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(s);
    if (fence != null) s = fence.group(1)!.trim();
    final braceStart = s.indexOf('{');
    final braceEnd = s.lastIndexOf('}');
    if (braceStart >= 0 && braceEnd > braceStart) {
      s = s.substring(braceStart, braceEnd + 1);
    }
    try {
      final decoded = jsonDecode(s);
      if (decoded is! Map) return null;
      final kws = (decoded['keywords'] is List)
          ? (decoded['keywords'] as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).take(8).toList()
          : <String>[];
      final syms = (decoded['symbols'] is List)
          ? (decoded['symbols'] as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).take(6).toList()
          : <String>[];
      if (kws.isEmpty && syms.isEmpty) return null;
      return (keywords: kws, symbols: syms);
    } catch (_) {
      return null;
    }
  }

  /// Pure RRF fusion: `score(d) = Σ 1 / (60 + rank_i(d))` with bilingual merge (spec 06 §4.4).
  static List<RetrievedChunk> fuseRrf({
    required List<RetrievedChunk> rgList,
    required List<RetrievedChunk> vectorList,
    required List<RetrievedChunk> symbolList,
    required String preferredLang, // 'zh' | 'original'
    String? focusLibKey,
    String? focusPage,
    int limit = 20,
  }) {
    final scores = <String, double>{};
    final sources = <String, Set<RetrievalSource>>{};
    final bestDisplay = <String, RetrievedChunk>{};

    void accumulate(List<RetrievedChunk> list, RetrievalSource src, {double weight = 1.0}) {
      final seenInList = <String>{};
      var rank = 0;
      for (final ch in list) {
        final key = ch.mergeKey;
        if (!seenInList.add(key)) continue;
        rank++;
        scores[key] = (scores[key] ?? 0.0) + weight / (60.0 + rank);
        (sources[key] ??= <RetrievalSource>{}).add(src);
        final prev = bestDisplay[key];
        if (prev == null || (ch.lang == preferredLang && prev.lang != preferredLang)) {
          bestDisplay[key] = ch;
        }
      }
    }

    accumulate(rgList, RetrievalSource.keyword);
    accumulate(vectorList, RetrievalSource.semantic);
    accumulate(symbolList, RetrievalSource.symbol, weight: 1.25);

    // Optional boost for "AI: 就当前页提问".
    if (focusLibKey != null && focusPage != null) {
      for (final key in scores.keys) {
        final ch = bestDisplay[key]!;
        if (ch.libKey == focusLibKey && ch.page == focusPage) {
          scores[key] = scores[key]! + 0.03;
        }
      }
    }

    final merged = <RetrievedChunk>[
      for (final e in scores.entries)
        RetrievedChunk(
          libKey: bestDisplay[e.key]!.libKey,
          libName: bestDisplay[e.key]!.libName,
          versionId: bestDisplay[e.key]!.versionId,
          page: bestDisplay[e.key]!.page,
          pageTitle: bestDisplay[e.key]!.pageTitle,
          lang: bestDisplay[e.key]!.lang,
          anchor: bestDisplay[e.key]!.anchor,
          breadcrumb: bestDisplay[e.key]!.breadcrumb,
          text: bestDisplay[e.key]!.text,
          score: e.value,
          sources: sources[e.key]!,
        ),
    ];

    merged.sort((a, b) => b.score.compareTo(a.score));
    return merged.take(limit).toList();
  }

  /// Executes full hybrid retrieval.
  Future<HybridSearchResult> retrieve({
    required String query,
    required List<Library> libraries,
    required SearchScope scope,
    Library? currentLibrary,
    LibraryVersion? currentVersion,
    required String currentLang,
    required bool rewriteEnabled,
    required String chatBaseUrl,
    required String chatApiKey,
    required String chatModel,
    required Future<({List<VectorSearchHit> hits, String? notice})> Function(String q) vectorSearcher,
    DocLocation? focusPage,
    RgCancelToken? cancelToken,
    int limit = 20,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const HybridSearchResult();

    // Start vector search concurrently with query rewrite!
    final vectorFuture = vectorSearcher(q);

    // 1. Keyword rewrite via chat model (if configured & enabled).
    var keywords = <String>[];
    var symbols = <String>[];
    if (rewriteEnabled && chatBaseUrl.trim().isNotEmpty && chatModel.trim().isNotEmpty && chatApiKey.trim().isNotEmpty) {
      try {
        final raw = await _client.chatComplete(
          baseUrl: chatBaseUrl,
          apiKey: chatApiKey,
          model: chatModel,
          messages: [
            {'role': 'system', 'content': _rewriteSystemPrompt},
            {'role': 'user', 'content': q},
          ],
          temperature: 0.0,
          maxTokens: 256,
          timeout: const Duration(seconds: 15),
        );
        final parsed = parseRewriteJson(raw);
        if (parsed != null) {
          keywords = parsed.keywords;
          symbols = parsed.symbols;
        }
      } catch (e) {
        Log.warn('query rewrite failed, falling back to tokenizer: $e');
      }
    }
    if (keywords.isEmpty) {
      keywords = fallbackTokenize(q);
    }

    // Resolve target libraries/versions.
    final targets = <(Library lib, LibraryVersion ver, String dir)>[];
    if (scope == SearchScope.currentLibrary && currentLibrary != null) {
      final v = currentVersion ?? currentLibrary.defaultVersion;
      if (Directory(v.searchDir).existsSync()) targets.add((currentLibrary, v, v.searchDir));
    } else {
      for (final l in libraries) {
        final v = l.defaultVersion;
        if (Directory(v.searchDir).existsSync()) targets.add((l, v, v.searchDir));
      }
    }

    // 2. Parallel rg recall mapped to chunks.
    final rgHitsByKw = await rgService.searchKeywords(
      keywords: keywords,
      searchDirs: targets.map((t) => t.$3).toList(),
      cancelToken: cancelToken,
    );
    final rgChunks = _mapRgHitsToChunks(rgHitsByKw, targets);

    // 3. Symbol recall mapped to chunks.
    final symQueries = {...symbols};
    if (symQueries.isEmpty && RegExp(r'^[A-Za-z_][A-Za-z0-9_.]{1,40}$').hasMatch(q)) {
      symQueries.add(q);
    }
    final symbolChunks = _lookupSymbolChunks(symQueries, scope, currentLibrary, currentVersion);

    // 4. Await vector recall.
    final vecRes = await vectorFuture;
    final libMap = {for (final l in libraries) l.key: l};
    final vectorChunks = <RetrievedChunk>[];
    for (final vh in vecRes.hits) {
      final lib = libMap[vh.libKey];
      final ver = lib?.version(vh.versionId);
      vectorChunks.add(RetrievedChunk(
        libKey: vh.libKey,
        libName: lib?.name ?? vh.libKey,
        versionId: vh.versionId,
        page: vh.page,
        pageTitle: ver?.titleOf(vh.page) ?? p.basenameWithoutExtension(vh.page),
        lang: vh.lang,
        anchor: vh.anchor,
        breadcrumb: vh.breadcrumb,
        text: vh.text,
        score: vh.score,
        sources: const {RetrievalSource.semantic},
      ));
    }

    // 5. RRF fusion.
    final fused = fuseRrf(
      rgList: rgChunks,
      vectorList: vectorChunks,
      symbolList: symbolChunks,
      preferredLang: currentLang,
      focusLibKey: focusPage?.libKey,
      focusPage: focusPage?.page,
      limit: limit,
    );

    return HybridSearchResult(
      chunks: fused,
      vectorNotice: vecRes.notice,
      rewrittenKeywords: keywords,
      rewrittenSymbols: symbols,
    );
  }

  List<RetrievedChunk> _mapRgHitsToChunks(
    Map<String, List<RgRawFileHits>> hitsByKw,
    List<(Library lib, LibraryVersion ver, String dir)> targets,
  ) {
    final pageChunkCache = <String, List<DocChunk>>{};
    final chunkKws = <String, Set<String>>{};
    final chunkHits = <String, int>{};
    final chunkObj = <String, DocChunk>{};

    List<DocChunk> chunksOfFile(String filePath, Library lib, LibraryVersion ver, String canonicalPage, String lang) {
      return pageChunkCache.putIfAbsent(filePath, () {
        try {
          final text = File(filePath).readAsStringSync();
          final doc = MdParser.parse(text);
          final title = doc.frontMatter['title']?.toString() ?? ver.titleOf(canonicalPage) ?? p.basenameWithoutExtension(canonicalPage);
          return DocChunker.chunkDocument(
            libKey: lib.key,
            libName: lib.name,
            versionId: ver.id,
            page: canonicalPage,
            pageTitle: title,
            lang: lang,
            doc: doc,
          );
        } catch (_) {
          return const [];
        }
      });
    }

    for (final entry in hitsByKw.entries) {
      final kw = entry.key;
      for (final fh in entry.value) {
        final norm = p.normalize(fh.filePath);
        (Library, LibraryVersion, String, String)? mapped;
        for (final (lib, ver, _) in targets) {
          if (p.isWithin(ver.absDir, norm)) {
            var rel = p.relative(norm, from: ver.absDir).replaceAll('\\', '/');
            var lang = 'zh';
            if (rel.toLowerCase().endsWith('.en.md')) {
              lang = 'original';
              rel = '${rel.substring(0, rel.length - 6)}.md';
            }
            mapped = (lib, ver, rel, lang);
            break;
          }
        }
        if (mapped == null) continue;
        final chunks = chunksOfFile(norm, mapped.$1, mapped.$2, mapped.$3, mapped.$4);
        if (chunks.isEmpty) continue;
        for (final m in fh.matches) {
          DocChunk best = chunks.first;
          for (final ch in chunks) {
            if (m.lineNumber >= ch.startLine && m.lineNumber <= ch.endLine) {
              best = ch;
              break;
            }
          }
          final key = best.identityKey;
          chunkObj[key] = best;
          (chunkKws[key] ??= <String>{}).add(kw);
          chunkHits[key] = (chunkHits[key] ?? 0) + 1;
        }
      }
    }

    final rankedKeys = chunkObj.keys.toList()
      ..sort((a, b) {
        final kwCmp = chunkKws[b]!.length.compareTo(chunkKws[a]!.length);
        if (kwCmp != 0) return kwCmp;
        return chunkHits[b]!.compareTo(chunkHits[a]!);
      });

    return [
      for (final k in rankedKeys.take(50))
        RetrievedChunk(
          libKey: chunkObj[k]!.libKey,
          libName: chunkObj[k]!.libName,
          versionId: chunkObj[k]!.versionId,
          page: chunkObj[k]!.page,
          pageTitle: chunkObj[k]!.pageTitle,
          lang: chunkObj[k]!.lang,
          anchor: chunkObj[k]!.anchor,
          breadcrumb: chunkObj[k]!.breadcrumb,
          text: chunkObj[k]!.displayText,
          score: chunkKws[k]!.length * 10.0 + chunkHits[k]!,
          sources: const {RetrievalSource.keyword},
        ),
    ];
  }

  List<RetrievedChunk> _lookupSymbolChunks(
    Set<String> symbolNames,
    SearchScope scope,
    Library? currentLib,
    LibraryVersion? currentVer,
  ) {
    final out = <RetrievedChunk>[];
    for (final name in symbolNames) {
      final hits = symbolIndex.search(
        name,
        scope: scope,
        currentLibrary: currentLib,
        currentVersion: currentVer,
        limit: 5,
      );
      for (final h in hits) {
        final abs = h.version.absPath(h.page);
        if (!File(abs).existsSync()) continue;
        try {
          final doc = MdParser.parse(File(abs).readAsStringSync());
          final chunks = DocChunker.chunkDocument(
            libKey: h.lib.key,
            libName: h.lib.name,
            versionId: h.version.id,
            page: h.page,
            pageTitle: h.pageTitle,
            lang: 'zh',
            doc: doc,
          );
          if (chunks.isEmpty) continue;
          final matched = chunks.firstWhere(
            (c) => h.anchor != null && c.anchor == h.anchor,
            orElse: () => chunks.first,
          );
          out.add(RetrievedChunk(
            libKey: matched.libKey,
            libName: matched.libName,
            versionId: matched.versionId,
            page: matched.page,
            pageTitle: matched.pageTitle,
            lang: matched.lang,
            anchor: matched.anchor,
            breadcrumb: matched.breadcrumb,
            text: matched.displayText,
            score: h.score.toDouble(),
            sources: const {RetrievalSource.symbol},
          ));
        } catch (_) {}
      }
    }
    return out;
  }
}
