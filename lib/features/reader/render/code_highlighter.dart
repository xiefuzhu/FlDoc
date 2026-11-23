import 'dart:collection';

import 'package:flutter/painting.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/github.dart';

class CodePiece {
  CodePiece(this.text, this.style);
  final String text;
  final TextStyle style;
}

/// Syntax highlighting with an LRU cache. Output is a flat list of pieces so
/// find/search highlights can be layered on top.
class CodeHighlighter {
  CodeHighlighter._() {
    _hl.registerLanguages(builtinAllLanguages);
  }

  static final CodeHighlighter instance = CodeHighlighter._();

  final Highlight _hl = Highlight();
  final LinkedHashMap<String, List<CodePiece>> _cache = LinkedHashMap();

  static const _aliases = {
    'sh': 'bash',
    'shell': 'bash',
    'zsh': 'bash',
    'console': 'bash',
    'ps1': 'powershell',
    'ps': 'powershell',
    'yml': 'yaml',
    'js': 'javascript',
    'ts': 'typescript',
    'kt': 'kotlin',
    'py': 'python',
    'rs': 'rust',
    'md': 'markdown',
    'html': 'xml',
    'vue': 'xml',
    'jsonc': 'json',
    'json5': 'json',
    'c++': 'cpp',
    'cs': 'csharp',
    'golang': 'go',
    'dockerfile': 'dockerfile',
    'text': 'plaintext',
    'txt': 'plaintext',
  };

  List<CodePiece> highlight(String code, String? language, TextStyle base, {required bool dark}) {
    final key = '${dark ? 1 : 0}|${base.fontSize}|${base.fontFamily}|$language|$code';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    final pieces = _compute(code, language, base, dark);
    _cache[key] = pieces;
    if (_cache.length > 400) _cache.remove(_cache.keys.first);
    return pieces;
  }

  List<CodePiece> _compute(String code, String? language, TextStyle base, bool dark) {
    final theme = dark ? atomOneDarkTheme : githubTheme;
    final themed = {
      for (final e in theme.entries) e.key: e.value.copyWith(backgroundColor: const Color(0x00000000)),
    };
    final rootStyle = base.copyWith(color: dark ? const Color(0xFFD4D4D4) : const Color(0xFF24292E));
    var lang = language?.toLowerCase().trim();
    if (lang != null) lang = _aliases[lang] ?? lang;
    if (lang == null || lang.isEmpty || lang == 'plaintext' || _hl.getLanguage(lang) == null || code.length > 200000) {
      return [CodePiece(code, rootStyle)];
    }
    try {
      final result = _hl.highlight(code: code, language: lang);
      final renderer = TextSpanRenderer(rootStyle, themed);
      result.render(renderer);
      final span = renderer.span;
      if (span == null) return [CodePiece(code, rootStyle)];
      final out = <CodePiece>[];
      void walk(InlineSpan s, TextStyle inherited) {
        if (s is TextSpan) {
          final st = inherited.merge(s.style);
          if (s.text != null && s.text!.isNotEmpty) out.add(CodePiece(s.text!, st));
          for (final c in s.children ?? const <InlineSpan>[]) {
            walk(c, st);
          }
        }
      }

      walk(span, rootStyle);
      final joined = out.map((e) => e.text).join();
      if (joined != code) return [CodePiece(code, rootStyle)];
      return out;
    } catch (_) {
      return [CodePiece(code, rootStyle)];
    }
  }
}
