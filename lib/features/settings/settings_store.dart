import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/atomic_file.dart';
import '../../core/debounce.dart';
import '../../core/log.dart';
import 'settings_model.dart';

class SettingsLoadResult {
  SettingsLoadResult(this.settings, {this.error});

  final AppSettings? settings;

  /// Human readable error (Chinese) including line/column when JSON is invalid.
  final String? error;
}

/// Reads/writes settings.json and watches it for external edits.
class SettingsStore {
  SettingsStore(this.filePath);

  final String filePath;
  String? _lastWritten;
  StreamSubscription<FileSystemEvent>? _watchSub;
  final Debouncer _debounce = Debouncer(const Duration(milliseconds: 300));

  SettingsLoadResult load() {
    final loaded = AtomicFile.readWithBackupFallback(
      filePath,
      isValid: (text) => parse(text).settings != null,
    );
    if (loaded == null) {
      final s = AppSettings.defaultSettings();
      save(s);
      return SettingsLoadResult(s);
    }
    if (loaded.recoveredFromBackup) {
      Log.warn('Recovered settings.json from backup');
    }
    final res = parse(loaded.text);
    if (res.settings != null) {
      _lastWritten = loaded.text;
    }
    return res;
  }

  static SettingsLoadResult parse(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return SettingsLoadResult(null, error: 'settings.json 顶层必须是对象');
      }
      return SettingsLoadResult(AppSettings.fromJson(decoded));
    } on FormatException catch (e) {
      final pos = _lineCol(text, e.offset);
      return SettingsLoadResult(null, error: 'settings.json 格式错误（第 ${pos.$1} 行，第 ${pos.$2} 列）：${e.message}');
    }
  }

  static (int, int) _lineCol(String text, int? offset) {
    if (offset == null) return (1, 1);
    var line = 1;
    var col = 1;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        line++;
        col = 1;
      } else {
        col++;
      }
    }
    return (line, col);
  }

  void save(AppSettings s) {
    final text = '${s.toPrettyJson()}\n';
    _lastWritten = text;
    AtomicFile.writeStringSync(filePath, text, keepBackup: true);
  }

  /// Calls [onChange] when settings.json is modified by someone else.
  void watch(void Function(SettingsLoadResult result) onChange) {
    _watchSub?.cancel();
    if (Platform.isAndroid) return;
    final dir = Directory(AtomicFile.canonicalizePath(p.dirname(filePath)));
    if (!dir.existsSync()) return;
    final targetCanon = AtomicFile.canonicalizePath(filePath);
    _watchSub = dir.watch().listen((event) {
      if (p.equals(AtomicFile.canonicalizePath(event.path), targetCanon)) {
        _debounce(() {
          try {
            final text = File(filePath).readAsStringSync();
            if (text == _lastWritten) return;
            _lastWritten = text;
            onChange(parse(text));
          } catch (e) {
            Log.warn('settings reload failed: $e');
          }
        });
      }
    });
  }

  void dispose() {
    _watchSub?.cancel();
    _debounce.dispose();
  }
}
