import 'package:lpinyin/lpinyin.dart';

final Map<String, String> _pinyinInitialsCache = {};
final Map<String, String> _pinyinFullCache = {};

/// Safely converts Chinese text to lowercase pinyin initials (e.g. `全局搜索` -> `qjss`).
String pinyinInitials(String text) {
  return _pinyinInitialsCache.putIfAbsent(text, () {
    final buf = StringBuffer();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (rune >= 0x4E00 && rune <= 0x9FFF) {
        try {
          final py = PinyinHelper.getPinyinE(ch, separator: '', defPinyin: '');
          if (py.isNotEmpty) buf.write(py[0].toLowerCase());
        } catch (_) {}
      } else {
        buf.write(ch.toLowerCase());
      }
    }
    return buf.toString();
  });
}

/// Safely converts Chinese text to full lowercase pinyin without tones.
String pinyinFull(String text) {
  return _pinyinFullCache.putIfAbsent(text, () {
    try {
      return PinyinHelper.getPinyinE(text, separator: '', defPinyin: '').toLowerCase();
    } catch (_) {
      return text.toLowerCase();
    }
  });
}

/// Computes a fuzzy relevance score (> 0 means matched) against [text] and optional [extra] keywords.
/// Supports direct substring, prefix, subsequence, pinyin initials (`qjss` -> `全局搜索`), and full pinyin.
int fuzzyScore(String query, String text, {List<String> extra = const []}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 1;
  final parts = q.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return 1;

  final candidates = [text, ...extra];
  var total = 0;
  for (final part in parts) {
    var bestPart = 0;
    for (var i = 0; i < candidates.length; i++) {
      final s = _scoreSingle(part, candidates[i]);
      final weighted = i == 0 ? s : (s * 0.8).round();
      if (weighted > bestPart) bestPart = weighted;
    }
    if (bestPart <= 0) return 0; // Every space-separated token must match.
    total += bestPart;
  }
  return total;
}

int _scoreSingle(String q, String rawTarget) {
  if (rawTarget.isEmpty) return 0;
  final target = rawTarget.toLowerCase();
  if (target == q) return 1000;
  if (target.startsWith(q)) return 850;
  final idx = target.indexOf(q);
  if (idx >= 0) return 700 - (idx.clamp(0, 100));

  // Pinyin initials (e.g. "qjss" -> "全局搜索")
  final initials = pinyinInitials(rawTarget);
  if (initials == q) return 680;
  if (initials.startsWith(q)) return 640;
  final pIdx = initials.indexOf(q);
  if (pIdx >= 0) return 600 - (pIdx.clamp(0, 80));

  // Full pinyin
  final full = pinyinFull(rawTarget);
  if (full.contains(q)) return 500;

  // Subsequence on target or initials
  if (_subseq(q, target)) return 350;
  if (_subseq(q, initials)) return 300;
  return 0;
}

bool _subseq(String needle, String haystack) {
  var j = 0;
  for (var i = 0; i < haystack.length && j < needle.length; i++) {
    if (haystack.codeUnitAt(i) == needle.codeUnitAt(j)) j++;
  }
  return j == needle.length;
}
