/// Anchor slug rules.
///
/// Contract libraries use explicit `{#id}` anchors. Plain Markdown libraries
/// fall back to GitHub rules: lowercase, drop everything except letters,
/// digits (including CJK), spaces, `-` and `_`, then spaces become `-`.
/// Duplicates get `-1`, `-2`, ... appended.
library;

final RegExp _explicitAnchor = RegExp(r'\s*\{#([A-Za-z0-9][A-Za-z0-9_-]*)\}\s*$');
final RegExp contractAnchorId = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// Splits `Title {#id}` into (title, id). id is null if absent.
(String, String?) splitExplicitAnchor(String heading) {
  final m = _explicitAnchor.firstMatch(heading);
  if (m == null) return (heading.trim(), null);
  return (heading.substring(0, m.start).trim(), m.group(1));
}

/// GitHub-style slug without de-duplication.
String githubSlug(String text) {
  final lower = text.trim().toLowerCase();
  final buf = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    if (_isWordRune(rune) || ch == '-' || ch == '_') {
      buf.write(ch);
    } else if (ch == ' ') {
      buf.write('-');
    }
  }
  return buf.toString();
}

bool _isWordRune(int r) {
  if (r >= 0x30 && r <= 0x39) return true; // 0-9
  if (r >= 0x61 && r <= 0x7a) return true; // a-z
  if (r >= 0x41 && r <= 0x5a) return true; // A-Z
  if (r < 0x80) return false;
  // Treat non-ASCII letters (CJK, accented letters, etc.) as word characters,
  // excluding general punctuation and CJK punctuation / full-width symbols.
  if (r >= 0x2000 && r <= 0x206F) return false; // general punctuation
  if (r >= 0x3000 && r <= 0x303F) return false; // CJK symbols & punctuation
  if (r >= 0xFF00 && r <= 0xFF0F) return false;
  if (r >= 0xFF1A && r <= 0xFF20) return false;
  if (r >= 0xFF3B && r <= 0xFF40) return false;
  if (r >= 0xFF5B && r <= 0xFF65) return false;
  if (r >= 0x00A0 && r <= 0x00BF) return false; // latin-1 punctuation
  if (r == 0x00D7 || r == 0x00F7) return false;
  if (r >= 0x2190 && r <= 0x2BFF) return false; // arrows, symbols
  if (r >= 0x1F000) return false; // emoji & pictographs
  return true;
}

/// Assigns unique slugs in document order (GitHub: first `x`, then `x-1`).
class SlugTracker {
  final Map<String, int> _counts = {};
  final Set<String> _used = {};

  /// Registers an explicit id (kept as-is even if duplicated).
  String useExplicit(String id) {
    _used.add(id);
    _counts.putIfAbsent(id, () => 0);
    return id;
  }

  String unique(String base) {
    var slug = base;
    if (_used.contains(slug)) {
      var n = _counts[base] ?? 0;
      do {
        n++;
        slug = '$base-$n';
      } while (_used.contains(slug));
      _counts[base] = n;
    } else {
      _counts.putIfAbsent(base, () => 0);
    }
    _used.add(slug);
    return slug;
  }
}
