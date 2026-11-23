import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fldoc/app/providers.dart';
import 'package:fldoc/core/database.dart';
import 'package:fldoc/core/paths.dart';
import 'package:fldoc/features/ai/chunker.dart';
import 'package:fldoc/features/ai/client/openai_client.dart';
import 'package:fldoc/features/ai/history/chat_history.dart';
import 'package:fldoc/features/ai/index/embed_indexer.dart';
import 'package:fldoc/features/ai/retrieval/hybrid_retriever.dart';
import 'package:fldoc/features/library/library_controller.dart';
import 'package:fldoc/features/library/scanner.dart';
import 'package:fldoc/features/palette/fuzzy_match.dart';
import 'package:fldoc/features/reader/markdown/md_parser.dart';
import 'package:fldoc/features/search/models.dart';
import 'package:fldoc/features/search/rg/rg_service.dart';
import 'package:fldoc/features/search/symbols/symbol_index.dart';
import 'package:fldoc/features/settings/credential_store.dart';
import 'package:fldoc/features/settings/settings_controller.dart';
import 'package:fldoc/features/settings/settings_model.dart';
import 'package:fldoc/features/settings/settings_store.dart';
import 'package:fldoc/features/window/ui_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final fixturesRoot = p.normalize(p.join(Directory.current.path, 'test', 'fixtures', 'libraries'));
  late ScanResult scan;

  setUpAll(() => scan = LibraryScanner.scan([fixturesRoot]));

  test('fuzzy pinyin matching & RgJsonParser UTF-8 byte offsets', () {
    expect(pinyinInitials('全局搜索'), 'qjss');
    expect(fuzzyScore('qjss', '搜索: 全局搜索'), greaterThan(0));
    expect(fuzzyScore('qhzd', '窗口: 切换置顶'), greaterThan(0));
    expect(fuzzyScore('xyznotfound', '搜索: 全局搜索'), 0);

    const lineText = '使用 ProviderScope 监听状态\n';
    final byteStart = utf8.encode('使用 ').length;
    final byteEnd = byteStart + utf8.encode('ProviderScope').length;
    final parser = RgJsonParser(maxResults: 1)
      ..feedLine(jsonEncode({
        'type': 'begin',
        'data': {'path': {'text': 'pages/index.md'}},
      }));
    final hitLimit = parser.feedLine(jsonEncode({
      'type': 'match',
      'data': {
        'path': {'text': 'pages/index.md'},
        'lines': {'text': lineText},
        'line_number': 12,
        'submatches': [
          {'match': {'text': 'ProviderScope'}, 'start': byteStart, 'end': byteEnd},
        ],
      },
    }));
    expect(hitLimit, isTrue);
    final out = parser.finish();
    expect(out.truncated, isTrue);
    expect(out.files.single.matches.single.submatches.single.start, 3);
    expect(out.files.single.matches.single.submatches.single.end, 16);
  });

  test('rg.exe search & SymbolIndex scoring + fenced code fallback', () async {
    final rgRes = await RgService().search(
      query: 'ProviderScope',
      libraries: scan.libraries,
      scope: SearchScope.allLibraries,
      currentLang: 'zh',
    );
    expect(rgRes.error, isNull);
    expect(rgRes.totalHits, greaterThan(0));
    expect(rgRes.groups.any((g) => g.lib.id == 'sample-riverpod'), isTrue);

    final idx = SymbolIndex()..loadLibraries(scan.libraries);
    expect(idx.length, 2);
    expect(idx.search('watch').first.entry?.name, 'watch');
    expect(idx.search('PS').first.entry?.name, 'ProviderScope');

    final plain = scan.libraries.firstWhere((l) => l.id == 'plain-notes');
    final hits = await idx.searchWithFallback(
      'computeDelta',
      libraries: scan.libraries,
      scope: SearchScope.currentLibrary,
      currentLibrary: plain,
    );
    expect(hits.first.isCodeFallback, isTrue);
    expect(hits.first.page, 'README.md');
  });

  test('DocChunker, HybridRetriever RRF & vector math', () {
    final lib = scan.libraries.firstWhere((l) => l.id == 'sample-riverpod');
    final chunks = DocChunker.chunkVersion(lib, lib.defaultVersion);
    final intro = chunks.firstWhere((c) => c.lang == 'zh' && c.anchor == 'install-dependencies');
    expect(intro.embedText, contains('Riverpod'));
    expect(intro.embedText, isNot(contains('concepts/reading.md')));

    final longPara = '这是一个测试段落，用来验证超过一千五百字符时切块器会按块切分并保留相邻重叠。' * 20;
    final splitDoc = MdParser.parse('## 长章节 {#long}\n\n$longPara\n\n$longPara\n\n$longPara\n\n## 小节 {#tiny}\n\n短句。');
    expect(
      DocChunker.chunkDocument(
        libKey: 'k',
        libName: 'Lib',
        versionId: '1.0',
        page: 'pages/a.md',
        pageTitle: 'A',
        lang: 'zh',
        doc: splitDoc,
      ).length,
      greaterThanOrEqualTo(2),
    );

    RetrievedChunk mk(String page, String anchor, String lang, RetrievalSource s) => RetrievedChunk(
          libKey: 'lib',
          libName: 'Lib',
          versionId: '1',
          page: page,
          pageTitle: page,
          lang: lang,
          anchor: anchor,
          breadcrumb: anchor,
          text: '$lang:$anchor',
          score: 1,
          sources: {s},
        );
    final fused = HybridRetriever.fuseRrf(
      rgList: [mk('p1.md', 'a1', 'zh', RetrievalSource.keyword), mk('p2.md', 'a2', 'zh', RetrievalSource.keyword)],
      vectorList: [mk('p1.md', 'a1', 'original', RetrievalSource.semantic)],
      symbolList: [mk('p1.md', 'a1', 'zh', RetrievalSource.symbol)],
      preferredLang: 'zh',
    );
    expect(fused.first.page, 'p1.md');
    expect(fused.first.lang, 'zh');
    expect(fused.first.sources, {RetrievalSource.keyword, RetrievalSource.semantic, RetrievalSource.symbol});
    expect(HybridRetriever.parseRewriteJson('```json\n{"keywords":["状态"],"symbols":["Ref.watch"]}\n```')?.symbols,
        ['Ref.watch']);

    final vec = normalizeVector(decodeVector(normalizeAndEncodeVector(Float32List.fromList([3.0, 4.0]))));
    expect(vec[0], closeTo(0.6, 1e-5));
    expect(dotProduct(vec, vec), closeTo(1.0, 1e-5));
  });

  test('OpenAiClient mock server (models, embeddings, SSE reasoningEffort, 401) & ChatHistoryRepo', () async {
    Map<String, dynamic>? lastChatBody;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final baseUrl = 'http://127.0.0.1:${server.port}/v1';

    server.listen((req) async {
      if ((req.headers.value('authorization') ?? '') == 'Bearer bad-key') {
        req.response
          ..statusCode = 401
          ..write('{"error":{"message":"invalid key"}}');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/v1/models') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'data': [
              {'id': 'gpt-4o-mini'},
              {'id': 'deepseek-r1'},
            ],
          }));
      } else if (req.uri.path == '/v1/embeddings') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'data': [
              {'index': 0, 'embedding': [0.6, 0.8, 0.0]},
            ],
          }));
      } else if (req.uri.path == '/v1/chat/completions') {
        lastChatBody = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        req.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.add(utf8.encode('data: {"choices":[{"delta":{"reasoning_content":"思考中"}}]}\n\n'));
        req.response.add(utf8.encode('data: {"choices":[{"delta":{"content":"答案 42 [1]"}}]}\n\n'));
        req.response.add(utf8.encode('data: [DONE]\n\n'));
      }
      await req.response.close();
    });

    final client = OpenAiClient();
    expect(await client.listModels(baseUrl: baseUrl, apiKey: 'sk-test'), ['deepseek-r1', 'gpt-4o-mini']);
    expect((await client.testEmbedding(baseUrl: baseUrl, apiKey: 'sk-test', model: 'BAAI/bge-m3')).dim, 3);

    final deltas = await client
        .streamChat(
          baseUrl: baseUrl,
          apiKey: 'sk-test',
          model: 'deepseek-r1',
          messages: const [{'role': 'user', 'content': 'hi'}],
          reasoningEffort: 'auto',
        )
        .toList();
    expect(deltas.map((d) => d.reasoning).join(), '思考中');
    expect(deltas.map((d) => d.content).join(), '答案 42 [1]');
    expect(lastChatBody?.containsKey('reasoning_effort'), isFalse);

    await client
        .streamChat(
          baseUrl: baseUrl,
          apiKey: 'sk-test',
          model: 'deepseek-r1',
          messages: const [{'role': 'user', 'content': 'hi'}],
          reasoningEffort: 'high',
        )
        .toList();
    expect(lastChatBody?['reasoning_effort'], 'high');

    await expectLater(
      client.listModels(baseUrl: baseUrl, apiKey: 'bad-key'),
      throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.unauthorized)),
    );

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = ChatHistoryRepo(db);
    final now = DateTime.now().millisecondsSinceEpoch;
    repo.upsertSession(ChatSessionModel(
      id: 's1',
      title: '关于 ProviderScope',
      scope: const ChatScope(libId: 'riverpod', versionId: '3.x'),
      createdAt: now,
      updatedAt: now,
    ));
    repo.addMessage(ChatMessageModel(
      sessionId: 's1',
      role: 'assistant',
      content: '使用 ProviderScope [1]',
      citations: const [
        ChatCitation(
          index: 1,
          libKey: 'riverpod',
          libName: 'Riverpod',
          versionId: '3.x',
          page: 'pages/index.md',
          anchor: 'install-dependencies',
          title: '快速开始',
          breadcrumb: '安装依赖',
          snippet: 'ProviderScope',
        ),
      ],
      createdAt: now + 1,
    ));
    expect(repo.listSessions(query: 'ProviderScope').length, 1);
    expect(repo.loadMessages('s1').single.citations.single.anchor, 'install-dependencies');
    repo.deleteSession('s1');
    expect(repo.listSessions(), isEmpty);

    // Regression test: EmbedIndexer.searchVectors inside Riverpod Notifier must not capture `this` into Isolate.run.
    final tmp = Directory.systemTemp.createTempSync('fldoc_vec_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    AppPaths.setForTest(tmp.path);
    final vecDb = AppDatabase.inMemory();
    final ui = UiState({});
    final store = SettingsStore(p.join(tmp.path, 'settings.json'));
    store.save(
      AppSettings.defaultSettings()
          .copyWith('ai.embedding.baseUrl', baseUrl)
          .copyWith('ai.embedding.model', 'BAAI/bge-m3')
          .copyWith('ai.embedding.autoIndex', false)
          .copyWith('libraryRoots', <String>[]),
    );
    final creds = MemoryCredentialStore()..write(CredentialStore.embeddingTarget, 'sk-test');
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(vecDb),
        uiStateProvider.overrideWithValue(ui),
        windowServiceProvider.overrideWithValue(null),
        settingsStoreProvider.overrideWithValue(store),
        credentialStoreProvider.overrideWithValue(creds),
      ],
    );
    addTearDown(() {
      store.dispose();
      ui.dispose();
      container.dispose();
      vecDb.close();
    });

    final riverpod = scan.libraries.firstWhere((l) => l.id == 'sample-riverpod');
    final modelKey = '${OpenAiClient.normalizeBaseUrl(baseUrl)}::BAAI/bge-m3';
    vecDb.db.execute(
      'INSERT INTO chunk (lib_id, version_id, page_path, lang, anchor, breadcrumb, text, content_hash, embed_model, dim, vector, updated_at) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        riverpod.key,
        riverpod.defaultVersion.id,
        'pages/index.md',
        'zh',
        'install-dependencies',
        '安装依赖',
        '自定义文本框样式示例',
        'hash-1',
        modelKey,
        3,
        normalizeAndEncodeVector(Float32List.fromList([0.6, 0.8, 0.0])),
        1,
      ],
    );

    final vecRes = await container.read(embedIndexerProvider.notifier).searchVectors(
          query: '怎么自定义文本输入框样式',
          libraries: scan.libraries,
          currentLibrary: riverpod,
          allLibraries: false,
        );
    for (var i = 0; i < 20 && !container.read(libraryProvider).loadedOnce; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(vecRes.notice, isNull);
    expect(vecRes.hits.length, 1);
    expect(vecRes.hits.single.score, closeTo(1.0, 1e-5));
  });

  test('RgService ranks title and heading hits above anchorless catalog mentions', () async {
    final tmpLibRoot = Directory.systemTemp.createTempSync('fldoc_rg_rank_');
    addTearDown(() => tmpLibRoot.deleteSync(recursive: true));

    final pagesDir = Directory(p.join(tmpLibRoot.path, 'flutter', 'latest', 'pages'))..createSync(recursive: true);
    Directory(p.join(pagesDir.path, 'reference')).createSync(recursive: true);
    Directory(p.join(pagesDir.path, 'cookbook', 'forms')).createSync(recursive: true);
    Directory(p.join(pagesDir.path, 'widgets')).createSync(recursive: true);

    File(p.join(tmpLibRoot.path, 'flutter', 'manifest.json')).writeAsStringSync(jsonEncode({
      'schema': 'fldoc.library/1',
      'id': 'test-flutter',
      'name': 'Flutter',
      'sourceLanguage': 'en',
      'displayLanguage': 'zh-CN',
      'defaultVersion': 'latest',
      'versions': [
        {
          'id': 'latest',
          'label': 'latest',
          'dir': 'latest',
          'toc': [
            {'title': 'Flutter Widget 索引', 'page': 'pages/reference/widgets.md'},
            {'title': '创建并自定义文本输入框', 'page': 'pages/cookbook/forms/text-input.md'},
            {'title': 'TextField Widget', 'page': 'pages/widgets/textfield.md'},
          ],
        },
      ],
    }));

    File(p.join(pagesDir.path, 'reference', 'widgets.md')).writeAsStringSync(
      '---\ntitle: Flutter Widget 索引\n---\n\n'
      '[TextField](a.md) 文本输入框。[TextField](a.md) 支持定制。[TextField](a.md) 常用。\n'
      '[TextField](a.md) [TextField](a.md)\n',
    );
    File(p.join(pagesDir.path, 'cookbook', 'forms', 'text-input.md')).writeAsStringSync(
      '---\ntitle: 创建并自定义文本输入框\n---\n\n'
      '## TextField {#textfield}\n\n'
      '使用 TextField 组件接收用户输入。\n',
    );
    File(p.join(pagesDir.path, 'widgets', 'textfield.md')).writeAsStringSync(
      '---\ntitle: TextField Widget\n---\n\n'
      '# TextField\n\n'
      '基础文本输入组件。\n',
    );

    final rankScan = LibraryScanner.scan([tmpLibRoot.path]);
    final rgRes = await RgService().search(
      query: 'TextField',
      libraries: rankScan.libraries,
      scope: SearchScope.allLibraries,
      currentLang: 'zh',
    );

    expect(rgRes.error, isNull);
    expect(rgRes.groups.length, 3);
    expect(rgRes.groups[0].page, 'pages/widgets/textfield.md');
    expect(rgRes.groups[0].hasTitleHit, isTrue);
    expect(rgRes.groups[1].page, 'pages/cookbook/forms/text-input.md');
    expect(rgRes.groups[1].hasTitleHit, isFalse);
    expect(rgRes.groups[1].hasHeadingHit, isTrue);
    expect(rgRes.groups[2].page, 'pages/reference/widgets.md');
    expect(rgRes.groups[2].hasTitleHit, isFalse);
    expect(rgRes.groups[2].hasHeadingHit, isFalse);
  });
}
