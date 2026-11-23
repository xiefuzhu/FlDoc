import 'dart:convert';
import 'dart:io';

import 'package:fldoc/features/importer/prompt_builder.dart';
import 'package:fldoc/features/library/manifest_generator.dart';
import 'package:fldoc/features/library/manifest_parser.dart';
import 'package:fldoc/features/library/models.dart';
import 'package:fldoc/features/library/scanner.dart';
import 'package:fldoc/features/library/validator/library_validator.dart';
import 'package:fldoc/features/reader/links/link_resolver.dart';
import 'package:fldoc/features/reader/markdown/md_model.dart';
import 'package:fldoc/features/reader/markdown/md_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _sampleMd = '''---
title: 快速开始
source_url: https://riverpod.dev/docs/introduction/getting_started
---

## 安装依赖 {#install-dependencies}

在 `pubspec.yaml` 中添加 **riverpod** 依赖，参见[文档](../concepts/providers.md#what)。

```dart
void main() {
  runApp(ProviderScope(child: MyApp()));
}
```

> [!WARNING]
> 不要在 build 中创建 provider。

- [x] 已完成
- [ ] 未完成
  继续

| 名称 | 说明 |
|:----:|-----:|
| a | `x` |

\$\$
E = mc^2
\$\$

行内公式 \$a+b\$ 与 <kbd>Ctrl</kbd> 键。<span>raw</span>

## 安装依赖

```mermaid
graph TD; A-->B;
```
''';

void _writeValidBase(String root, {String dirName = 'demo'}) {
  final libDir = p.join(root, dirName);
  Directory(p.join(libDir, '1.0', 'pages')).createSync(recursive: true);
  Directory(p.join(libDir, '1.0', 'assets')).createSync(recursive: true);
  File(p.join(libDir, '1.0', 'assets', 'a.png')).writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
  File(p.join(libDir, '1.0', 'pages', 'index.md')).writeAsStringSync('''---
title: 首页
source_url: https://example.dev/docs/
source_lang: en
lang: zh-CN
translated: true
original: index.en.md
fetched_at: 2026-11-22T10:00:00+08:00
source_sha256: abc123
---

## 简介 {#intro}

欢迎阅读中文文档，参见[指南](guide.md#usage)和图片 ![图](../assets/a.png)。

```dart
final x = 1;
```
''');
  File(p.join(libDir, '1.0', 'pages', 'index.en.md')).writeAsStringSync('''---
title: Home
source_url: https://example.dev/docs/
lang: en
fetched_at: 2026-11-22T10:00:00+08:00
source_sha256: abc123
---

## Intro {#intro}

Welcome.
''');
  File(p.join(libDir, '1.0', 'pages', 'guide.md')).writeAsStringSync('''---
title: 指南
source_url: https://example.dev/docs/guide
source_lang: zh-CN
lang: zh-CN
translated: false
fetched_at: 2026-11-22T10:00:00+08:00
source_sha256: def456
---

## 使用方法 {#usage}

这是一段完整的中文说明内容。
''');
  File(p.join(libDir, '1.0', 'symbols.json')).writeAsStringSync(jsonEncode({
    'schema': 'fldoc.symbols/1',
    'symbols': [
      {'name': 'foo', 'kind': 'function', 'page': 'pages/guide.md', 'anchor': 'usage'},
    ],
  }));
  File(p.join(libDir, 'manifest.json')).writeAsStringSync(jsonEncode({
    'schema': 'fldoc.library/1',
    'id': dirName,
    'name': 'Demo',
    'sourceLanguage': 'en',
    'displayLanguage': 'zh-CN',
    'defaultVersion': '1.0',
    'updatedAt': '2026-11-22T10:00:00+08:00',
    'versions': [
      {
        'id': '1.0',
        'label': '1.0',
        'dir': '1.0',
        'sourceUrl': 'https://example.dev/docs/',
        'scope': 'https://example.dev/docs/',
        'crawledAt': '2026-11-22T10:00:00+08:00',
        'translated': true,
        'toc': [
          {'title': '首页', 'page': 'pages/index.md'},
          {'title': '指南', 'page': 'pages/guide.md'},
        ],
      },
    ],
  }));
}

Library _dummyLib(String libDir, String root, {String id = 'demo', String? dup}) => Library(
      id: id,
      name: id,
      dir: libDir,
      root: root,
      format: LibraryFormat.contract,
      versions: [
        LibraryVersion(id: '1.0', label: '1.0', dir: '1.0', absDir: p.join(libDir, '1.0'), toc: const []),
      ],
      defaultVersionId: '1.0',
    )..duplicateOfRoot = dup;

void main() {
  final fixturesRoot = p.normalize(p.join(Directory.current.path, 'test', 'fixtures', 'libraries'));
  late MdDocument parsed;
  late ScanResult fixturesScan;

  setUpAll(() {
    parsed = MdParser.parse(_sampleMd);
    fixturesScan = LibraryScanner.scan([fixturesRoot]);
  });

  group('MdParser', () {
    test('parses front matter, blocks, anchors, inline segments, and offsets', () {
      expect(parsed.frontMatter['title'], '快速开始');
      expect(parsed.bodyStartLine, 5);
      expect(parsed.blocks.map((b) => b.kind).toList(), [
        BlockKind.heading,
        BlockKind.paragraph,
        BlockKind.code,
        BlockKind.alert,
        BlockKind.list,
        BlockKind.table,
        BlockKind.math,
        BlockKind.paragraph,
        BlockKind.heading,
        BlockKind.mermaid,
      ]);
      expect(parsed.outline.map((o) => o.anchor), ['install-dependencies', '安装依赖']);
      expect(parsed.blockForAnchor('install-dependencies'), 0);
      expect(parsed.blockForLine(12), 2);

      final para = parsed.blocks[1].nodes.single as ParaNode;
      expect(para.run.segs.any((s) => s.styles.contains(SegStyle.code) && s.text == 'pubspec.yaml'), isTrue);
      expect(para.run.segs.any((s) => s.styles.contains(SegStyle.bold) && s.text == 'riverpod'), isTrue);
      expect(para.run.segs.firstWhere((s) => s.href != null).href, '../concepts/providers.md#what');
      expect((parsed.blocks[3].nodes.single as AlertNode).type, AlertType.warning);
      expect((parsed.blocks[4].nodes.single as ListNode).items.map((i) => i.checked), [true, false]);

      final table = parsed.blocks[5].nodes.single as TableNode;
      expect(table.aligns, [CellAlign.center, CellAlign.right]);
      expect((parsed.blocks[6].nodes.single as MathBlockNode).tex, 'E = mc^2');

      final inlinePara = parsed.blocks[7].nodes.single as ParaNode;
      expect(inlinePara.run.segs.any((s) => s.mathTex == 'a+b'), isTrue);
      expect(inlinePara.run.segs.any((s) => s.styles.contains(SegStyle.kbd) && s.text == 'Ctrl'), isTrue);

      for (final b in parsed.blocks) {
        for (final r in b.runs) {
          expect(b.plainText.substring(r.base, r.base + r.text.length), r.text);
        }
      }
    });

    test('parses setext headings, details, and html anchors', () {
      final setext = MdParser.parse('# Title\n\nPara\nSub\n---\n\ntext');
      expect(setext.outline.map((o) => (o.level, o.text)), [(1, 'Title'), (2, 'Para Sub')]);

      final det = MdParser.parse('<details>\n<summary>更多</summary>\n\n内容 **粗体**\n\n</details>\n');
      expect((det.blocks.single.nodes.single as DetailsNode).summary.text, '更多');

      final anch = MdParser.parse('<a id="legacy"></a>\n\nText here');
      expect(anch.blockForAnchor('legacy'), isNotNull);
    });
  });

  group('LibraryScanner, ManifestGenerator, LinkResolver & PromptBuilder', () {
    test('scans fixtures, resolves links/urls, and renders import prompt', () {
      expect(fixturesScan.errors, isEmpty);
      expect(fixturesScan.libraries.length, 2);

      final plain = fixturesScan.libraries.firstWhere((l) => l.id == 'plain-notes');
      expect(plain.format, LibraryFormat.plain);
      expect(plain.defaultVersion.orderedPages, ['README.md', 'guide/page2.md', 'guide/page10.md']);

      final riverpod = fixturesScan.libraries.firstWhere((l) => l.id == 'sample-riverpod');
      expect(riverpod.format, LibraryFormat.contract);
      expect(riverpod.defaultVersionId, '3.x');
      expect(riverpod.defaultVersion.pages['pages/index.md']?.original, 'index.en.md');

      final urls = UrlIndex()..addLibrary(riverpod);
      final cur = DocLocation(libKey: riverpod.key, versionId: '3.x', page: 'pages/concepts/reading.md');
      final rel = resolveLink('../index.en.md#install-dependencies', cur, riverpod.defaultVersion, urls);
      expect((rel as InternalLink).location.page, 'pages/index.md');
      expect(rel.location.anchor, 'install-dependencies');
      expect((resolveLink('#using-refwatch', cur, riverpod.defaultVersion, urls) as AnchorLink).anchor, 'using-refwatch');
      expect(resolveLink('../../../../Windows/win.ini', cur, riverpod.defaultVersion, urls), isA<InvalidLink>());
      expect(
        (resolveLink('http://www.riverpod.dev/docs/concepts/reading/#using-refwatch', cur, riverpod.defaultVersion, urls)
                as InternalLink)
            .location
            .page,
        'pages/concepts/reading.md',
      );
      expect(resolveLink('https://dart.dev/guides', cur, riverpod.defaultVersion, urls), isA<ExternalLink>());
      expect(resolveLink('javascript:alert(1)', cur, riverpod.defaultVersion, urls), isA<InvalidLink>());

      expect(PromptBuilder.deriveScope('https://riverpod.dev/docs/introduction/getting_started'),
          'https://riverpod.dev/docs/introduction/');
      expect(PromptBuilder.deriveLibId('https://docs.flutter.dev/ui'), 'flutter');
      final template = File(p.join(Directory.current.path, 'assets', 'prompts', 'import_prompt.md')).readAsStringSync();
      final params = ImportParams(
        sourceUrl: 'https://riverpod.dev/docs/introduction/getting_started',
        scope: 'https://riverpod.dev/docs/',
        libId: 'riverpod',
        libName: 'Riverpod',
        versionId: '3.x',
        versionLabel: '3.x',
        targetRoot: 'C:/Users/demo/flDocLibrary',
        maxPages: 250,
        translate: true,
      );
      expect(PromptBuilder.validate(params), isNull);
      final rendered = PromptBuilder.render(template, params);
      expect(PromptBuilder.findUnreplacedPlaceholders(rendered), isEmpty);
    });

    test('handles broken manifest fallback, duplicates, and manifest generation', () {
      final tmp = Directory.systemTemp.createTempSync('fldoc_lib_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final r1 = p.join(tmp.path, 'r1');
      final r2 = p.join(tmp.path, 'r2');
      final demoDir = p.join(r1, 'same-id');
      Directory(p.join(demoDir, '1.0', 'pages')).createSync(recursive: true);
      File(p.join(demoDir, '1.0', 'pages', 'index.md')).writeAsStringSync('# Hi');
      File(p.join(demoDir, 'manifest.json')).writeAsStringSync('''
{"schema":"fldoc.library/1","id":"same-id","name":"Demo","sourceLanguage":"zh-CN","displayLanguage":"zh-CN","defaultVersion":"1.0","updatedAt":"2026-11-22T10:00:00+08:00","versions":[{"id":"1.0","label":"1.0","dir":"1.0","sourceUrl":"","scope":"","crawledAt":"2026-11-22T10:00:00+08:00","translated":false,"toc":[{"title":"Home","page":"pages/index.md"}]}]}
''');
      final r2Plain = p.join(r2, 'same-id');
      Directory(r2Plain).createSync(recursive: true);
      final mdFile = File(p.join(r2Plain, 'README.md'))..writeAsStringSync('# 首页\n\n正文');

      final first = LibraryScanner.scan([r1, r2]);
      expect(first.libraries.length, 2);
      expect(first.libraries[0].duplicateOfRoot, isNull);
      expect(first.libraries[1].duplicateOfRoot, r2);

      // Corrupt manifest preserves previous good state.
      File(p.join(demoDir, 'manifest.json')).writeAsStringSync('{ broken json');
      final second = LibraryScanner.scan([r1], previous: {for (final l in first.libraries) l.dir: l});
      expect(second.libraries.single.loadWarning, isNotNull);
      expect(second.errors, isNotEmpty);

      // Generate manifest without mutating markdown.
      final manifest = ManifestGenerator.generate(first.libraries[1]);
      expect(manifest.existsSync(), isTrue);
      expect(mdFile.readAsStringSync(), '# 首页\n\n正文');
      expect(parseManifest(r2Plain, r2, manifest.readAsStringSync()).defaultVersion.orderedPages, ['README.md']);
    });
  });

  group('LibraryValidator (V01..V20)', () {
    test('clean fixture passes and rule violations V01..V20 are detected', () {
      final cleanLib = fixturesScan.libraries.firstWhere((l) => l.id == 'sample-riverpod');
      expect(LibraryValidator.validateLibrary(cleanLib, allLibraries: fixturesScan.libraries).issues, isEmpty);

      final tmp = Directory.systemTemp.createTempSync('fldoc_val_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      _writeValidBase(tmp.path);
      final libDir = p.join(tmp.path, 'demo');

      // Clean base passes.
      final baseScan = LibraryScanner.scan([tmp.path]);
      expect(LibraryValidator.validateLibrary(baseScan.libraries.single, allLibraries: baseScan.libraries).issues, isEmpty);

      // V01 wrong schema.
      File(p.join(libDir, 'manifest.json')).writeAsStringSync('{"schema":"wrong/1","id":"demo","versions":[]}');
      expect(LibraryValidator.validateLibrary(_dummyLib(libDir, tmp.path)).issues.any((i) => i.code == 'V01' && i.isError),
          isTrue);

      // Rewrite valid base & break V02..V20 cleanly in minimal steps.
      _writeValidBase(tmp.path);
      final mf = jsonDecode(File(p.join(libDir, 'manifest.json')).readAsStringSync()) as Map<String, dynamic>;
      mf['id'] = 'other-id';
      mf['defaultVersion'] = '9.9';
      (mf['versions'] as List).add({'id': '2.0', 'label': '2.0', 'dir': 'missing-dir', 'toc': []});
      (mf['versions'][0]['toc'] as List).addAll([
        {'title': 'Dup', 'page': 'pages/guide.md'},
        {'title': 'Missing', 'page': 'pages/nope.md'},
      ]);
      File(p.join(libDir, 'manifest.json')).writeAsStringSync(jsonEncode(mf));
      File(p.join(libDir, '1.0', 'pages', 'orphan.md')).writeAsStringSync('## 无 front matter {#orphan}\n');
      File(p.join(libDir, '1.0', 'pages', 'index.en.md')).writeAsStringSync('''---
title: Home
source_url: https://example.dev/docs/different
lang: en
fetched_at: 2026-11-22T10:00:00+08:00
source_sha256: abc
---

## Different {#other-id}
''');
      const badGuide = '''---
title: 指南
source_url: https://example.dev/docs/
source_lang: en
lang: zh-CN
translated: false
source_sha256: zzz
---

## 缺少锚点的标题

## 重复 {#dup}

## 重复二 {#dup}

See [broken](missing.md) and [bad anchor](index.md#nonexistent) and ![bad](../assets/nope.png).

```
no lang fence
```

<div>not whitelisted</div>

This paragraph is intentionally written completely in English prose without translation so that the validator flags rule seventeen automatically when scanning the page body.
''';
      File(p.join(libDir, '1.0', 'pages', 'guide.md')).writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(badGuide)]);
      File(p.join(libDir, '1.0', 'symbols.json')).writeAsStringSync(jsonEncode({
        'schema': 'fldoc.symbols/1',
        'symbols': [
          {'name': 'missingPageSym', 'kind': 'function', 'page': 'pages/missing.md'},
          {'name': 'badAnchorSym', 'kind': 'function', 'page': 'pages/index.md', 'anchor': 'does-not-exist'},
        ],
      }));

      final codes = LibraryValidator.validateLibrary(_dummyLib(libDir, tmp.path, id: 'other-id', dup: tmp.path))
          .issues
          .map((i) => i.code)
          .toSet();
      for (final expected in const [
        'V02', 'V03', 'V04', 'V05', 'V06', 'V07', 'V08', 'V09', 'V10',
        'V11', 'V12', 'V13', 'V14', 'V15', 'V16', 'V17', 'V18', 'V19', 'V20',
      ]) {
        expect(codes, contains(expected), reason: 'Missing rule $expected; got $codes');
      }
    });
  });
}
