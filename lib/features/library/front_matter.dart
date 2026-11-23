import 'package:yaml/yaml.dart';

class FrontMatter {
  FrontMatter(this.data, this.body, this.bodyStartLine, {this.error, this.present = false});

  final Map<String, dynamic> data;
  final String body;

  /// 1-based line number in the file where [body] starts.
  final int bodyStartLine;
  final String? error;
  final bool present;

  String? str(String key) {
    final v = data[key];
    if (v == null) return null;
    return v.toString();
  }

  bool? boolean(String key) {
    final v = data[key];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true' ? true : (v.toLowerCase() == 'false' ? false : null);
    return null;
  }
}

/// Splits a Markdown file into YAML front matter and body.
FrontMatter parseFrontMatter(String text) {
  var src = text;
  if (src.startsWith('\uFEFF')) src = src.substring(1);
  final lines = src.split('\n');
  if (lines.isEmpty || lines.first.trimRight() != '---') {
    return FrontMatter({}, src, 1);
  }
  var end = -1;
  for (var i = 1; i < lines.length; i++) {
    final t = lines[i].trimRight();
    if (t == '---' || t == '...') {
      end = i;
      break;
    }
  }
  if (end < 0) {
    return FrontMatter({}, src, 1, error: 'front matter 未闭合', present: true);
  }
  final yamlText = lines.sublist(1, end).join('\n');
  final body = lines.sublist(end + 1).join('\n');
  try {
    final y = yamlText.trim().isEmpty ? null : loadYaml(yamlText);
    final map = <String, dynamic>{};
    if (y is YamlMap) {
      for (final e in y.entries) {
        map[e.key.toString()] = _plain(e.value);
      }
    } else if (y != null) {
      return FrontMatter({}, body, end + 2, error: 'front matter 不是键值映射', present: true);
    }
    return FrontMatter(map, body, end + 2, present: true);
  } on YamlException catch (e) {
    return FrontMatter({}, body, end + 2, error: 'front matter YAML 错误：${e.message}', present: true);
  }
}

Object? _plain(Object? v) {
  if (v is YamlMap) return {for (final e in v.entries) e.key.toString(): _plain(e.value)};
  if (v is YamlList) return v.map(_plain).toList();
  return v;
}
