import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../core/log.dart';
import 'manifest_parser.dart';
import 'models.dart';

class ScanResult {
  ScanResult(this.libraries, this.errors);

  final List<Library> libraries;

  /// Load problems keyed by library directory.
  final Map<String, String> errors;
}

/// Scans library roots. Pure function (runs in an isolate).
class LibraryScanner {
  /// Loads one library directory. Returns null when it is not a library.
  /// When [eagerPageMetas] is false, contract libraries skip scanning every
  /// page file on cold start (NFR-01) and hydrate metadata asynchronously.
  static Library? loadLibrary(String libDir, String root, {bool eagerPageMetas = true}) {
    final manifest = File(p.join(libDir, 'manifest.json'));
    if (manifest.existsSync()) {
      final lib = parseManifest(libDir, root, manifest.readAsStringSync());
      if (eagerPageMetas) {
        for (final v in lib.versions) {
          loadPageMetas(v);
        }
      }
      return lib;
    }
    if (containsMarkdown(libDir)) return buildPlainLibrary(libDir, root);
    return null;
  }

  /// Scans all roots. [previous] supplies last good state per directory so a
  /// broken manifest keeps the old library (FR-LIB-02).
  static ScanResult scan(
    List<String> roots, {
    Map<String, Library> previous = const {},
    Set<String>? onlyDirs,
    bool eagerPageMetas = true,
  }) {
    final libs = <Library>[];
    final errors = <String, String>{};
    final seenIds = <String, String>{};
    for (final root in roots) {
      final rootDir = Directory(root);
      if (!rootDir.existsSync()) continue;
      List<Directory> dirs;
      try {
        dirs = rootDir.listSync(followLinks: false).whereType<Directory>().toList()
          ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      } catch (e) {
        errors[root] = '无法读取库根目录：$e';
        continue;
      }
      for (final d in dirs) {
        final name = p.basename(d.path);
        if (name.startsWith('.')) continue;
        final dir = p.normalize(d.path);
        Library? lib;
        if (onlyDirs != null && !onlyDirs.contains(dir) && previous.containsKey(dir)) {
          lib = previous[dir];
        } else {
          try {
            lib = loadLibrary(dir, root, eagerPageMetas: eagerPageMetas);
          } catch (e) {
            final prev = previous[dir];
            errors[dir] = e.toString();
            if (prev != null) {
              prev.loadWarning = 'manifest 加载失败，显示上次成功的状态：$e';
              lib = prev;
            }
          }
        }
        if (lib == null) continue;
        final firstRoot = seenIds[lib.id];
        if (firstRoot != null) {
          lib.duplicateOfRoot = root;
        } else {
          lib.duplicateOfRoot = null;
          seenIds[lib.id] = root;
        }
        libs.add(lib);
      }
    }
    return ScanResult(libs, errors);
  }

  static Future<ScanResult> scanAsync(
    List<String> roots, {
    Map<String, Library> previous = const {},
    Set<String>? onlyDirs,
    bool eagerPageMetas = true,
  }) {
    return Isolate.run(() => scan(roots, previous: previous, onlyDirs: onlyDirs, eagerPageMetas: eagerPageMetas));
  }

  /// Hydrates front-matter [PageMeta] for all contract libraries in a background isolate.
  static Future<List<Library>> hydrateMetasAsync(List<Library> libraries) {
    return Isolate.run(() {
      for (final lib in libraries) {
        if (lib.format == LibraryFormat.contract) {
          for (final v in lib.versions) {
            if (v.pages.isEmpty) loadPageMetas(v);
          }
        }
      }
      return libraries;
    });
  }
}

/// Watches roots recursively and reports affected library directories after
/// a 1.5 s quiet period.
class LibraryWatcher {
  LibraryWatcher(this.onChanged, {this.delay = const Duration(milliseconds: 1500)});

  final void Function(Set<String> libDirs, bool rootsChanged) onChanged;
  final Duration delay;
  final List<StreamSubscription<FileSystemEvent>> _subs = [];
  final Set<String> _pending = {};
  bool _rootChanged = false;
  Timer? _timer;

  void watch(List<String> roots) {
    stop();
    // Android blocks or poorly supports recursive inotify on external storage; reload on resume instead.
    if (Platform.isAndroid) return;
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      try {
        _subs.add(dir.watch(recursive: true).listen((e) => _onEvent(root, e), onError: (Object e) {
          Log.warn('watch error on $root: $e');
        }));
      } catch (e) {
        Log.warn('cannot watch $root: $e');
      }
    }
  }

  void _onEvent(String root, FileSystemEvent e) {
    final rel = p.relative(e.path, from: root);
    if (rel.startsWith('..')) return;
    final parts = p.split(rel);
    if (parts.isEmpty || parts.first == '.') return;
    if (parts.length == 1) {
      // A library directory itself was created/removed/renamed.
      _rootChanged = true;
    }
    _pending.add(p.normalize(p.join(root, parts.first)));
    _timer?.cancel();
    _timer = Timer(delay, _flush);
  }

  void _flush() {
    final dirs = Set<String>.of(_pending);
    final rootChanged = _rootChanged;
    _pending.clear();
    _rootChanged = false;
    onChanged(dirs, rootChanged);
  }

  void stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _timer?.cancel();
  }
}
