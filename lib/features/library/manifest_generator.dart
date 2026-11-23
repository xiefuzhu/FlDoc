import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'manifest_parser.dart';
import 'models.dart';

/// Generates a flat-version (`dir: "."`) contract `manifest.json` for a plain
/// Markdown library without modifying any `.md` files (FR-LIB-06).
class ManifestGenerator {
  static bool hasExistingManifest(String libDir) => File(p.join(libDir, 'manifest.json')).existsSync();

  static String deriveValidLibId(String folderName) {
    var s = folderName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-');
    s = s.replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-|-$'), '');
    if (s.isEmpty || !RegExp(r'^[a-z0-9]').hasMatch(s)) s = 'lib-$s';
    if (s.length > 64) s = s.substring(0, 64);
    return s;
  }

  static Map<String, dynamic> buildManifestMap(Library plainLib, {DateTime? now}) {
    final ts = _isoWithOffset(now ?? DateTime.now());
    final v = plainLib.defaultVersion;
    final id = libIdPattern.hasMatch(plainLib.id) ? plainLib.id : deriveValidLibId(plainLib.id);
    return {
      'schema': 'fldoc.library/1',
      'id': id,
      'name': plainLib.name,
      'description': '从本地 Markdown 文件夹生成',
      'sourceLanguage': 'zh-CN',
      'displayLanguage': 'zh-CN',
      'defaultVersion': v.id,
      'updatedAt': ts,
      'generator': 'fldoc:manifest-generator',
      'versions': [
        {
          'id': v.id,
          'label': v.label,
          'dir': '.',
          'sourceUrl': '',
          'scope': '',
          'crawledAt': ts,
          'pageCount': v.orderedPages.length,
          'translated': false,
          'toc': _tocToJson(v.toc),
        },
      ],
    };
  }

  /// Writes `manifest.json` inside [plainLib.dir]. Does not alter any `.md` files.
  static File generate(Library plainLib, {DateTime? now}) {
    final map = buildManifestMap(plainLib, now: now);
    final pretty = '${const JsonEncoder.withIndent('  ').convert(map)}\n';
    final outFile = File(p.join(plainLib.dir, 'manifest.json'));
    outFile.writeAsStringSync(pretty, flush: true);
    return outFile;
  }

  static List<Map<String, dynamic>> _tocToJson(List<TocNode> nodes) => [
        for (final n in nodes)
          {
            'title': n.title,
            if (n.page != null) 'page': n.page,
            if (n.icon != null) 'icon': n.icon,
            if (n.children.isNotEmpty) 'children': _tocToJson(n.children),
          },
      ];

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
