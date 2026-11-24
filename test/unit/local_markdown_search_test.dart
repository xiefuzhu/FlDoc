import 'dart:io';

import 'package:fldoc/features/library/scanner.dart';
import 'package:fldoc/features/search/models.dart';
import 'package:fldoc/features/search/rg/rg_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('portable search groups bilingual results and preserves line context and UTF-16 highlights', () async {
    final root = Directory.systemTemp.createTempSync('fldoc_local_search_');
    addTearDown(() => root.deleteSync(recursive: true));
    final dir = Directory(p.join(root.path, 'sample'))..createSync();
    void write(String path, String text) {
      File(p.join(dir.path, path))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    }

    write('page.md', '# 快速开始\n前一行\n🚀 读取 Provider\n后一行\nproviderish');
    write('page.en.md', '# Getting Started\nprovider example');
    write('assets/hidden.md', 'Provider');
    write('.private.md', 'Provider');

    final library = LibraryScanner.loadLibrary(dir.path, root.path)!;
    final search = RgService.local();
    final result = await search.search(
      query: 'Provider',
      libraries: [library],
      scope: SearchScope.allLibraries,
      currentLang: 'zh',
      caseMode: 'ignore',
      wholeWord: true,
    );
    expect(result.error, isNull);
    expect(result.totalHits, 2);
    final group = result.groups.single;
    expect(group.page, 'page.md');
    final hit = group.hits.first;
    expect(hit.lineNumber, 3);
    expect(hit.contextBefore, ['前一行']);
    expect(hit.contextAfter, ['后一行']);
    final range = hit.submatches.single;
    expect(hit.lineText.substring(range.start, range.end), 'Provider');
    expect(group.hits.last.isOriginal, isTrue);

    final keywords = await search.searchKeywords(
      keywords: ['provider', '读取', 'missing'],
      searchDirs: [dir.path],
    );
    expect(keywords['provider'], hasLength(2));
    expect(keywords['读取']!.single.matches.single.lineNumber, 3);
    expect(keywords['missing'], isEmpty);
  });

  test('portable search uses the symbol regex fallback and stops cancelled requests', () async {
    final root = p.absolute('test', 'fixtures', 'libraries');
    final libraries = LibraryScanner.scan([root]).libraries;
    final search = RgService.local();
    final symbols = await search.searchCodeFallback(
      query: 'computeDelta',
      libraries: libraries,
      scope: SearchScope.allLibraries,
    );
    expect(symbols.single.snippet, contains('computeDelta'));

    final error = await search.search(
      query: '(',
      regex: true,
      libraries: libraries,
      scope: SearchScope.allLibraries,
      currentLang: 'zh',
    );
    expect(error.error, contains('搜索表达式无效'));

    final cancel = RgCancelToken();
    final pending = search.search(
      query: 'Provider',
      libraries: libraries,
      scope: SearchScope.allLibraries,
      currentLang: 'zh',
      cancelToken: cancel,
    );
    cancel.cancel();
    final result = await pending;
    expect(result.error, isNull);
    expect(result.groups, isEmpty);
  });
}
