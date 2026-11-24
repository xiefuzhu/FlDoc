import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fldoc/features/library/library_package.dart';
import 'package:fldoc/features/library/manifest_generator.dart';
import 'package:fldoc/features/library/models.dart';
import 'package:fldoc/features/library/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String storage;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fldoc_package_');
    storage = p.join(temp.path, 'imported');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('a contract library round-trips with versions, translations, symbols and assets', () async {
    final fixtures = p.absolute(p.join('test', 'fixtures', 'libraries'));
    final library = LibraryScanner.loadLibrary(
      p.join(fixtures, 'sample-riverpod'),
      fixtures,
    )!;
    final package = p.join(temp.path, LibraryPackage.fileName(library));
    await LibraryPackage.export(library, package);

    final imported = await LibraryPackage.importFile(package, storage);
    final restored = LibraryScanner.scan([imported.root]).libraries.single;
    expect(restored.id, library.id);
    expect(restored.name, library.name);
    expect(restored.defaultVersionId, library.defaultVersionId);
    expect(
      restored.versions.map((version) => version.id),
      library.versions.map((version) => version.id),
    );
    expect(
      restored.defaultVersion.pages['pages/index.md']?.original,
      'index.en.md',
    );

    for (final file in Directory(
      library.dir,
    ).listSync(recursive: true).whereType<File>()) {
      final relative = p.relative(file.path, from: library.dir);
      expect(
        File(p.join(restored.dir, relative)).readAsBytesSync(),
        file.readAsBytesSync(),
        reason: relative,
      );
    }

    final renamed = File(package)
        .renameSync(p.join(temp.path, 'received via sharing.zip'));
    expect(await LibraryPackage.importFile(renamed.path, storage), imported);
    expect(Directory(storage).listSync(), hasLength(1));
  });

  test(
    'plain Markdown keeps its directory name, links and binary files',
    () async {
      final dir = Directory(p.join(temp.path, '开发笔记'))..createSync();
      final markdown = File(p.join(dir.path, 'README.md'))
        ..writeAsStringSync('# 首页\n\n[下一章](章节/第二章.md)\n\n![图](assets/示意.png)');
      File(p.join(dir.path, '章节', '第二章.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# 第二章');
      final asset = File(p.join(dir.path, 'assets', '示意.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([0x81, 0, 0xff]);
      File(p.join(dir.path, '.git', 'config')).createSync(recursive: true);
      final library = LibraryScanner.loadLibrary(dir.path, temp.path)!;
      final package = p.join(temp.path, LibraryPackage.fileName(library));
      await LibraryPackage.export(library, package);

      final first = await LibraryPackage.importFile(package, storage);
      final restored = LibraryScanner.scan([first.root]).libraries.single;
      expect(restored.name, '开发笔记');
      expect(restored.format, LibraryFormat.plain);
      expect(restored.defaultVersion.orderedPages, ['README.md', '章节/第二章.md']);
      expect(
        File(p.join(restored.dir, 'assets', '示意.png')).readAsBytesSync(),
        asset.readAsBytesSync(),
      );
      expect(Directory(p.join(restored.dir, '.git')).existsSync(), isFalse);

      markdown.writeAsStringSync('# 更新');
      ManifestGenerator.generate(library);
      final contract = LibraryScanner.loadLibrary(dir.path, temp.path)!;
      await LibraryPackage.export(contract, package);
      final second = await LibraryPackage.importFile(package, storage);
      expect(second.root, isNot(first.root));
      expect(
        File(p.join(restored.dir, 'README.md')).readAsStringSync(),
        startsWith('# 首页'),
      );
      final updated = LibraryScanner.scan([second.root]).libraries.single;
      expect(updated.format, LibraryFormat.contract);
      expect(updated.defaultVersion.dir, '.');
      expect(File(p.join(updated.dir, 'README.md')).readAsStringSync(), '# 更新');
    },
  );

  test(
    'a malformed package leaves no installed library or partial import',
    () async {
      Future<void> reject(Iterable<ArchiveFile> entries) async {
        final archive = Archive();
        entries.forEach(archive.add);
        final bundle = File(p.join(temp.path, 'invalid.zip'))
          ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
        await expectLater(
          LibraryPackage.importFile(bundle.path, storage),
          throwsA(isA<FormatException>()),
        );
        expect(Directory(storage).listSync(), isEmpty);
      }

      const descriptor = 'fldoc-package.json';
      ArchiveFile metadata([String format = 'fldoc.package/1']) =>
          ArchiveFile.string(
            descriptor,
            '{"format":"$format","folder":"notes"}',
          );

      await reject([ArchiveFile.string('library/README.md', '# 普通 ZIP')]);
      await reject([
        metadata('fldoc.package/2'),
        ArchiveFile.string('library/README.md', '# 正文'),
      ]);
      await reject([
        metadata(),
        ArchiveFile.string('library/../outside.md', '# 无效路径'),
      ]);
      await reject([
        metadata(),
        ArchiveFile.string('library/a.md', '# 一'),
        ArchiveFile.string('library/A.md', '# 二'),
      ]);
      await reject([
        metadata(),
        ArchiveFile.string('library/assets/picture.png', 'no pages'),
      ]);
      await reject([
        metadata(),
        ArchiveFile.string('library/README.md', '# 正文'),
        ArchiveFile.string('library/manifest.json', '''
        {"id":"test","name":"Notes","versions":[
          {"id":"default","dir":"../../../","toc":[{"title":"Hello","page":"README.md"}]}
        ]}'''),
      ]);
    },
  );
}
