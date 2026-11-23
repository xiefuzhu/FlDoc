import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../markdown/md_model.dart';
import '../render/block_renderer.dart';

class FindMatch {
  const FindMatch(this.block, this.start, this.end);
  final int block;
  final int start;
  final int end;
}

class FindState {
  const FindState({
    this.open = false,
    this.query = '',
    this.caseSensitive = false,
    this.wholeWord = false,
    this.regex = false,
    this.matches = const [],
    this.current = -1,
    this.token = 0,
  });

  final bool open;
  final String query;
  final bool caseSensitive;
  final bool wholeWord;
  final bool regex;
  final List<FindMatch> matches;
  final int current;

  /// Changes whenever the current match should be scrolled into view.
  final int token;

  FindMatch? get currentMatch => current >= 0 && current < matches.length ? matches[current] : null;

  bool get active => query.isNotEmpty && matches.isNotEmpty;

  FindState copyWith({
    bool? open,
    String? query,
    bool? caseSensitive,
    bool? wholeWord,
    bool? regex,
    List<FindMatch>? matches,
    int? current,
    int? token,
  }) =>
      FindState(
        open: open ?? this.open,
        query: query ?? this.query,
        caseSensitive: caseSensitive ?? this.caseSensitive,
        wholeWord: wholeWord ?? this.wholeWord,
        regex: regex ?? this.regex,
        matches: matches ?? this.matches,
        current: current ?? this.current,
        token: token ?? this.token,
      );

  /// Highlights for one block.
  List<TextHighlight> highlightsFor(int block) {
    if (matches.isEmpty) return const [];
    final out = <TextHighlight>[];
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m.block == block) out.add(TextHighlight(m.start, m.end, current: i == current));
    }
    return out;
  }
}

/// Finds all matches in parsed block text (independent of built widgets, so
/// lazily built blocks can still be highlighted and scrolled to).
List<FindMatch> findInDocument(
  MdDocument doc,
  String query, {
  bool caseSensitive = false,
  bool wholeWord = false,
  bool regex = false,
}) {
  if (query.isEmpty) return const [];
  RegExp re;
  try {
    var pattern = regex ? query : RegExp.escape(query);
    if (wholeWord) pattern = r'(?<![\p{L}\p{N}_])(?:' + pattern + r')(?![\p{L}\p{N}_])';
    re = RegExp(pattern, caseSensitive: caseSensitive, unicode: true);
  } catch (_) {
    return const [];
  }
  final out = <FindMatch>[];
  for (final b in doc.blocks) {
    for (final m in re.allMatches(b.plainText)) {
      if (m.end > m.start) out.add(FindMatch(b.index, m.start, m.end));
      if (out.length >= 5000) return out;
    }
  }
  return out;
}

final findProvider = NotifierProvider<FindController, FindState>(FindController.new);

class FindController extends Notifier<FindState> {
  MdDocument? _doc;

  @override
  FindState build() => const FindState();

  void attach(MdDocument? doc) {
    if (identical(doc, _doc)) return;
    _doc = doc;
    if (state.query.isNotEmpty) _recompute(keepNearBlock: state.currentMatch?.block);
  }

  void open({String? initial}) {
    state = state.copyWith(open: true, query: initial ?? state.query);
    if (initial != null) _recompute();
  }

  void close() => state = FindState(caseSensitive: state.caseSensitive, wholeWord: state.wholeWord, token: state.token + 1);

  void setQuery(String q) {
    state = state.copyWith(query: q);
    _recompute();
  }

  void toggleCase() {
    state = state.copyWith(caseSensitive: !state.caseSensitive);
    _recompute();
  }

  void toggleWholeWord() {
    state = state.copyWith(wholeWord: !state.wholeWord);
    _recompute();
  }

  /// Highlights [query] after a search jump, focusing the first match at or
  /// after [nearBlock]. The find bar stays closed.
  void highlightTransient(String query, {int? nearBlock, bool regex = false, bool caseSensitive = false}) {
    state = FindState(query: query, regex: regex, caseSensitive: caseSensitive, token: state.token);
    _recompute(keepNearBlock: nearBlock);
  }

  void next() => _step(1);
  void previous() => _step(-1);

  void _step(int d) {
    if (state.matches.isEmpty) return;
    final n = state.matches.length;
    state = state.copyWith(current: (state.current + d + n) % n, token: state.token + 1);
  }

  void _recompute({int? keepNearBlock}) {
    final doc = _doc;
    if (doc == null || state.query.isEmpty) {
      state = state.copyWith(matches: const [], current: -1);
      return;
    }
    final matches = findInDocument(doc, state.query,
        caseSensitive: state.caseSensitive, wholeWord: state.wholeWord, regex: state.regex);
    var current = matches.isEmpty ? -1 : 0;
    if (keepNearBlock != null && matches.isNotEmpty) {
      final idx = matches.indexWhere((m) => m.block >= keepNearBlock);
      current = idx < 0 ? 0 : idx;
    }
    state = state.copyWith(matches: matches, current: current, token: state.token + 1);
  }
}
