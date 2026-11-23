import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Minimal daily-rotated file logger. Keeps 7 days. Secrets are redacted.
class Log {
  static String? _dir;
  static IOSink? _sink;
  static String? _day;

  static void init(String logsDir) {
    _dir = logsDir;
    _cleanup();
  }

  static final RegExp _bearer = RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]+', caseSensitive: false);
  static final RegExp _skKey = RegExp(r'sk-[A-Za-z0-9_\-]{8,}');

  static String redact(String s) =>
      s.replaceAllMapped(_bearer, (m) => '${m.group(1)}***').replaceAll(_skKey, 'sk-***');

  static void info(String msg) => _write('INFO', msg);
  static void warn(String msg) => _write('WARN', msg);
  static void error(String msg, [Object? err, StackTrace? st]) {
    _write('ERROR', '$msg${err != null ? ': $err' : ''}${st != null ? '\n$st' : ''}');
  }

  /// Flushes buffered log output best-effort during lifecycle transitions.
  static void flushSyncBestEffort() {
    final sink = _sink;
    if (sink == null) return;
    try {
      unawaited(sink.flush().catchError((_) {}));
    } catch (_) {}
  }

  static void _write(String level, String msg) {
    final line = '${DateTime.now().toIso8601String()} [$level] ${redact(msg)}';
    // ignore: avoid_print
    assert(() { print(line); return true; }());
    final dir = _dir;
    if (dir == null) return;
    try {
      final now = DateTime.now();
      final day = '${now.year}${_two(now.month)}${_two(now.day)}';
      if (_day != day) {
        _sink?.close();
        _sink = File(p.join(dir, 'fldoc-$day.log')).openWrite(mode: FileMode.append);
        _day = day;
      }
      _sink!.writeln(line);
      if (level == 'WARN' || level == 'ERROR') {
        unawaited(_sink!.flush().catchError((_) {}));
      }
    } catch (_) {
      // logging must never throw
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static void _cleanup() {
    final dir = _dir;
    if (dir == null) return;
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final f in Directory(dir).listSync().whereType<File>()) {
        if (p.basename(f.path).startsWith('fldoc-') && f.statSync().modified.isBefore(cutoff)) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }
}
