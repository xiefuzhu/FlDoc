import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/log.dart';
import '../../library/library_controller.dart';
import '../../library/models.dart';
import '../../settings/credential_store.dart';
import '../../settings/settings_controller.dart';
import '../chunker.dart';
import '../client/openai_client.dart';

enum IndexStateKind { unconfigured, idle, indexing, ready, staleModel, failed }

class LibraryIndexStatus {
  const LibraryIndexStatus({
    this.kind = IndexStateKind.idle,
    this.indexed = 0,
    this.total = 0,
    this.error,
  });

  final IndexStateKind kind;
  final int indexed;
  final int total;
  final String? error;

  double get progress => total <= 0 ? 0 : (indexed / total).clamp(0.0, 1.0);
  int get percent => (progress * 100).round();

  String get label => switch (kind) {
        IndexStateKind.unconfigured => '未配置嵌入模型',
        IndexStateKind.idle => '待索引',
        IndexStateKind.indexing => '索引中 $percent%',
        IndexStateKind.ready => '已就绪（$total 块）',
        IndexStateKind.staleModel => '模型已变更，需重建',
        IndexStateKind.failed => '失败（${error ?? '未知错误'}）',
      };
}

class VectorSearchHit {
  const VectorSearchHit({
    required this.libKey,
    required this.versionId,
    required this.page,
    required this.lang,
    required this.anchor,
    required this.breadcrumb,
    required this.text,
    required this.score,
  });

  final String libKey;
  final String versionId;
  final String page;
  final String lang;
  final String anchor;
  final String breadcrumb;
  final String text;
  final double score;
}

/// L2-normalizes [v] in place and returns a little-endian float32 byte view.
Uint8List normalizeAndEncodeVector(Float32List v) {
  var normSq = 0.0;
  for (var i = 0; i < v.length; i++) {
    normSq += v[i] * v[i];
  }
  final norm = math.sqrt(normSq);
  final out = Float32List(v.length);
  if (norm > 1e-12) {
    final inv = 1.0 / norm;
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] * inv;
    }
  }
  final bd = ByteData(out.length * 4);
  for (var i = 0; i < out.length; i++) {
    bd.setFloat32(i * 4, out[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

Float32List decodeVector(Uint8List bytes) {
  final n = bytes.length ~/ 4;
  final out = Float32List(n);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getFloat32(i * 4, Endian.little);
  }
  return out;
}

Float32List normalizeVector(Float32List v) {
  var normSq = 0.0;
  for (var i = 0; i < v.length; i++) {
    normSq += v[i] * v[i];
  }
  final norm = math.sqrt(normSq);
  final out = Float32List(v.length);
  if (norm > 1e-12) {
    final inv = 1.0 / norm;
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] * inv;
    }
  }
  return out;
}

