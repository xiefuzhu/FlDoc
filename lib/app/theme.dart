import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';

import '../features/settings/settings_model.dart';

Color parseHexColor(String hex, {Color fallback = const Color(0xFF0078D4)}) {
  var h = hex.trim().replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null || h.length != 8 ? fallback : Color(v);
}

String colorToHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

const accentPresets = <String, String>{
  '#0078D4': '蓝色（默认）',
  '#0063B1': '深蓝',
  '#8764B8': '紫色',
  '#E3008C': '洋红',
  '#E81123': '红色',
  '#CA5010': '橙色',
  '#498205': '绿色',
  '#038387': '青色',
  '#5D5A58': '灰色',
};

ThemeMode themeModeOf(String v) => switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

String? _bodyFont(String name) {
  if (name.isEmpty) return null;
  if (name == 'Microsoft YaHei UI') {
    if (Platform.isMacOS) return 'Helvetica Neue';
    if (Platform.isAndroid) return 'Roboto';
  }
  return name;
}

String _codeFont(String name) {
  if (name.isNotEmpty && name != 'Cascadia Code') return name;
  if (Platform.isMacOS) return 'Menlo';
  if (Platform.isAndroid) return 'monospace';
  return name.isEmpty ? 'Consolas' : name;
}

FluentThemeData buildTheme(AppSettings s, Brightness brightness, {Color? defaultAccent}) {
  final accent = (defaultAccent != null && s.accentColor.toUpperCase() == '#0078D4'
          ? defaultAccent
          : parseHexColor(s.accentColor))
      .toAccentColor();
  final dark = brightness == Brightness.dark;
  final bg = dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3);
  return FluentThemeData(
    brightness: brightness,
    accentColor: accent,
    fontFamily: _bodyFont(s.bodyFont),
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: bg,
    micaBackgroundColor: bg,
    focusTheme: FocusThemeData(glowFactor: 0),
  );
}

/// Styles used by the Markdown renderer.
class ReaderStyle {
  ReaderStyle({
    required this.theme,
    required this.fontSize,
    required this.bodyFont,
    required this.codeFont,
    required this.maxWidth,
  });

  final FluentThemeData theme;
  final double fontSize;
  final String bodyFont;
  final String codeFont;

  /// null = unlimited.
  final double? maxWidth;

  bool get dark => theme.brightness == Brightness.dark;
  Color get text => dark ? const Color(0xFFE6E6E6) : const Color(0xFF1B1B1B);
  Color get muted => dark ? const Color(0xFFA0A0A0) : const Color(0xFF616161);
  Color get accent => theme.accentColor.defaultBrushFor(theme.brightness);
  Color get link => dark ? theme.accentColor.lighter : theme.accentColor.darker;
  Color get codeBg => dark ? const Color(0xFF1E1E1E) : const Color(0xFFF6F8FA);
  Color get inlineCodeBg => dark ? const Color(0x33FFFFFF) : const Color(0x14000000);
  Color get border => dark ? const Color(0x33FFFFFF) : const Color(0x1F000000);
  Color get surface => dark ? const Color(0xFF2B2B2B) : const Color(0xFFFFFFFF);
  Color get findHit => dark ? const Color(0x66C8A600) : const Color(0x88FFE14D);
  Color get findCurrent => dark ? const Color(0xCCE07000) : const Color(0xFFFF9632);

  TextStyle get body => TextStyle(
        fontSize: fontSize,
        height: 1.7,
        color: text,
        fontFamily: _bodyFont(bodyFont),
        fontFamilyFallback: Platform.isMacOS
            ? const ['PingFang SC']
            : const ['Microsoft YaHei UI', 'Segoe UI', 'Microsoft YaHei'],
      );

  TextStyle get code => TextStyle(
        fontSize: fontSize * 0.88,
        height: 1.55,
        color: text,
        fontFamily: _codeFont(codeFont),
        fontFamilyFallback: const ['Cascadia Mono', 'Consolas', 'Microsoft YaHei UI'],
      );

  TextStyle heading(int level) {
    final scale = switch (level) { 1 => 1.9, 2 => 1.5, 3 => 1.25, 4 => 1.1, _ => 1.0 };
    return body.copyWith(fontSize: fontSize * scale, fontWeight: level <= 2 ? FontWeight.w600 : FontWeight.w600, height: 1.35);
  }
}
