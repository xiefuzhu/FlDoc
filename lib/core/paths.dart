import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Application data locations. Call [AppPaths.init] once at startup.
class AppPaths {
  AppPaths._(this.supportDir, this.cacheDir, this.defaultLibraryDir);

  final String supportDir;
  final String cacheDir;
  final String defaultLibraryDir;

  static AppPaths? _instance;

  static AppPaths? get instanceOrNull => _instance;

  static AppPaths get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('AppPaths.init() has not been called');
    }
    return i;
  }

  static Future<AppPaths> init({
    String? overrideSupportDir,
    String? overrideCacheDir,
    String? overrideDefaultLibraryRoot,
  }) async {
    final envOverride = Platform.environment['FLDOC_SUPPORT_DIR'];
    final support = overrideSupportDir ??
        (envOverride != null && envOverride.trim().isNotEmpty ? envOverride.trim() : null) ??
        (await getApplicationSupportDirectory()).path;

    final cache = overrideCacheDir ?? await _resolveCacheDir(support, isOverride: overrideSupportDir != null);
    final defLib = overrideDefaultLibraryRoot ?? await _resolveDefaultLibraryDir(support);

    final paths = AppPaths._(support, cache, defLib);
    for (final d in [paths.supportDir, paths.cacheDir, paths.mermaidCacheDir, paths.logsDir]) {
      Directory(d).createSync(recursive: true);
    }
    _instance = paths;
    return paths;
  }

  static Future<String> _resolveCacheDir(String supportDir, {required bool isOverride}) async {
    if (isOverride || Platform.isWindows) {
      return p.join(supportDir, 'cache');
    }
    try {
      return (await getApplicationCacheDirectory()).path;
    } catch (_) {
      return p.join(supportDir, 'cache');
    }
  }

  static Future<String> _resolveDefaultLibraryDir(String supportDir) async {
    if (Platform.isWindows) {
      return _fallbackDefaultLibraryRoot();
    }
    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) return p.join(ext.path, 'flDocLibrary');
      } catch (_) {}
      try {
        final docs = await getApplicationDocumentsDirectory();
        return p.join(docs.path, 'flDocLibrary');
      } catch (_) {
        return p.join(supportDir, 'flDocLibrary');
      }
    }
    // macOS / Linux sandbox-friendly Documents directory.
    try {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, 'flDocLibrary');
    } catch (_) {
      final home = Platform.environment['HOME'];
      return p.join(home != null && home.isNotEmpty ? home : supportDir, 'flDocLibrary');
    }
  }

  static String _fallbackDefaultLibraryRoot() {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    return p.join(home, 'flDocLibrary');
  }

  /// For tests.
  static void setForTest(String dir) =>
      _instance = AppPaths._(dir, p.join(dir, 'cache'), p.join(dir, 'flDocLibrary'));

  String get settingsFile => p.join(supportDir, 'settings.json');
  String get credentialsFallbackFile => p.join(supportDir, 'credentials.dpapi');
  String get credentialsVaultFile => p.join(supportDir, 'credentials.vault');
  String get stateFile => p.join(supportDir, 'state.json');
  String get dbFile => p.join(supportDir, 'fldoc.db');
  String get mermaidCacheDir => p.join(cacheDir, 'mermaid');
  String get logsDir => p.join(supportDir, 'logs');

  /// Directory containing the running executable.
  static String get exeDir => p.dirname(Platform.resolvedExecutable);

  /// Search executable packaged alongside the app executable.
  static String get bundledRgPath => p.join(exeDir, Platform.isWindows ? 'rg.exe' : 'rg');

  /// Default library root (`%USERPROFILE%\flDocLibrary` on Windows; sandbox-safe Docs/Storage on macOS/Android).
  static String get defaultLibraryRoot => _instance?.defaultLibraryDir ?? _fallbackDefaultLibraryRoot();
}