double dotProduct(Float32List a, Float32List b) {
  final len = a.length < b.length ? a.length : b.length;
  var sum = 0.0;
  for (var i = 0; i < len; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

class _StoredRow {
  _StoredRow(this.libKey, this.versionId, this.page, this.lang, this.anchor, this.breadcrumb, this.text, this.blob);
  final String libKey;
  final String versionId;
  final String page;
  final String lang;
  final String anchor;
  final String breadcrumb;
  final String text;
  final Uint8List blob;
}

final embedIndexerProvider = NotifierProvider<EmbedIndexer, Map<String, LibraryIndexStatus>>(EmbedIndexer.new);

/// Incremental background vector indexer backed by SQLite `chunk` table (doc 06 §6).
class EmbedIndexer extends Notifier<Map<String, LibraryIndexStatus>> {
  final OpenAiClient _client = OpenAiClient();
  bool _running = false;
  final Set<String> _queuedLibs = {};

  @override
  Map<String, LibraryIndexStatus> build() {
    ref.listen(libraryProvider.select((s) => s.generation), (_, _) => _onLibrariesUpdated());
    ref.listen(
      settingsProvider.select((s) => '${s.embedBaseUrl}|${s.embedModel}|${s.autoIndex}'),
      (_, _) => refreshStatuses(),
    );
    Future.microtask(() {
      refreshStatuses();
      _onLibrariesUpdated();
    });
    return const {};
  }

  bool get isConfigured {
    final s = ref.read(settingsProvider);
    final key = ref.read(credentialStoreProvider).read(CredentialStore.embeddingTarget);
    return s.embedBaseUrl.trim().isNotEmpty && s.embedModel.trim().isNotEmpty && key != null && key.trim().isNotEmpty;
  }

  String _currentModelKey() {
    final s = ref.read(settingsProvider);
    return '${OpenAiClient.normalizeBaseUrl(s.embedBaseUrl)}::${s.embedModel.trim()}';
  }

  /// Refreshes status badges from SQLite without making network requests.
  void refreshStatuses() {
    final libs = ref.read(libraryProvider).libraries;
    final configured = isConfigured;
    final db = ref.read(databaseProvider);
    final modelKey = _currentModelKey();
    final next = <String, LibraryIndexStatus>{};

    for (final lib in libs) {
      final existing = state[lib.key];
      if (existing != null && existing.kind == IndexStateKind.indexing) {
        next[lib.key] = existing;
        continue;
      }
      if (!configured) {
        next[lib.key] = const LibraryIndexStatus(kind: IndexStateKind.unconfigured);
        continue;
      }
      final rs = db.db.select(
        'SELECT embed_model, COUNT(*) AS cnt FROM chunk WHERE lib_id=? GROUP BY embed_model',
        [lib.key],
      );
      if (rs.isEmpty) {
        next[lib.key] = const LibraryIndexStatus(kind: IndexStateKind.idle);
      } else {
        var matching = 0;
        var stale = 0;
        for (final row in rs) {
          final m = row['embed_model'] as String? ?? '';
          final c = (row['cnt'] as num?)?.toInt() ?? 0;
          if (m == modelKey) {
            matching += c;
          } else {
            stale += c;
          }
        }
        if (stale > 0 && matching == 0) {
          next[lib.key] = LibraryIndexStatus(kind: IndexStateKind.staleModel, total: stale);
        } else if (matching > 0) {
          next[lib.key] = LibraryIndexStatus(kind: IndexStateKind.ready, indexed: matching, total: matching);
        } else {
          next[lib.key] = const LibraryIndexStatus(kind: IndexStateKind.idle);
        }
      }
    }
    state = next;
  }

  void _onLibrariesUpdated() {
    refreshStatuses();
    final s = ref.read(settingsProvider);
    if (!s.autoIndex || !isConfigured) return;
    final libs = ref.read(libraryProvider).libraries;
    for (final lib in libs) {
      _queuedLibs.add(lib.key);
    }
    _drainQueue();
  }

  /// Estimates total chunks across [libs] (used to confirm when > 20,000 chunks).
  Future<int> estimateChunkCount(List<Library> libs) => _estimateChunkCountInIsolate(libs);

  static Future<int> _estimateChunkCountInIsolate(List<Library> libs) {
    return Isolate.run(() {
      var total = 0;
      for (final lib in libs) {
        total += DocChunker.chunkVersion(lib, lib.defaultVersion).length;
      }
      return total;
    });
  }

  static Future<List<DocChunk>> _chunkVersionInIsolate(Library lib, LibraryVersion version) {
    return Isolate.run(() => DocChunker.chunkVersion(lib, version));
  }

  static Future<List<VectorSearchHit>> _scoreVectorsInIsolate(
    List<_StoredRow> rows,
    Float32List queryVec,
    int topN,
  ) {
    return Isolate.run(() {
      final out = <VectorSearchHit>[];
      for (final r in rows) {
        final vec = decodeVector(r.blob);
        final score = dotProduct(queryVec, vec);
        out.add(VectorSearchHit(
          libKey: r.libKey,
          versionId: r.versionId,
          page: r.page,
          lang: r.lang,
          anchor: r.anchor,
          breadcrumb: r.breadcrumb,
          text: r.text,
          score: score,
        ));
      }
      out.sort((a, b) => b.score.compareTo(a.score));
      return out.take(topN).toList();
    });
  }

  /// Queues a library for incremental indexing (or full rebuild when [forceRebuild] is true).
  Future<void> indexLibrary(Library lib, {bool forceRebuild = false}) async {
    if (!isConfigured) {
      state = {...state, lib.key: const LibraryIndexStatus(kind: IndexStateKind.unconfigured)};
      return;
    }
    if (forceRebuild) {
      ref.read(databaseProvider).db.execute('DELETE FROM chunk WHERE lib_id=?', [lib.key]);
    }
    _queuedLibs.add(lib.key);
    await _drainQueue();
  }

  Future<void> indexAll(List<Library> libs, {bool forceRebuild = false}) async {
    if (!isConfigured) {
      refreshStatuses();
      return;
    }
    if (forceRebuild) {
      ref.read(databaseProvider).db.execute('DELETE FROM chunk');
    }
    for (final lib in libs) {
      _queuedLibs.add(lib.key);
    }
    await _drainQueue();
  }

  Future<void> _drainQueue() async {
    if (_running) return;
    _running = true;
    try {
      while (_queuedLibs.isNotEmpty) {
        final libKey = _queuedLibs.first;
        _queuedLibs.remove(libKey);
        final lib = ref.read(libraryProvider).byKey(libKey);
        if (lib == null) continue;
        await _indexOne(lib);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _indexOne(Library lib) async {
    final s = ref.read(settingsProvider);
    final apiKey = ref.read(credentialStoreProvider).read(CredentialStore.embeddingTarget) ?? '';
    if (s.embedBaseUrl.trim().isEmpty || s.embedModel.trim().isEmpty || apiKey.trim().isEmpty) {
      state = {...state, lib.key: const LibraryIndexStatus(kind: IndexStateKind.unconfigured)};
      return;
    }
    final modelKey = _currentModelKey();
    final db = ref.read(databaseProvider);

    try {
      final version = lib.defaultVersion;
      final chunks = await _chunkVersionInIsolate(lib, version);

      // Purge chunks built with a different embedding model.
      db.db.execute('DELETE FROM chunk WHERE lib_id=? AND version_id=? AND embed_model != ?',
          [lib.key, version.id, modelKey]);

      // Fetch existing keys for this (lib, version, model).
      final existingRows = db.db.select(
        'SELECT id, page_path, lang, anchor, content_hash FROM chunk WHERE lib_id=? AND version_id=? AND embed_model=?',
        [lib.key, version.id, modelKey],
      );
      final existingMap = <String, int>{};
      for (final row in existingRows) {
        final k = '${row['page_path']}|${row['lang']}|${row['anchor']}|${row['content_hash']}';
        existingMap[k] = (row['id'] as num).toInt();
      }

      final wantedKeys = <String>{};
      final pending = <DocChunk>[];
      for (final ch in chunks) {
        final k = '${ch.page}|${ch.lang}|${ch.anchor}|${ch.contentHash}';
        wantedKeys.add(k);
        if (!existingMap.containsKey(k)) {
          pending.add(ch);
        }
      }

      // Delete obsolete chunks.
      for (final e in existingMap.entries) {
        if (!wantedKeys.contains(e.key)) {
          db.db.execute('DELETE FROM chunk WHERE id=?', [e.value]);
        }
      }

      final alreadyDone = chunks.length - pending.length;
      if (pending.isEmpty) {
        state = {
          ...state,
          lib.key: LibraryIndexStatus(kind: IndexStateKind.ready, indexed: chunks.length, total: chunks.length),
        };
        return;
      }

      state = {
        ...state,
        lib.key: LibraryIndexStatus(kind: IndexStateKind.indexing, indexed: alreadyDone, total: chunks.length),
      };

      final batchSize = s.embedBatchSize.clamp(1, 128);
      var completed = alreadyDone;

      for (var i = 0; i < pending.length; i += batchSize) {
        final batch = pending.sublist(i, math.min(i + batchSize, pending.length));
        final resp = await _embedWithRetry(
          baseUrl: s.embedBaseUrl,
          apiKey: apiKey,
          model: s.embedModel,
          inputs: batch.map((c) => c.embedText).toList(),
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        db.db.execute('BEGIN');
        try {
          final stmt = db.db.prepare('''
            INSERT OR REPLACE INTO chunk
              (lib_id, version_id, page_path, lang, anchor, breadcrumb, text, content_hash, embed_model, dim, vector, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
          ''');
          try {
            for (var j = 0; j < batch.length; j++) {
              final ch = batch[j];
              final blob = normalizeAndEncodeVector(resp.vectors[j]);
              stmt.execute([
                ch.libKey,
                ch.versionId,
                ch.page,
                ch.lang,
                ch.anchor,
                ch.breadcrumb,
                ch.displayText,
                ch.contentHash,
                modelKey,
                resp.dim,
                blob,
                now,
              ]);
            }
          } finally {
            stmt.close();
          }
          db.db.execute('COMMIT');
        } catch (e) {
          db.db.execute('ROLLBACK');
          rethrow;
        }

        completed += batch.length;
        state = {
          ...state,
          lib.key: LibraryIndexStatus(kind: IndexStateKind.indexing, indexed: completed, total: chunks.length),
        };
      }

      state = {
        ...state,
        lib.key: LibraryIndexStatus(kind: IndexStateKind.ready, indexed: chunks.length, total: chunks.length),
      };
    } catch (e, st) {
      Log.error('embed index failed for ${lib.key}', e, st);
      state = {...state, lib.key: LibraryIndexStatus(kind: IndexStateKind.failed, error: e.toString())};
    }
  }

  /// Exponential backoff retry up to 5 times on 429 / 5xx (spec 06 §6.2).
  Future<EmbedResponse> _embedWithRetry({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<String> inputs,
    OpenAiClient? clientOverride,
  }) async {
    final cli = clientOverride ?? _client;
    var attempt = 0;
    while (true) {
      try {
        return await cli.embed(baseUrl: baseUrl, apiKey: apiKey, model: model, inputs: inputs);
      } on AiException catch (e) {
        final retryable = e.kind == AiErrorKind.rateLimited || e.kind == AiErrorKind.server || e.kind == AiErrorKind.timeout;
        if (!retryable || attempt >= 4) rethrow;
        attempt++;
        final delayMs = 1000 * (1 << (attempt - 1));
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
  }

  /// Brute-force dot-product vector search inside an isolate (spec 06 §4.3).
  Future<({List<VectorSearchHit> hits, String? notice})> searchVectors({
    required String query,
    required List<Library> libraries,
    Library? currentLibrary,
    LibraryVersion? currentVersion,
    required bool allLibraries,
    int topN = 50,
    OpenAiClient? clientOverride,
  }) async {
    final s = ref.read(settingsProvider);
    final apiKey = ref.read(credentialStoreProvider).read(CredentialStore.embeddingTarget) ?? '';
    if (s.embedBaseUrl.trim().isEmpty || s.embedModel.trim().isEmpty || apiKey.trim().isEmpty) {
      return (hits: const <VectorSearchHit>[], notice: '向量索引不可用，仅关键词结果（未配置嵌入模型）');
    }

    final scopes = <(String libKey, String versionId)>[];
    if (!allLibraries && currentLibrary != null) {
      scopes.add((currentLibrary.key, (currentVersion ?? currentLibrary.defaultVersion).id));
    } else {
      for (final l in libraries) {
        scopes.add((l.key, l.defaultVersion.id));
      }
    }
    if (scopes.isEmpty) return (hits: const <VectorSearchHit>[], notice: null);

    // Check if any target library is currently indexing or failed.
    for (final (lk, _) in scopes) {
      final st = state[lk];
      if (st != null && st.kind == IndexStateKind.indexing) {
        return (hits: const <VectorSearchHit>[], notice: '向量索引构建中（${st.percent}%），当前为关键词结果');
      }
    }

    final db = ref.read(databaseProvider);
    final modelKey = _currentModelKey();

    // Embed the query.
    Float32List queryVec;
    int queryDim;
    try {
      final cli = clientOverride ?? _client;
      final res = await cli.embed(
        baseUrl: s.embedBaseUrl,
        apiKey: apiKey,
        model: s.embedModel,
        inputs: [query],
      );
      queryVec = normalizeVector(res.vectors.first);
      queryDim = res.dim;
    } catch (e) {
      return (hits: const <VectorSearchHit>[], notice: '向量检索失败（$e），当前仅关键词结果');
    }

    // Read candidate vectors from SQLite for matching model & dim.
    final rows = <_StoredRow>[];
    for (final (lk, vid) in scopes) {
      final rs = db.db.select(
        'SELECT lib_id, version_id, page_path, lang, anchor, breadcrumb, text, vector FROM chunk WHERE lib_id=? AND version_id=? AND embed_model=? AND dim=?',
        [lk, vid, modelKey, queryDim],
      );
      for (final r in rs) {
        final blob = r['vector'];
        if (blob is! Uint8List || blob.length != queryDim * 4) continue;
        rows.add(_StoredRow(
          r['lib_id'] as String,
          r['version_id'] as String,
          r['page_path'] as String,
          r['lang'] as String? ?? 'zh',
          r['anchor'] as String? ?? '',
          r['breadcrumb'] as String? ?? '',
          r['text'] as String? ?? '',
          blob,
        ));
      }
    }

    if (rows.isEmpty) {
      // Check if there was a failed status or empty index.
      final failed = scopes.map((e) => state[e.$1]).whereType<LibraryIndexStatus>().where((st) => st.kind == IndexStateKind.failed);
      if (failed.isNotEmpty) {
        return (hits: const <VectorSearchHit>[], notice: '向量索引构建失败（${failed.first.error}），仅关键词结果');
      }
      return (hits: const <VectorSearchHit>[], notice: '向量索引尚未就绪，当前仅关键词结果');
    }

    final scored = await _scoreVectorsInIsolate(rows, queryVec, topN);

    return (hits: scored, notice: null);
  }
}
