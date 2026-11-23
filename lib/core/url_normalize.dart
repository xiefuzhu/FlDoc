/// URL normalisation shared by de-duplication and local mapping
/// (contract section 7).
///
/// 1. scheme -> https, host lowercase, strip `www.`
/// 2. drop fragment; drop query (callers may also try the query-preserving form)
/// 3. strip trailing `/`, `index.html`, `.html`
/// 4. normalise percent-encoding
String? normalizeUrl(String input, {bool keepQuery = false}) {
  final trimmed = input.trim();
  Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } catch (_) {
    return null;
  }
  if (!(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
  var host = uri.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  final port = uri.hasPort && uri.port != 80 && uri.port != 443 ? ':${uri.port}' : '';

  final segments = <String>[];
  for (final seg in uri.pathSegments) {
    // pathSegments are decoded; re-encode canonically.
    segments.add(Uri.encodeComponent(seg).replaceAll('%7E', '~'));
  }
  while (segments.isNotEmpty && segments.last.isEmpty) {
    segments.removeLast();
  }
  if (segments.isNotEmpty) {
    final last = segments.last.toLowerCase();
    if (last == 'index.html' || last == 'index.htm') {
      segments.removeLast();
    } else if (last.endsWith('.html')) {
      segments[segments.length - 1] = segments.last.substring(0, segments.last.length - 5);
    } else if (last.endsWith('.htm')) {
      segments[segments.length - 1] = segments.last.substring(0, segments.last.length - 4);
    }
  }
  while (segments.isNotEmpty && segments.last.isEmpty) {
    segments.removeLast();
  }
  final path = segments.isEmpty ? '' : '/${segments.join('/')}';
  final query = keepQuery && uri.hasQuery && uri.query.isNotEmpty ? '?${uri.query}' : '';
  return 'https://$host$port$path$query';
}

/// All lookup keys for [url]: without query, and with query when present.
List<String> normalizedUrlVariants(String url) {
  final out = <String>[];
  final a = normalizeUrl(url);
  if (a != null) out.add(a);
  final b = normalizeUrl(url, keepQuery: true);
  if (b != null && b != a) out.add(b);
  return out;
}
