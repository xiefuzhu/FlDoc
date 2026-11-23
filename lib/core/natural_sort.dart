/// Natural ordering: `page2` < `page10`, case-insensitive.
int naturalCompare(String a, String b) {
  final ra = _tokenize(a.toLowerCase());
  final rb = _tokenize(b.toLowerCase());
  final n = ra.length < rb.length ? ra.length : rb.length;
  for (var i = 0; i < n; i++) {
    final x = ra[i];
    final y = rb[i];
    final xn = int.tryParse(x);
    final yn = int.tryParse(y);
    int c;
    if (xn != null && yn != null) {
      c = xn.compareTo(yn);
      if (c == 0) c = x.length.compareTo(y.length);
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  final c = ra.length.compareTo(rb.length);
  return c != 0 ? c : a.compareTo(b);
}

final RegExp _chunk = RegExp(r'\d+|\D+');

List<String> _tokenize(String s) => _chunk.allMatches(s).map((m) => m.group(0)!).toList();
