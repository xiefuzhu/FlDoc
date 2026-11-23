import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../library/manifest_parser.dart';

class ImportParams {
  const ImportParams({
    required this.sourceUrl,
    required this.scope,
    required this.libId,
    required this.libName,
    required this.versionId,
    required this.versionLabel,
    required this.targetRoot,
    this.maxPages = 300,
    this.translate = true,
    this.now,
  });

  final String sourceUrl;
  final String scope;
  final String libId;
  final String libName;
  final String versionId;
  final String versionLabel;
  final String targetRoot;
  final int maxPages;
  final bool translate;
  final DateTime? now;

  String get libDir => p.join(targetRoot, libId).replaceAll('\\', '/');

  bool get existsOnDisk {
    final libPath = p.join(targetRoot, libId);
    final verPath = p.join(libPath, versionId);
    return Directory(verPath).existsSync() || File(p.join(libPath, 'manifest.json')).existsSync();
  }

  String get mode => existsOnDisk ? '增量更新' : '首次抓取';
}

/// Builds the agent import prompt from `assets/prompts/import_prompt.md` (doc 04).
class PromptBuilder {
  static const assetPath = 'assets/prompts/import_prompt.md';

  static Future<String> loadTemplate() => rootBundle.loadString(assetPath);

  /// Derives default scope (directory URL prefix) from [sourceUrl].
  static String deriveScope(String sourceUrl) {
    final uri = Uri.tryParse(sourceUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return sourceUrl.trim();
    final segs = List<String>.of(uri.pathSegments.where((s) => s.isNotEmpty));
    if (segs.isEmpty) return '${uri.scheme}://${uri.authority}/';
    // Keep up to the parent directory (or the first segment like /docs/).
    if (segs.length >= 2) {
      segs.removeLast();
    }
    return '${uri.scheme}://${uri.authority}/${segs.join('/')}/';
  }

  /// Derives a valid `libId` (`^[a-z0-9][a-z0-9-]{0,63}$`) from [sourceUrl].
  static String deriveLibId(String sourceUrl) {
    final uri = Uri.tryParse(sourceUrl.trim());
    if (uri == null || uri.host.isEmpty) return '';
    var host = uri.host.toLowerCase();
    for (final prefix in const ['www.', 'docs.', 'doc.', 'api.', 'developer.']) {
      if (host.startsWith(prefix)) host = host.substring(prefix.length);
    }
    final parts = host.split('.');
    var base = parts.isNotEmpty ? parts.first : host;
    if (base == 'github' && uri.pathSegments.length >= 2) {
      base = uri.pathSegments[1];
    }
    base = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (base.length > 64) base = base.substring(0, 64);
    return base;
  }

  /// Validates [ImportParams] and returns an error message, or null if valid.
  static String? validate(ImportParams params) {
    final uri = Uri.tryParse(params.sourceUrl.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      return '请输入有效的 http/https 来源 URL';
    }
    if (!libIdPattern.hasMatch(params.libId.trim())) {
      return '库 ID 需匹配 ^[a-z0-9][a-z0-9-]{0,63}\$';
    }
    if (params.libName.trim().isEmpty) return '请输入库名';
    if (!versionIdPattern.hasMatch(params.versionId.trim())) {
      return '版本 ID 格式无效';
    }
    if (params.targetRoot.trim().isEmpty) return '请选择目标库根目录';
    if (params.maxPages <= 0) return '最大页数需大于 0';
    return null;
  }

  static String render(String template, ImportParams params) {
    final ts = _isoWithOffset(params.now ?? DateTime.now());
    final map = <String, String>{
      'SOURCE_URL': params.sourceUrl.trim(),
      'SCOPE': params.scope.trim().isEmpty ? deriveScope(params.sourceUrl) : params.scope.trim(),
      'LIB_ID': params.libId.trim(),
      'LIB_NAME': params.libName.trim(),
      'VERSION_ID': params.versionId.trim().isEmpty ? 'latest' : params.versionId.trim(),
      'VERSION_LABEL': params.versionLabel.trim().isEmpty ? params.versionId.trim() : params.versionLabel.trim(),
      'TARGET_ROOT': params.targetRoot.trim().replaceAll('\\', '/'),
      'LIB_DIR': params.libDir,
      'MAX_PAGES': params.maxPages.toString(),
      'TRANSLATE': params.translate ? '是' : '否',
      'MODE': params.mode,
      'NOW': ts,
    };
    var out = template;
    for (final e in map.entries) {
      out = out.replaceAll('{{${e.key}}}', e.value);
    }
    return out;
  }

  /// Returns any unreplaced `{{PLACEHOLDER}}` tokens found in [rendered].
  static List<String> findUnreplacedPlaceholders(String rendered) =>
      RegExp(r'\{\{[A-Z0-9_]+\}\}').allMatches(rendered).map((m) => m.group(0)!).toList();

  static String _isoWithOffset(DateTime dt) {
    final offset = dt.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hh = abs.inHours.toString().padLeft(2, '0');
    final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final sec = dt.second.toString().padLeft(2, '0');
    return '$y-$m-${d}T$h:$min:$sec$sign$hh:$mm';
  }
}
