import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'log.dart';

/// Cross-platform atomic file write, backup recovery, and path canonicalization.
class AtomicFile {
  AtomicFile._();

  /// Atomically writes [content] to [filePath] via a unique sibling `.tmp` file.
  ///
  /// When [keepBackup] is true and [filePath] already exists and is non-empty,
  /// preserves a `.bak` sibling copy before replacing the target.
  /// When [ownerOnly] is true on POSIX platforms (macOS/Android/Linux),
  /// applies `0600` permissions before moving into place.
  static void writeStringSync(
    String filePath,
    String content, {
    bool keepBackup = false,
    bool ownerOnly = false,
  }) {
    final target = File(filePath);
    target.parent.createSync(recursive: true);

    if (keepBackup) {
      _snapshotBackupBestEffort(target, ownerOnly: ownerOnly);
    }

    final tmp = File('$filePath.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      tmp.writeAsStringSync(content, flush: true);
      if (ownerOnly && !Platform.isWindows) {
        _chmod600BestEffort(tmp.path);
      }

      if (Platform.isWindows) {
        _replaceOnWindows(tmp, target, content);
      } else {
        _replaceOnPosix(tmp, target, content);
      }
    } finally {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// Reads [filePath] and validates it with [isValid], falling back to `.bak`
  /// if the primary file is missing, empty, or fails validation.
  static ({String text, bool recoveredFromBackup})? readWithBackupFallback(
    String filePath, {
    required bool Function(String text) isValid,
  }) {
    String? primaryText;
    final primary = File(filePath);
    if (primary.existsSync()) {
      try {
        primaryText = primary.readAsStringSync();
        if (primaryText.isNotEmpty && isValid(primaryText)) {
          return (text: primaryText, recoveredFromBackup: false);
        }
      } catch (e) {
        Log.warn('Failed reading $filePath ($e), checking backup');
      }
    }

    final bak = File('$filePath.bak');
    if (bak.existsSync()) {
      try {
        final bakText = bak.readAsStringSync();
        if (bakText.isNotEmpty && isValid(bakText)) {
          try {
            writeStringSync(filePath, bakText, keepBackup: false);
          } catch (e) {
            Log.warn('Failed restoring $filePath from backup: $e');
          }
          return (text: bakText, recoveredFromBackup: true);
        }
      } catch (e) {
        Log.warn('Failed reading backup ${bak.path}: $e');
      }
    }

    if (primaryText != null) {
      return (text: primaryText, recoveredFromBackup: false);
    }
    return null;
  }

  /// Resolves symlinks (such as macOS `/var` -> `/private/var`) and normalizes [path].
  static String canonicalizePath(String path) {
    final norm = p.normalize(path);
    try {
      return p.normalize(File(norm).resolveSymbolicLinksSync());
    } on FileSystemException {
      try {
        final parent = Directory(p.dirname(norm));
        if (parent.existsSync()) {
          return p.normalize(p.join(parent.resolveSymbolicLinksSync(), p.basename(norm)));
        }
      } catch (_) {}
      return norm;
    } catch (_) {
      return norm;
    }
  }

  static void _snapshotBackupBestEffort(File target, {required bool ownerOnly}) {
    try {
      if (!target.existsSync() || target.lengthSync() == 0) return;
      final bakPath = '${target.path}.bak';
      target.copySync(bakPath);
      if (ownerOnly && !Platform.isWindows) {
        _chmod600BestEffort(bakPath);
      }
    } catch (e) {
      Log.warn('Backup snapshot skipped for ${target.path}: $e');
    }
  }

  static void _chmod600BestEffort(String path) {
    try {
      Process.runSync('chmod', ['600', path]);
    } catch (_) {}
  }

  static void _replaceOnWindows(File tmp, File target, String content) {
    var replaced = false;
    var lastWinErr = 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      final pSrc = tmp.path.toNativeUtf16();
      final pDst = target.path.toNativeUtf16();
      try {
        final ok = MoveFileEx(
          pSrc,
          pDst,
          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        );
        if (ok != 0) {
          replaced = true;
          break;
        }
        lastWinErr = GetLastError();
      } finally {
        calloc.free(pSrc);
        calloc.free(pDst);
      }
      sleep(const Duration(milliseconds: 20));
    }
    if (!replaced) {
      Log.warn('MoveFileEx failed (err=$lastWinErr), falling back to direct write for ${target.path}');
      target.writeAsStringSync(content, flush: true);
    }
  }

  static void _replaceOnPosix(File tmp, File target, String content) {
    Object? lastErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        tmp.renameSync(target.path);
        return;
      } catch (e) {
        lastErr = e;
        sleep(const Duration(milliseconds: 15));
      }
    }
    Log.warn('renameSync failed ($lastErr), falling back to direct write for ${target.path}');
    target.writeAsStringSync(content, flush: true);
  }
}
