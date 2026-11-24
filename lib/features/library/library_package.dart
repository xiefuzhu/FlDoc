import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'scanner.dart';

/// A ZIP containing one library snapshot and a versioned package descriptor.
class LibraryPackage {
  static const suffix = '.fldoc.zip';
  static const _descriptor = 'fldoc-package.json';
  static const _format = 'fldoc.package/1';
  static const _payload = 'library';
  static const _maxBytes = 8 * 1024 * 1024 * 1024;
  static const _maxEntries = 100000;
  static const _ignored = {
    '.git',
    '.hg',
    '.svn',
    '.ds_store',
    'thumbs.db',
    'desktop.ini',
  };

  static String fileName(Library library) =>
      '${p.basename(library.dir)}$suffix';

  static Future<void> export(Library library, String destination) =>
      Isolate.run(() => _export(library, destination));

  /// Returns a root that the regular library scanner can load. A byte-for-byte
  /// repeat reuses the same root, while updated packages get their own root.
  static Future<({String root, String name})> importFile(
    String source,
    String storage,
  ) => Isolate.run(() => _importFile(source, storage));

  static void _export(Library library, String destination) {
    final directory = Directory(library.dir);
    final folder = p.basename(directory.path);
    _checkSegment(folder, libraryFolder: true);
    final source = directory.resolveSymbolicLinksSync();
    final target = File(destination);
    final parent = target.parent.resolveSymbolicLinksSync();
    if (p.equals(source, parent) || p.isWithin(source, parent)) {
      throw FormatException('请选择文档库目录以外的位置保存资料包');
    }

    final entries = <String, FileSystemEntity>{};
    final paths = <String, String>{};
    var bytes = 0;
    void collect(Directory dir) {
      final children = dir.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        final name = p.basename(child.path);
        if (_ignored.contains(name.toLowerCase()) || child is Link) continue;
        _checkSegment(name);
        final rel = p
            .split(p.relative(child.path, from: directory.path))
            .join('/');
        _recordPath(paths, rel, isFile: child is File);
        entries[rel] = child;
        if (child is File) bytes += child.lengthSync();
        if (entries.length >= _maxEntries || bytes > _maxBytes) {
          throw FormatException('文档库超过资料包大小限制');
        }
        if (child is Directory) collect(child);
      }
    }

    collect(directory);
    _checkLibrary(library, (path) => entries[path] is File);

