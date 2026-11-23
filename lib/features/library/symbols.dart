import 'dart:convert';

class SymbolEntry {
  SymbolEntry({
    required this.name,
    required this.kind,
    required this.page,
    this.qualifiedName,
    this.signature,
    this.anchor,
    this.summary,
    this.aliases = const [],
  });

  final String name;
  final String kind;
  final String page;
  final String? qualifiedName;
  final String? signature;
  final String? anchor;
  final String? summary;
  final List<String> aliases;

  String get display => qualifiedName ?? name;

  static SymbolEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], kind = j['kind'], page = j['page'];
    if (name is! String || kind is! String || page is! String) return null;
    return SymbolEntry(
      name: name,
      kind: kind,
      page: page,
      qualifiedName: j['qualifiedName'] as String?,
      signature: j['signature'] as String?,
      anchor: j['anchor'] as String?,
      summary: j['summary'] as String?,
      aliases: (j['aliases'] is List) ? (j['aliases'] as List).whereType<String>().toList() : const [],
    );
  }
}

const symbolKinds = {
  'class', 'function', 'method', 'property', 'constructor', 'enum', 'typedef', //
  'extension', 'mixin', 'widget', 'annotation', 'cli', 'config', 'other',
};

class SymbolsParseResult {
  SymbolsParseResult(this.symbols, this.errors);
  final List<SymbolEntry> symbols;
  final List<String> errors;
}

SymbolsParseResult parseSymbols(String text) {
  final errors = <String>[];
  Object? d;
  try {
    d = jsonDecode(text);
  } on FormatException catch (e) {
    return SymbolsParseResult(const [], ['symbols.json 不是合法 JSON：${e.message}']);
  }
  if (d is! Map || d['schema'] != 'fldoc.symbols/1') {
    errors.add('symbols.json schema 应为 fldoc.symbols/1');
  }
  final list = d is Map ? d['symbols'] : null;
  if (list is! List) {
    errors.add('symbols.json 缺少 symbols 数组');
    return SymbolsParseResult(const [], errors);
  }
  final out = <SymbolEntry>[];
  for (var i = 0; i < list.length; i++) {
    final s = SymbolEntry.fromJson(list[i]);
    if (s == null) {
      errors.add('symbols[$i] 缺少 name/kind/page');
    } else {
      if (!symbolKinds.contains(s.kind)) errors.add('symbols[$i] kind 无效：${s.kind}');
      out.add(s);
    }
  }
  return SymbolsParseResult(out, errors);
}
