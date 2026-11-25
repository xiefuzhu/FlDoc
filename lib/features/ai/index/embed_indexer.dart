import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/log.dart';
import '../../library/library_controller.dart';
import '../../library/manifest_parser.dart';
import '../../library/models.dart';
import '../../settings/credential_store.dart';
import '../../settings/settings_controller.dart';
import '../chunker.dart';
import '../client/openai_client.dart';

enum IndexStateKind { unconfigured, idle, indexing, incomplete, ready, staleModel, failed }

enum _IndexRequest { automatic, manual, rebuild }

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
        IndexStateKind.incomplete => '未完成（$indexed/$total 块）',
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
  final _queuedLibs = <String, _IndexRequest>{};
  Future<void>? _drainFuture;
  ({int generation, String modelKey, bool configured})? _scope;
  bool _autoIndex = false;

  @override
  Map<String, LibraryIndexStatus> build() {
    ref.listen(libraryProvider.select((s) => s.generation), (_, _) => _syncStatuses());
    ref.listen(
      settingsProvider.select((s) => (s.embedBaseUrl, s.embedModel, s.autoIndex)),
      (_, _) => _syncStatuses(),
    );
    Future.microtask(_syncStatuses);
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

  /// Rechecks configuration after the embedding credential has been saved or removed.
  void refreshStatuses() => _syncStatuses(retryFailed: true);

  void _syncStatuses({bool retryFailed = false}) {
    if (!ref.mounted) return;
    final catalog = ref.read(libraryProvider);
    final configured = isConfigured;
    final scope = (generation: catalog.generation, modelKey: _currentModelKey(), configured: configured);
    final scopeChanged = _scope != scope;
    _scope = scope;
    final autoIndex = ref.read(settingsProvider).autoIndex;
    final autoEnabled = autoIndex && !_autoIndex;
    _autoIndex = autoIndex;

    if (scopeChanged) {
      final initial = configured
          ? const LibraryIndexStatus()
          : const LibraryIndexStatus(kind: IndexStateKind.unconfigured);
      state = {for (final lib in catalog.libraries) lib.key: initial};
    }
    if (!configured) return;
    for (final lib in catalog.libraries) {
      final kind = state[lib.key]?.kind;
      if (scopeChanged || (autoEnabled && kind != IndexStateKind.ready) ||
          (retryFailed && autoIndex && kind == IndexStateKind.failed)) {
        _queuedLibs.putIfAbsent(lib.key, () => _IndexRequest.automatic);
      }
    }
    if (_queuedLibs.isNotEmpty) unawaited(_drainQueue());
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
    return Isolate.run(() {
      if (lib.format == LibraryFormat.contract && version.pages.isEmpty) loadPageMetas(version);
      return DocChunker.chunkVersion(lib, version, strict: true);
    });
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
    _enqueueManual(lib, forceRebuild);
    await _drainQueue();
  }

  Future<void> indexAll(List<Library> libs, {bool forceRebuild = false}) async {
    if (!isConfigured) {
      refreshStatuses();
      return;
    }
    for (final lib in libs) {
      _enqueueManual(lib, forceRebuild);
    }
    await _drainQueue();
  }

  void _enqueueManual(Library lib, bool forceRebuild) {
    if (_queuedLibs[lib.key] == _IndexRequest.rebuild) return;
    _queuedLibs[lib.key] = forceRebuild ? _IndexRequest.rebuild : _IndexRequest.manual;
  }

  Future<void> _drainQueue() => _drainFuture ??= Future<void>.microtask(_runQueue).whenComplete(() {
    _drainFuture = null;
  });

  Future<void> _runQueue() async {
    while (ref.mounted && _queuedLibs.isNotEmpty) {
      final libKey = _queuedLibs.keys.first;
      final request = _queuedLibs.remove(libKey)!;
      final lib = ref.read(libraryProvider).byKey(libKey);
      if (lib != null && _scope?.configured == true) await _indexOne(lib, request);
    }
  }

  Future<void> _indexOne(Library lib, _IndexRequest request) async {
    final s = ref.read(settingsProvider);
    final apiKey = ref.read(credentialStoreProvider).read(CredentialStore.embeddingTarget) ?? '';
    if (s.embedBaseUrl.trim().isEmpty || s.embedModel.trim().isEmpty || apiKey.trim().isEmpty) {
      state = {...state, lib.key: const LibraryIndexStatus(kind: IndexStateKind.unconfigured)};
      return;
    }
    final scope = _scope!;
    final modelKey = scope.modelKey;
    final db = ref.read(databaseProvider).db;
    final allowEmbedding = request != _IndexRequest.automatic || s.autoIndex;
    var completed = 0;
    var total = 0;
    if (allowEmbedding) {
      state = {...state, lib.key: const LibraryIndexStatus(kind: IndexStateKind.indexing)};
    }

    try {
      final version = lib.defaultVersion;
      final chunks = await _chunkVersionInIsolate(lib, version);
      if (!ref.mounted || _scope != scope) return;

      if (request == _IndexRequest.rebuild) {
        db.execute('DELETE FROM chunk WHERE lib_id=?', [lib.key]);
      }

      final existingRows = db.select(
        'SELECT id, page_path, lang, anchor, content_hash FROM chunk WHERE lib_id=? AND version_id=? AND embed_model=?',
        [lib.key, version.id, modelKey],
      );
      final existingMap = {
        for (final row in existingRows)
          (row['page_path'], row['lang'], row['anchor'], row['content_hash']): row['id'],
      };

      final wantedKeys = <(String, String, String, String)>{};
      final pending = <DocChunk>[];
      for (final ch in chunks) {
        final key = (ch.page, ch.lang, ch.anchor, ch.contentHash);
        if (wantedKeys.add(key) && !existingMap.containsKey(key)) pending.add(ch);
      }
      total = wantedKeys.length;
      completed = total - pending.length;

      if (allowEmbedding) {
        db.execute('DELETE FROM chunk WHERE lib_id=? AND version_id=? AND embed_model != ?',
            [lib.key, version.id, modelKey]);
        for (final e in existingMap.entries) {
          if (!wantedKeys.contains(e.key)) db.execute('DELETE FROM chunk WHERE id=?', [e.value]);
        }
      }

      if (pending.isEmpty) {
        state = {
          ...state,
          lib.key: LibraryIndexStatus(kind: IndexStateKind.ready, indexed: completed, total: total),
        };
        return;
      }

      if (!allowEmbedding) {
        final staleModel = completed == 0 && db.select(
          'SELECT 1 FROM chunk WHERE lib_id=? AND version_id=? AND embed_model != ? LIMIT 1',
          [lib.key, version.id, modelKey],
        ).isNotEmpty;
        final kind = staleModel
            ? IndexStateKind.staleModel
            : completed > 0 ? IndexStateKind.incomplete : IndexStateKind.idle;
        state = {
          ...state,
          lib.key: LibraryIndexStatus(kind: kind, indexed: completed, total: total),
        };
        return;
      }

      state = {
        ...state,
        lib.key: LibraryIndexStatus(kind: IndexStateKind.indexing, indexed: completed, total: total),
      };

      final batchSize = s.embedBatchSize.clamp(1, 128);

      for (var i = 0; i < pending.length; i += batchSize) {
        if (!ref.mounted || _scope != scope) return;
        final batch = pending.sublist(i, math.min(i + batchSize, pending.length));
        final resp = await _embedWithRetry(
          baseUrl: s.embedBaseUrl,
          apiKey: apiKey,
          model: s.embedModel,
          inputs: batch.map((c) => c.embedText).toList(),
        );
        if (!ref.mounted || _scope != scope) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        db.execute('BEGIN');
        try {
          final stmt = db.prepare('''
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
          db.execute('COMMIT');
        } catch (e) {
          db.execute('ROLLBACK');
          rethrow;
        }

        completed += batch.length;
        state = {
          ...state,
          lib.key: LibraryIndexStatus(kind: IndexStateKind.indexing, indexed: completed, total: total),
        };
      }

      state = {
        ...state,
        lib.key: LibraryIndexStatus(kind: IndexStateKind.ready, indexed: completed, total: total),
      };
    } catch (e, st) {
      Log.error('embed index failed for ${lib.key}', e, st);
      if (!ref.mounted || _scope != scope) return;
      state = {
        ...state,
        lib.key: LibraryIndexStatus(kind: IndexStateKind.failed, indexed: completed, total: total, error: e.toString()),
      };
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