    // Prepare the archive beside its destination and publish it in one rename.
    final staging = target.parent.createTempSync('.fldoc-export-');
    try {
      final temporary = File(p.join(staging.path, 'package.zip'));
      final output = OutputFileStream(temporary.path);
      try {
        final encoder = ZipEncoder(streamed: true)..startEncode(output);
        encoder.add(
          ArchiveFile.string(
            _descriptor,
            jsonEncode({'format': _format, 'folder': folder}),
          ),
        );
        for (final MapEntry(key: relative, value: entity) in entries.entries) {
          final path = '$_payload/$relative';
          if (entity is Directory) {
            encoder.add(ArchiveFile.directory(path));
          } else if (entity is File) {
            final input = InputFileStream(entity.path);
            try {
              encoder.add(
                ArchiveFile.stream(path, input)
                  ..lastModTime =
                      entity.lastModifiedSync().millisecondsSinceEpoch ~/ 1000,
              );
            } finally {
              input.closeSync();
            }
          }
        }
        encoder.endEncode();
      } finally {
        output.closeSync();
      }
      temporary.renameSync(target.path);
    } finally {
      staging.deleteSync(recursive: true);
    }
  }

  static Future<({String root, String name})> _importFile(
    String source,
    String storage,
  ) async {
    // ZIP headers and compression can add overhead to the payload.
    final file = File(source);
    if (file.lengthSync() > _maxBytes + (128 << 20)) {
      throw FormatException('资料包超过大小限制');
    }
    final hash = await sha256.bind(file.openRead()).first;
    final storageDir = Directory(storage)..createSync(recursive: true);
    final destination = p.join(storage, hash.toString());
    final input = InputFileStream(source);
    try {
      final files = <String, ZipFile?>{};
      final paths = <String, String>{};
      var total = 0;
      for (final header in ZipDirectory().headers(input, verify: true)) {
        final entry = header.file!
          ..verify = true
          ..throwOnError = true;
        final mode = (header.externalFileAttributes >> 16) & 0xf000;
        if (mode != 0 && mode != 0x4000 && mode != 0x8000 ||
            (entry.flags & 1) != 0 ||
            (header.compressionMethod != 0 && header.compressionMethod != 8)) {
          throw FormatException('资料包包含不支持的文件类型');
        }
        final isDirectory =
            entry.filename.endsWith('/') ||
            mode == 0x4000 ||
            (header.versionMadeBy >> 8 == 0 &&
                header.externalFileAttributes & 0x10 != 0);
        final name = entry.filename.endsWith('/')
            ? entry.filename.substring(0, entry.filename.length - 1)
            : entry.filename;
        _recordPath(paths, name, isFile: !isDirectory);
        if (files.containsKey(name) ||
            (name != _descriptor &&
                !name.startsWith('$_payload/') &&
                !(name == _payload && isDirectory))) {
          throw FormatException('资料包内有重名文件或无效目录：$name');
        }
        files[name] = isDirectory ? null : entry;
        final size = entry.uncompressedSize;
        if (size < 0 ||
            size > _maxBytes - total ||
            files.length > _maxEntries) {
          throw FormatException('资料包超过大小限制');
        }
        total += size;
      }
      final descriptor = files.remove(_descriptor);
      if (descriptor == null || descriptor.uncompressedSize > 16 * 1024) {
        throw FormatException('请选择 flDoc 导出的资料包');
      }
      final metadata = jsonDecode(
        utf8.decode(descriptor.getStream().toUint8List()),
      );
      if (metadata is! Map || metadata['format'] != _format) {
        throw FormatException('不支持此资料包版本');
      }
      final folder = metadata['folder'];
      if (folder is! String) throw FormatException('资料包缺少文档库目录名');
      _checkSegment(folder, libraryFolder: true);

      final existing = Directory(p.join(destination, folder));
      if (existing.existsSync()) {
        final library = LibraryScanner.loadLibrary(
          existing.path,
          destination,
          eagerPageMetas: false,
        );
        if (library != null) return (root: destination, name: library.name);
      }

      final staging = storageDir.createTempSync('.import-');
      try {
        final libraryDir = Directory(p.join(staging.path, folder))
          ..createSync();
        files.remove(_payload);
        for (final MapEntry(key: name, value: entry) in files.entries) {
          final relative = name.substring(_payload.length + 1);
          final target = p.joinAll([libraryDir.path, ...relative.split('/')]);
          if (entry == null) {
            Directory(target).createSync(recursive: true);
          } else {
            File(target).createSync(recursive: true, exclusive: true);
            final output = OutputFileStream(target);
            try {
              entry.decompress(output);
            } finally {
              output.closeSync();
            }
          }
        }
        final library = LibraryScanner.loadLibrary(
          libraryDir.path,
          staging.path,
          eagerPageMetas: false,
        );
        if (library == null) throw FormatException('资料包内没有文档库');
        _checkLibrary(library, (path) => files['$_payload/$path'] != null);
        try {
          staging.renameSync(destination);
        } on FileSystemException {
          // Another import of the same package can finish while this one extracts.
          if (!existing.existsSync()) rethrow;
        }
        return (root: destination, name: library.name);
      } finally {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      }
    } on ArchiveException {
      throw const FormatException('资料包已损坏或无法读取');
    } finally {
      input.closeSync();
    }
  }

  static void _checkLibrary(
    Library library,
    bool Function(String path) hasFile,
  ) {
    if (library.format == LibraryFormat.contract && !hasFile('manifest.json')) {
      throw FormatException('文档库缺少可打包的 manifest.json');
    }
    var hasPage = false;
    for (final version in library.versions) {
      final prefix = version.dir == '.' ? '' : '${version.dir}/';
      if (prefix.isNotEmpty) _pathSegments(version.dir);
      for (final page in version.orderedPages) {
        _pathSegments(page);
        if (hasFile('$prefix$page')) hasPage = true;
      }
    }
    if (!hasPage) throw FormatException('文档库没有可读取的页面');
  }

  static void _recordPath(
    Map<String, String> paths,
    String path, {
    required bool isFile,
  }) {
    final parts = _pathSegments(path);
    // Check explicit and implicit directories to catch case collisions and
    // file/directory conflicts even on case-sensitive devices.
    var current = '';
    for (var i = 0; i < parts.length; i++) {
      current += parts[i];
      final key = current.toLowerCase();
      if (i < parts.length - 1 || !isFile) current += '/';
      if (paths.putIfAbsent(key, () => current) != current) {
        throw FormatException('资料包内有跨平台重名路径：$path');
      }
    }
  }

  static List<String> _pathSegments(String path) {
    final parts = path.split('/');
    for (final part in parts) {
      _checkSegment(part);
    }
    return parts;
  }

  static final _forbidden = RegExp(r'[\x00-\x1f<>:"\\|?*]');
  static final _reserved = RegExp(
    r'^(CON|PRN|AUX|NUL|(?:COM|LPT)[1-9¹²³])$',
    caseSensitive: false,
  );

  static void _checkSegment(String name, {bool libraryFolder = false}) {
    if (name.isEmpty ||
        name.endsWith('.') ||
        name.endsWith(' ') ||
        name.contains('/') ||
        _forbidden.hasMatch(name) ||
        _reserved.hasMatch(name.split('.').first.trimRight()) ||
        (libraryFolder && name.startsWith('.'))) {
      throw FormatException('资料包包含不兼容的路径：$name');
    }
  }
}
