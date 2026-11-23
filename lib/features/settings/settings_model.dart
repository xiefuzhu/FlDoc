import 'dart:convert';

import '../../core/paths.dart';

/// Settings document. Backed by a JSON map so unknown fields are preserved.
/// Values are addressed by dotted paths, e.g. `appearance.theme`.
class AppSettings {
  AppSettings._(this._data);

  final Map<String, dynamic> _data;

  static const int currentSchema = 1;

  static Map<String, dynamic> defaults() => {
        'schemaVersion': currentSchema,
        'oobeCompleted': false,
        'libraryRoots': [AppPaths.defaultLibraryRoot.replaceAll('\\', '/')],
        'appearance': {
          'theme': 'system',
          'accentColor': '#0078D4',
          'bodyFont': 'Microsoft YaHei UI',
          'codeFont': 'Cascadia Code',
          'fontSize': 15,
          'contentMaxWidth': 860,
        },
        'reading': {
          'language': 'zh',
          'fontScale': 1.0,
          'rememberPosition': true,
        },
        'sidebar': {
          'collapsedMode': 'hidden',
          'visible': true,
        },
        'window': {
          'alwaysOnTop': false,
          'opacity': 1.0,
          'closeToTray': true,
          'launchAtStartup': false,
        },
        'search': {
          'rgPath': '',
          'defaultScope': 'currentLibrary',
          'caseMode': 'smart',
          'maxResults': 300,
          'contextLines': 1,
          'debounceMs': 150,
        },
        'ai': {
          'chat': {
            'baseUrl': '',
            'model': '',
            'models': <String>[],
            'temperature': 0.2,
            'maxTokens': 2048,
            'rewriteQuery': true,
            'reasoningEffort': 'auto',
            'contextWindow': 274000,
          },
          'embedding': {
            'baseUrl': 'https://api.siliconflow.cn/v1',
            'model': 'BAAI/bge-m3',
            'batchSize': 32,
            'autoIndex': true,
          },
          'rag': {
            'topK': 8,
            'maxContextChars': 12000,
            'saveHistory': true,
          },
          'suggestOnNoResult': true,
        },
      };

  factory AppSettings.defaultSettings() => AppSettings._(defaults());

