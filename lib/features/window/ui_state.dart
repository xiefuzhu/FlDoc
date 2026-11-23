import 'dart:async';
import 'dart:convert';

import '../../core/atomic_file.dart';
import '../../core/paths.dart';

/// Persisted UI state (state.json): window bounds, panel widths, last page.
class UiState {
  UiState(this._data);

  final Map<String, dynamic> _data;
  Timer? _saveTimer;

  static UiState load() {
    try {
      final path = AppPaths.instance.stateFile;
      final loaded = AtomicFile.readWithBackupFallback(path, isValid: _isValidStateJson);
      if (loaded != null) {
        final m = jsonDecode(loaded.text);
        if (m is Map<String, dynamic>) return UiState(m);
      }
    } catch (_) {}
    return UiState({});
  }

  static bool _isValidStateJson(String text) {
    try {
      return jsonDecode(text) is Map<String, dynamic>;
    } catch (_) {
      return false;
    }
  }

  /// Schedules a debounced write so resize/drag interactions stay responsive.
  void save() {
    if (AppPaths.instanceOrNull == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 150), saveSync);
  }

  /// Immediately persists UI state atomically (for shutdown / backgrounding / window close).
  void saveSync() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (AppPaths.instanceOrNull == null) return;
    try {
      AtomicFile.writeStringSync(AppPaths.instance.stateFile, jsonEncode(_data), keepBackup: true);
    } catch (_) {}
  }

  void dispose() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  T? get<T>(String key) {
    final v = _data[key];
    return v is T ? v : null;
  }

  void set(String key, Object? value) {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    save();
  }

  double get sidebarWidth => (get<num>('sidebarWidth') ?? 280).toDouble();
  set sidebarWidth(double v) => set('sidebarWidth', v);

  double get aiPanelWidth => (get<num>('aiPanelWidth') ?? 380).toDouble();
  set aiPanelWidth(double v) => set('aiPanelWidth', v);

  bool get aiPanelVisible => get<bool>('aiPanelVisible') ?? false;
  set aiPanelVisible(bool v) => set('aiPanelVisible', v);

  /// `{x, y, w, h, maximized}`.
  Map<String, dynamic>? get windowBounds => get<Map<String, dynamic>>('window');
  set windowBounds(Map<String, dynamic>? v) => set('window', v);

  List<String> get recentCommands => (get<List>('recentCommands') ?? const []).whereType<String>().toList();
  set recentCommands(List<String> v) => set('recentCommands', v);

  Map<String, dynamic>? get lastLocation => get<Map<String, dynamic>>('lastLocation');
  set lastLocation(Map<String, dynamic>? v) => set('lastLocation', v);

  String? get lastLibraryId => get<String>('lastLibraryId');
  set lastLibraryId(String? v) => set('lastLibraryId', v);
}
