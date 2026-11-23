import 'package:path/path.dart' as p;

import '../../../core/url_normalize.dart';
import '../../library/models.dart';

sealed class LinkTarget {}

class InternalLink extends LinkTarget {
  InternalLink(this.location);
  final DocLocation location;
}

class AnchorLink extends LinkTarget {
  AnchorLink(this.anchor);
  final String anchor;
}

class ExternalLink extends LinkTarget {
  ExternalLink(this.uri);
  final Uri uri;
}

class InvalidLink extends LinkTarget {
  InvalidLink(this.reason);
  final String reason;
}

/// Maps normalised `source_url`s to local pages across all libraries.
class UrlIndex {
  final Map<String, DocLocation> _map = {};

  void clear() => _map.clear();

  void addLibrary(Library lib) {
    // Default version first so it wins on duplicates.
    final versions = [lib.defaultVersion, ...lib.versions.where((v) => v.id != lib.defaultVersionId)];
    for (final v in versions) {
      for (final meta in v.pages.values) {
        final url = meta.sourceUrl;
        if (url == null) continue;
        for (final key in normalizedUrlVariants(url)) {
          _map.putIfAbsent(key, () => DocLocation(libKey: lib.key, versionId: v.id, page: meta.path));
        }
      }
    }
  }

  DocLocation? lookup(String url) {
    for (final key in normalizedUrlVariants(url)) {
      final hit = _map[key];
      if (hit != null) return hit;
    }
    return null;
  }

  int get length => _map.length;
}

const allowedExternalSchemes = {'http', 'https', 'mailto'};

/// Resolves a Markdown link relative to the current page (FR-LK-01..03).
LinkTarget resolveLink(String href, DocLocation current, LibraryVersion version, UrlIndex urls) {
  final h = href.trim();
  if (h.isEmpty) return InvalidLink('空链接');
  if (h.startsWith('#')) return AnchorLink(Uri.decodeComponent(h.substring(1)));

  final schemeMatch = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):').firstMatch(h);
  if (schemeMatch != null) {
    final scheme = schemeMatch.group(1)!.toLowerCase();
    if (scheme.length == 1) {
      // Windows drive letter: treat as invalid (no absolute file access).
      return InvalidLink('不支持本地绝对路径');
    }
    Uri uri;
    try {
      uri = Uri.parse(h);
    } catch (_) {
      return InvalidLink('无效链接');
    }
    if (scheme == 'http' || scheme == 'https') {
      final local = urls.lookup(h);
      if (local != null) {
        return InternalLink(DocLocation(
          libKey: local.libKey,
          versionId: local.versionId,
          page: local.page,
          anchor: uri.fragment.isEmpty ? null : uri.fragment,
        ));
      }
    }
    if (!allowedExternalSchemes.contains(scheme)) return InvalidLink('不允许的协议：$scheme');
    return ExternalLink(uri);
  }

  // Relative link.
  var pathPart = h;
  String? anchor;
  final hashIdx = h.indexOf('#');
  if (hashIdx >= 0) {
    pathPart = h.substring(0, hashIdx);
    anchor = Uri.decodeComponent(h.substring(hashIdx + 1));
    if (anchor.isEmpty) anchor = null;
  }
  final qIdx = pathPart.indexOf('?');
  if (qIdx >= 0) pathPart = pathPart.substring(0, qIdx);
  if (pathPart.isEmpty) return anchor != null ? AnchorLink(anchor) : InvalidLink('空链接');
  final decoded = Uri.decodeComponent(pathPart);
  final target = resolveRelativePage(current.page, decoded, version.absDir);
  if (target == null) return InvalidLink('链接越出文档库目录');
  return InternalLink(DocLocation(libKey: current.libKey, versionId: current.versionId, page: target, anchor: anchor));
}

/// Resolves [rel] against the directory of [fromPage] (both version-relative).
/// Returns a version-relative path with `/`, mapped from `.en.md` to the
/// Chinese page, or null if it escapes [versionAbsDir].
String? resolveRelativePage(String fromPage, String rel, String versionAbsDir) {
  final ctx = p.Context(style: p.Style.posix);
  final base = ctx.dirname(fromPage);
  var joined = ctx.normalize(ctx.join(base, rel.replaceAll('\\', '/')));
  if (joined.startsWith('..') || joined.startsWith('/')) return null;
  final abs = p.normalize(p.join(versionAbsDir, joined));
  if (!p.isWithin(versionAbsDir, abs)) return null;
  if (joined.toLowerCase().endsWith('.en.md')) {
    joined = '${joined.substring(0, joined.length - 6)}.md';
  } else if (!joined.toLowerCase().endsWith('.md')) {
    // Directory-style links: try index.md.
    if (ctx.extension(joined).isEmpty) joined = ctx.join(joined, 'index.md');
  }
  return joined;
}