  /// Builds settings from user JSON: migrates, then fills missing values
  /// from defaults while keeping unknown fields.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final migrated = migrate(_deepCopy(json));
    return AppSettings._(_mergeDefaults(defaults(), migrated));
  }

  /// Schema migrations. Each step upgrades `schemaVersion` by one.
  static Map<String, dynamic> migrate(Map<String, dynamic> json) {
    var v = (json['schemaVersion'] as num?)?.toInt() ?? 0;
    if (v < 1) {
      // v0 -> v1: no structural changes; stamp the version.
      v = 1;
    }
    json['schemaVersion'] = v;
    return json;
  }

  static Map<String, dynamic> _mergeDefaults(Map<String, dynamic> defs, Map<String, dynamic> user) {
    final out = <String, dynamic>{};
    for (final e in defs.entries) {
      final uv = user[e.key];
      if (e.value is Map<String, dynamic>) {
        out[e.key] = _mergeDefaults(
          e.value as Map<String, dynamic>,
          uv is Map<String, dynamic> ? uv : <String, dynamic>{},
        );
      } else if (uv == null || !_sameKind(e.value, uv)) {
        out[e.key] = e.value;
      } else {
        out[e.key] = uv;
      }
    }
    for (final e in user.entries) {
      if (!defs.containsKey(e.key)) out[e.key] = e.value;
    }
    return out;
  }

  static bool _sameKind(Object? def, Object? v) {
    if (def is num) return v is num;
    if (def is bool) return v is bool;
    if (def is String) return v is String;
    if (def is List) return v is List;
    return true;
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> m) =>
      jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

  Map<String, dynamic> toJson() => _deepCopy(_data);

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(_data);

  Object? get(String path) {
    Object? cur = _data;
    for (final k in path.split('.')) {
      if (cur is Map<String, dynamic>) {
        cur = cur[k];
      } else {
        return null;
      }
    }
    return cur;
  }

  AppSettings copyWith(String path, Object? value) => copyWithMany({path: value});

  AppSettings copyWithMany(Map<String, Object?> updates) {
    final copy = _deepCopy(_data);
    for (final entry in updates.entries) {
      final keys = entry.key.split('.');
      Map<String, dynamic> cur = copy;
      for (final k in keys.take(keys.length - 1)) {
        final next = cur[k];
        if (next is Map<String, dynamic>) {
          cur = next;
        } else {
          final m = <String, dynamic>{};
          cur[k] = m;
          cur = m;
        }
      }
      cur[keys.last] = entry.value;
    }
    return AppSettings._(copy);
  }

  String _s(String p) => get(p) as String? ?? '';
  bool _b(String p) => get(p) as bool? ?? false;
  double _d(String p) => (get(p) as num?)?.toDouble() ?? 0;
  int _i(String p) => (get(p) as num?)?.toInt() ?? 0;

  bool get oobeCompleted => _b('oobeCompleted');
  List<String> get libraryRoots => (get('libraryRoots') as List?)?.whereType<String>().toList() ?? const [];

  String get theme => _s('appearance.theme');
  String get accentColor => _s('appearance.accentColor');
  String get bodyFont => _s('appearance.bodyFont');
  String get codeFont => _s('appearance.codeFont');
  double get fontSize => _d('appearance.fontSize');
  int get contentMaxWidth => _i('appearance.contentMaxWidth');

  String get language => _s('reading.language');
  double get fontScale => _d('reading.fontScale');
  bool get rememberPosition => _b('reading.rememberPosition');

  String get sidebarCollapsedMode => _s('sidebar.collapsedMode');
  bool get sidebarVisible => _b('sidebar.visible');

  bool get alwaysOnTop => _b('window.alwaysOnTop');
  double get opacity => _d('window.opacity');
  bool get closeToTray => _b('window.closeToTray');
  bool get launchAtStartup => _b('window.launchAtStartup');

  String get rgPath => _s('search.rgPath');
  String get defaultScope => _s('search.defaultScope');
  String get caseMode => _s('search.caseMode');
  int get maxResults => _i('search.maxResults');
  int get contextLines => _i('search.contextLines');
  int get debounceMs => _i('search.debounceMs');

  String get chatBaseUrl => _s('ai.chat.baseUrl');
  String get chatModel => _s('ai.chat.model');
  List<String> get chatModels => (get('ai.chat.models') as List?)?.whereType<String>().toList() ?? const [];
  double get chatTemperature => _d('ai.chat.temperature');
  int get chatMaxTokens => _i('ai.chat.maxTokens');
  bool get rewriteQuery => _b('ai.chat.rewriteQuery');
  String get chatReasoningEffort {
    final v = _s('ai.chat.reasoningEffort');
    return const {'auto', 'low', 'medium', 'high'}.contains(v) ? v : 'auto';
  }
  int get chatContextWindow => _i('ai.chat.contextWindow') == 500000 ? 500000 : 274000;
  String get embedBaseUrl => _s('ai.embedding.baseUrl');
  String get embedModel => _s('ai.embedding.model');
  int get embedBatchSize => _i('ai.embedding.batchSize');
  bool get autoIndex => _b('ai.embedding.autoIndex');
  int get ragTopK => _i('ai.rag.topK');
  int get ragMaxContextChars => _i('ai.rag.maxContextChars');
  bool get saveHistory => _b('ai.rag.saveHistory');
  bool get suggestOnNoResult => _b('ai.suggestOnNoResult');

  @override
  bool operator ==(Object other) => other is AppSettings && jsonEncode(_data) == jsonEncode(other._data);

  @override
  int get hashCode => jsonEncode(_data).hashCode;
}
