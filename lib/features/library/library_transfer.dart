import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/log.dart';
import '../../core/paths.dart';
import '../settings/settings_controller.dart';
import 'library_controller.dart';
import 'library_package.dart';
import 'models.dart';

final libraryTransferProvider = Provider(LibraryTransfer.new);

class LibraryTransfer {
  LibraryTransfer(this._ref);

  static const _androidLibraries = MethodChannel('dev.fldoc/libraries');
  final Ref _ref;
  bool _busy = false;

  Future<void> importPackage() => _run('导入', () async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: '导入资料包',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (picked == null) return;
    final source = picked.files.single.path;
    if (source == null) throw const FormatException('无法读取所选文件');
    final storage = p.join(AppPaths.instance.supportDir, 'imported_packages');
    _notice('正在导入资料包…');
    final ({String root, String name}) imported;
    try {
      imported = await LibraryPackage.importFile(source, storage);
    } finally {
      if (Platform.isAndroid) {
        try {
          await FilePicker.clearTemporaryFiles();
        } on PlatformException catch (error) {
          Log.warn('cannot clean up picked library package: $error');
        }
      }
    }
    if (!_ref.mounted) return;
    final root = imported.root.replaceAll('\\', '/');
    final roots = _ref.read(settingsProvider).libraryRoots;
    if (roots.any(
      (existing) => p.equals(p.normalize(existing), p.normalize(root)),
    )) {
      await _ref.read(libraryProvider.notifier).reload();
      _notice('「${imported.name}」已在文档库中');
    } else {
      _ref.read(settingsProvider.notifier).set('libraryRoots', [
        ...roots,
        root,
      ]);
      _notice('已导入「${imported.name}」');
    }
  });

  Future<void> exportPackage(Library library) => _run('导出', () async {
    final name = LibraryPackage.fileName(library);
    if (Platform.isAndroid) {
      final directory = await _newCacheDirectory();
      try {
        final source = p.join(directory.path, name);
        _notice('正在打包「${library.name}」…');
        await LibraryPackage.export(library, source);
        final saved = await _androidLibraries.invokeMethod<bool>(
          'savePackage',
          {'path': source, 'name': name},
        );
        if (saved == true) _notice('已导出「${library.name}」');
      } finally {
        await _deleteCacheDirectory(directory);
      }
    } else {
      final selected = await FilePicker.saveFile(
        dialogTitle: '导出资料包',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (selected == null) return;
      _notice('正在打包「${library.name}」…');
      if (Platform.isMacOS) {
        // The save panel grants access to the selected file in the sandbox.
        final directory = await _newCacheDirectory();
        try {
          final source = p.join(directory.path, name);
          await LibraryPackage.export(library, source);
          await File(source).openRead().pipe(File(selected).openWrite());
        } finally {
          await _deleteCacheDirectory(directory);
        }
      } else {
        await LibraryPackage.export(library, selected);
      }
      _notice('已导出至 $selected');
    }
  });

  Future<void> sharePackage(Library library, Rect? origin) => _run(
    '分享',
    () async {
      final directory = await _newCacheDirectory();
      var keepForRecipient = false;
      try {
        final path = p.join(directory.path, LibraryPackage.fileName(library));
        _notice('正在打包「${library.name}」…');
        await LibraryPackage.export(library, path);
        final result = await SharePlus.instance.share(
          ShareParams(
            title: library.name,
            files: [XFile(path, mimeType: 'application/zip')],
            sharePositionOrigin: origin,
          ),
        );
        // Some platforms cannot report a result. The receiving app may open the
        // shared path after the chooser returns, so retain it in the cache.
        keepForRecipient = result.status != ShareResultStatus.dismissed;
      } finally {
        if (!keepForRecipient) await _deleteCacheDirectory(directory);
      }
    },
  );

  Future<Directory> _newCacheDirectory() async {
    final cache = await Directory(
      p.join(AppPaths.instance.cacheDir, 'library-packages'),
    ).create(recursive: true);
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    await for (final item in cache.list(followLinks: false)) {
      if (item is Directory &&
          p.basename(item.path).startsWith('transfer-') &&
          (await item.stat()).modified.isBefore(cutoff)) {
        await _deleteCacheDirectory(item);
      }
    }
    return cache.createTemp('transfer-');
  }

  Future<void> _deleteCacheDirectory(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException catch (error) {
      Log.warn('cannot clean up library package: $error');
    }
  }

  Future<void> _run(String action, Future<void> Function() operation) async {
    if (_busy) {
      _notice('正在处理资料包，请稍候');
      return;
    }
    _busy = true;
    try {
      await operation();
    } catch (error, stack) {
      Log.error('library package $action failed', error, stack);
      final detail = switch (error) {
        FormatException() => '：${error.message}',
        PlatformException() when error.message != null => '：${error.message}',
        UnimplementedError() when action == '分享' => '：当前系统可以通过「导出资料包」保存文件后分享',
        _ => '',
      };
      _notice('$action资料包失败$detail', isError: true);
    } finally {
      _busy = false;
    }
  }

  void _notice(String message, {bool isError = false}) {
    if (_ref.mounted) {
      _ref.read(noticeProvider.notifier).show(message, isError: isError);
    }
  }
}

Rect? libraryShareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  return box is RenderBox && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
}
