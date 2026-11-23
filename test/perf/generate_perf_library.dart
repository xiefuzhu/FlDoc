import 'dart:convert';
import 'dart:io';

import 'package:fldoc/features/library/scanner.dart';
import 'package:fldoc/features/reader/markdown/md_parser.dart';
import 'package:fldoc/features/search/models.dart';
import 'package:fldoc/features/search/rg/rg_service.dart';
import 'package:path/path.dart' as p;

/// Generates a 5,000-page synthetic contract library and benchmarks NFR-01/02/03.
///
/// Usage: `dart run test/perf/generate_perf_library.dart [pageCount]`
Future<void> main(List<String> args) async {
  final pageCount = args.isNotEmpty ? (int.tryParse(args.first) ?? 5000) : 5000;
  final tmp = Directory.systemTemp.createTempSync('fldoc_perf_');
  try {
    final libDir = p.join(tmp.path, 'perf-docs');
    final verDir = p.join(libDir, '1.0');
    final pagesDir = p.join(verDir, 'pages');
    Directory(pagesDir).createSync(recursive: true);

    stdout.writeln('Generating $pageCount pages in $libDir ...');
    final toc = <Map<String, dynamic>>[];
    const chapters = 50;
    final perChapter = (pageCount / chapters).ceil();
    var written = 0;

    for (var c = 0; c < chapters && written < pageCount; c++) {
      final chDir = p.join(pagesDir, 'chapter-$c');
      Directory(chDir).createSync(recursive: true);
      final children = <Map<String, dynamic>>[];
      for (var j = 0; j < perChapter && written < pageCount; j++) {
        final rel = 'pages/chapter-$c/page-$j.md';
        final needle = written == pageCount ~/ 2 ? 'UNIQUE_BENCHMARK_TOKEN_FLDOC' : 'topic_$c';
        File(p.join(verDir, rel)).writeAsStringSync('''---
title: 章节 $c 页面 $j
source_url: https://perf.example.dev/docs/c$c/p$j
source_lang: en
lang: zh-CN
translated: false
fetched_at: 2026-11-22T10:00:00+08:00
source_sha256: deadbeef$written
---

## 概述 {#overview}

这是第 $written 页的测试正文，包含关键词 $needle 与示例代码。

```dart
void sampleFn$written() {
  print('$needle');
}
```
''');
        children.add({'title': '章节 $c 页面 $j', 'page': rel});
        written++;
      }
      toc.add({'title': '章节 $c', 'children': children});
    }

    File(p.join(libDir, 'manifest.json')).writeAsStringSync(jsonEncode({
      'schema': 'fldoc.library/1',
      'id': 'perf-docs',
      'name': 'Perf Docs',
      'sourceLanguage': 'en',
      'displayLanguage': 'zh-CN',
      'defaultVersion': '1.0',
      'updatedAt': '2026-11-22T10:00:00+08:00',
      'versions': [
        {
          'id': '1.0',
          'label': '1.0',
          'dir': '1.0',
          'sourceUrl': 'https://perf.example.dev/docs/',
          'scope': 'https://perf.example.dev/docs/',
          'crawledAt': '2026-11-22T10:00:00+08:00',
          'pageCount': written,
          'translated': false,
          'toc': toc,
        },
      ],
    }));

    // NFR-01: Cold scan of 5000 pages (< 2000ms target)
    final sw1 = Stopwatch()..start();
    final scan = LibraryScanner.scan([tmp.path], eagerPageMetas: false);
    sw1.stop();
    stdout.writeln('NFR-01 scan ($written pages): ${sw1.elapsedMilliseconds} ms (libs=${scan.libraries.length})');

    // NFR-02: Global search via rg.exe (< 300ms target)
    final rg = RgService();
    final sw2 = Stopwatch()..start();
    final res = await rg.search(
      query: 'UNIQUE_BENCHMARK_TOKEN_FLDOC',
      libraries: scan.libraries,
      scope: SearchScope.allLibraries,
      currentLang: 'zh',
    );
    sw2.stop();
    stdout.writeln('NFR-02 rg search ($written pages): ${sw2.elapsedMilliseconds} ms (hits=${res.totalHits})');

    // NFR-03: 10,000-line long page parse
    final longBuf = StringBuffer('---\ntitle: Long Page\n---\n\n');
    for (var i = 0; i < 1000; i++) {
      longBuf.writeln('## Section $i {#sec-$i}\n');
      longBuf.writeln('Paragraph line 1 for section $i with `inlineCode` and **bold** text.');
      longBuf.writeln('Paragraph line 2 for section $i.\n');
      longBuf.writeln('```dart\nfinal x$i = $i;\n// line 1\n// line 2\n```\n');
    }
    final longText = longBuf.toString();
    final lineCount = longText.split('\n').length;
    final sw3 = Stopwatch()..start();
    final doc = MdParser.parse(longText);
    sw3.stop();
    stdout.writeln('NFR-03 parse ($lineCount lines): ${sw3.elapsedMilliseconds} ms (blocks=${doc.blocks.length})');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}
