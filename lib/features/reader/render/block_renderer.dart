import 'dart:collection';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

import '../../../app/theme.dart';
import '../markdown/md_model.dart';
import 'code_highlighter.dart';

/// A highlighted range inside a block's plain text.
class TextHighlight {
  const TextHighlight(this.start, this.end, {this.current = false});
  final int start;
  final int end;
  final bool current;
}

/// Everything the renderer needs from the outside world.
class RenderContext {
  RenderContext({
    required this.style,
    required this.onLink,
    required this.onHover,
    required this.pageFile,
    required this.libDir,
    this.mermaidBuilder,
    this.citationBuilder,
  });

  final ReaderStyle style;
  final void Function(String href) onLink;
  final void Function(String? href) onHover;

  /// Absolute path of the page file (for relative images).
  final String pageFile;

  /// Images must resolve inside this directory.
  final String libDir;
  final Widget Function(String source)? mermaidBuilder;

  /// Optional: turns `[n]` citations into widgets (AI panel).
  final InlineSpan? Function(String text, TextStyle style)? citationBuilder;
}

/// Renders one [MdBlock]. Stateful so tap recognizers are disposed.
class BlockView extends StatefulWidget {
  const BlockView({super.key, required this.block, required this.ctx, this.highlights = const []});

  final MdBlock block;
  final RenderContext ctx;
  final List<TextHighlight> highlights;

  @override
  State<BlockView> createState() => _BlockViewState();
}

class _BlockViewState extends State<BlockView> {
  final List<GestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final r = _Renderer(widget.ctx, widget.highlights, _recognizers);
    final nodes = widget.block.nodes;
    final children = [for (final n in nodes) r.node(n, 0)];
    final top = widget.block.kind == BlockKind.heading ? widget.ctx.style.fontSize * 0.9 : 0.0;
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: widget.ctx.style.fontSize * 0.75),
      child: children.length == 1
          ? children.first
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

class _Renderer {
  _Renderer(this.ctx, this.highlights, this.recognizers);

  final RenderContext ctx;
  final List<TextHighlight> highlights;
  final List<GestureRecognizer> recognizers;

  static final LinkedHashMap<String, bool> _fileExistsCache = LinkedHashMap();

  static bool _fileExistsCached(String path) {
    final hit = _fileExistsCache.remove(path);
    if (hit != null) {
      _fileExistsCache[path] = hit;
      return hit;
    }
    final exists = File(path).existsSync();
    _fileExistsCache[path] = exists;
    if (_fileExistsCache.length > 500) {
      _fileExistsCache.remove(_fileExistsCache.keys.first);
    }
    return exists;
  }

  ReaderStyle get s => ctx.style;

  Widget node(MdNode n, int depth) {
    switch (n) {
      case ParaNode(:final run):
        if (run.isSoleImage) {
          final seg = run.segs.firstWhere((e) => e.imageSrc != null);
          return _image(seg.imageSrc!, seg.text, block: true);
        }
        return Text.rich(TextSpan(children: spans(run, s.body)));
      case HeadingNode(:final level, :final run):
        return Text.rich(TextSpan(children: spans(run, s.heading(level))));
      case CodeNode(:final language, :final run):
        return CodeBlockView(language: language, run: run, style: s, highlights: _forRun(run));
      case MermaidNode(:final run):
        final b = ctx.mermaidBuilder;
        if (b != null) return b(run.text);
        return CodeBlockView(language: 'mermaid', run: run, style: s, highlights: _forRun(run));
      case MathBlockNode(:final run):
        return _mathBlock(run.text);
      case ListNode():
        return _list(n, depth);
      case QuoteNode(:final children):
        return Container(
          padding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: s.border, width: 4))),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: s.muted),
            child: _column(children, depth),
          ),
        );
      case AlertNode(:final type, :final children):
        return _alert(type, children, depth);
      case TableNode():
        return _table(n);
      case HrNode():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(height: 1, color: s.border),
        );
      case DetailsNode(:final summary, :final children):
        return Expander(
          header: Text.rich(TextSpan(children: spans(summary, s.body))),
          content: _column(children, depth),
          initiallyExpanded: highlights.isNotEmpty,
        );
    }
  }

  Widget _column(List<MdNode> children, int depth) {
    final ws = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      ws.add(node(children[i], depth));
      if (i < children.length - 1) ws.add(SizedBox(height: s.fontSize * 0.5));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: ws);
  }

  Widget _list(ListNode l, int depth) {
    final items = <Widget>[];
    for (var i = 0; i < l.items.length; i++) {
      final item = l.items[i];
      Widget marker;
      if (item.checked != null) {
        marker = Padding(
          padding: EdgeInsets.only(top: s.fontSize * 0.3),
          child: Icon(
            item.checked! ? FluentIcons.checkbox_composite : FluentIcons.checkbox,
            size: s.fontSize,
            color: item.checked! ? s.accent : s.muted,
          ),
        );
      } else if (l.ordered) {
        marker = Text('${l.start + i}.', style: s.body.copyWith(color: s.muted));
      } else {
        marker = Text(depth.isEven ? '•' : '◦', style: s.body.copyWith(color: s.muted));
      }
      items.add(Padding(
        padding: EdgeInsets.only(bottom: s.fontSize * 0.25),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: s.fontSize * 1.6, child: Align(alignment: Alignment.topRight, child: Padding(padding: const EdgeInsets.only(right: 6), child: marker))),
            Expanded(child: _column(item.children, depth + 1)),
          ],
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items);
  }

  Widget _alert(AlertType type, List<MdNode> children, int depth) {
    final (label, icon, color) = switch (type) {
      AlertType.note => ('注意', FluentIcons.info, const Color(0xFF0969DA)),
      AlertType.tip => ('提示', FluentIcons.lightbulb, const Color(0xFF1A7F37)),
      AlertType.important => ('重要', FluentIcons.important, const Color(0xFF8250DF)),
      AlertType.warning => ('警告', FluentIcons.warning, const Color(0xFF9A6700)),
      AlertType.caution => ('当心', FluentIcons.error_badge, const Color(0xFFCF222E)),
    };
    final c = s.dark ? Color.lerp(color, Colors.white, 0.35)! : color;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
      decoration: BoxDecoration(
        color: c.withValues(alpha: s.dark ? 0.12 : 0.07),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: c, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(icon, size: s.fontSize, color: c),
            const SizedBox(width: 8),
            Text(label, style: s.body.copyWith(color: c, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 4),
          _column(children, depth),
        ],
      ),
    );
  }

  Widget _table(TableNode t) {
    final cols = t.header.length;
    TextAlign align(int c) => switch (c < t.aligns.length ? t.aligns[c] : CellAlign.left) {
          CellAlign.center => TextAlign.center,
          CellAlign.right => TextAlign.right,
          CellAlign.left => TextAlign.left,
        };
    Widget cell(InlineRun r, int c, {bool head = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text.rich(
            TextSpan(children: spans(r, head ? s.body.copyWith(fontWeight: FontWeight.w600) : s.body)),
            textAlign: align(c),
          ),
        );
    final rows = <TableRow>[
      TableRow(
        decoration: BoxDecoration(color: s.inlineCodeBg),
        children: [for (var c = 0; c < cols; c++) cell(t.header[c], c, head: true)],
      ),
      for (var r = 0; r < t.rows.length; r++)
        TableRow(
          decoration: BoxDecoration(color: r.isOdd ? s.inlineCodeBg.withValues(alpha: 0.04) : null),
          children: [
            for (var c = 0; c < cols; c++)
              c < t.rows[r].length ? cell(t.rows[r][c], c) : const SizedBox.shrink(),
          ],
        ),
    ];
    return LayoutBuilder(builder: (context, box) {
      final minW = cols * 120.0;
      final table = Table(
        border: TableBorder.all(color: s.border, width: 1),
        defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: rows,
      );
      if (box.maxWidth >= minW) return table;
      return SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: minW, child: table));
    });
  }

  Widget _mathBlock(String tex) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Math.tex(
            tex,
            mathStyle: MathStyle.display,
            textStyle: s.body.copyWith(fontSize: s.fontSize * 1.1),
            onErrorFallback: (e) => _mathError(tex, e.message),
          ),
        ),
      ),
    );
  }

  Widget _mathError(String tex, String message) => Tooltip(
        message: '公式解析失败：$message',
        child: Text(tex, style: s.code.copyWith(color: Colors.red)),
      );

  Widget _image(String src, String alt, {bool block = false}) {
    Widget placeholder() => Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(border: Border.all(color: s.border), borderRadius: BorderRadius.circular(4)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(FluentIcons.photo_error, size: 16, color: s.muted),
            const SizedBox(width: 6),
            Flexible(child: Text(alt.isEmpty ? '图片加载失败' : alt, style: s.body.copyWith(color: s.muted))),
          ]),
        );
    Widget img;
    final lower = src.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      img = lower.endsWith('.svg')
          ? SvgPicture.network(src, placeholderBuilder: (_) => placeholder())
          : Image.network(src, errorBuilder: (_, _, _) => placeholder());
    } else {
      final abs = p.normalize(p.join(p.dirname(ctx.pageFile), Uri.decodeComponent(src.split('#').first.split('?').first)));
      if (!p.isWithin(ctx.libDir, abs) || !_fileExistsCached(abs)) {
        img = placeholder();
      } else if (lower.endsWith('.svg')) {
        img = SvgPicture.file(File(abs), placeholderBuilder: (_) => placeholder());
      } else {
        img = Image.file(File(abs), errorBuilder: (_, _, _) => placeholder());
      }
    }
    final wrapped = Semantics(label: alt, child: Tooltip(message: alt, child: img));
    if (!block) return ConstrainedBox(constraints: BoxConstraints(maxHeight: s.fontSize * 1.6), child: wrapped);
    return Align(alignment: Alignment.centerLeft, child: wrapped);
  }

  List<TextHighlight> _forRun(InlineRun run) {
    final out = <TextHighlight>[];
    final a = run.base, b = run.base + run.text.length;
    for (final h in highlights) {
      if (h.end > a && h.start < b) {
        out.add(TextHighlight((h.start - a).clamp(0, run.text.length), (h.end - a).clamp(0, run.text.length), current: h.current));
      }
    }
    return out;
  }

  TextStyle _segStyle(Seg seg, TextStyle base) {
    var st = base;
    for (final x in seg.styles) {
      switch (x) {
        case SegStyle.bold:
          st = st.copyWith(fontWeight: FontWeight.w700);
        case SegStyle.italic:
          st = st.copyWith(fontStyle: FontStyle.italic);
        case SegStyle.strike:
          st = st.copyWith(decoration: TextDecoration.lineThrough);
        case SegStyle.code:
          st = st.merge(TextStyle(
            fontFamily: s.code.fontFamily,
            fontFamilyFallback: s.code.fontFamilyFallback,
            fontSize: (st.fontSize ?? s.fontSize) * 0.9,
            backgroundColor: s.inlineCodeBg,
          ));
        case SegStyle.kbd:
          st = st.merge(TextStyle(
            fontFamily: s.code.fontFamily,
            fontSize: (st.fontSize ?? s.fontSize) * 0.85,
            backgroundColor: s.inlineCodeBg,
            fontWeight: FontWeight.w600,
          ));
        case SegStyle.sub:
          st = st.copyWith(fontSize: (st.fontSize ?? s.fontSize) * 0.75, fontFeatures: const [FontFeature.subscripts()]);
        case SegStyle.sup:
          st = st.copyWith(fontSize: (st.fontSize ?? s.fontSize) * 0.75, fontFeatures: const [FontFeature.superscripts()]);
      }
    }
    if (seg.href != null) {
      st = st.copyWith(color: s.link, decoration: TextDecoration.underline, decorationColor: s.link.withValues(alpha: 0.4));
    }
    return st;
  }

  /// Inline spans for [run], with find/search highlights applied.
  List<InlineSpan> spans(InlineRun run, TextStyle base) {
    final out = <InlineSpan>[];
    final hs = _forRun(run);
    var offset = 0;
    for (final seg in run.segs) {
      final segStart = offset;
      offset += seg.text.length;
      if (seg.imageSrc != null) {
        out.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: _image(seg.imageSrc!, seg.text)));
        continue;
      }
      if (seg.mathTex != null) {
        final display = seg.mathTex!.startsWith('\u0000');
        final tex = display ? seg.mathTex!.substring(1) : seg.mathTex!;
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Math.tex(
            tex,
            mathStyle: display ? MathStyle.display : MathStyle.text,
            textStyle: base,
            onErrorFallback: (e) => _mathError(tex, e.message),
          ),
        ));
        continue;
      }
      final st = _segStyle(seg, base);
      GestureRecognizer? rec;
      final href = seg.href;
      if (href != null) {
        rec = TapGestureRecognizer()..onTap = () => ctx.onLink(href);
        recognizers.add(rec);
      }
      // Citation markers in AI answers.
      final cb = ctx.citationBuilder;
      if (cb != null && hs.isEmpty && href == null && seg.styles.isEmpty) {
        final pieces = _splitCitations(seg.text);
        for (final pc in pieces) {
          final w = pc.$2 ? cb(pc.$1, st) : null;
          out.add(w ?? TextSpan(text: pc.$1, style: st));
        }
        continue;
      }
      out.addAll(_highlighted(seg.text, segStart, st, hs, rec, href));
    }
    return out;
  }

  static final _citation = RegExp(r'\[\d{1,2}\]');

  List<(String, bool)> _splitCitations(String text) {
    final out = <(String, bool)>[];
    var last = 0;
    for (final m in _citation.allMatches(text)) {
      if (m.start > last) out.add((text.substring(last, m.start), false));
      out.add((m.group(0)!, true));
      last = m.end;
    }
    if (last < text.length) out.add((text.substring(last), false));
    return out;
  }

  List<InlineSpan> _highlighted(String text, int start, TextStyle st, List<TextHighlight> hs, GestureRecognizer? rec, String? href) {
    TextSpan mk(String t, TextStyle style) => TextSpan(
          text: t,
          style: style,
          recognizer: rec,
          mouseCursor: href != null ? SystemMouseCursors.click : null,
          onEnter: href != null ? (_) => ctx.onHover(href) : null,
          onExit: href != null ? (_) => ctx.onHover(null) : null,
        );
    if (hs.isEmpty) return [mk(text, st)];
    final end = start + text.length;
    final out = <InlineSpan>[];
    var cur = start;
    for (final h in hs) {
      if (h.end <= cur || h.start >= end) continue;
      final hs0 = h.start < cur ? cur : h.start;
      final he = h.end > end ? end : h.end;
      if (hs0 > cur) out.add(mk(text.substring(cur - start, hs0 - start), st));
      out.add(mk(
        text.substring(hs0 - start, he - start),
        st.copyWith(backgroundColor: h.current ? s.findCurrent : s.findHit, color: h.current ? Colors.black : null),
      ));
      cur = he;
    }
    if (cur < end) out.add(mk(text.substring(cur - start), st));
    return out;
  }
}

/// Fenced code block: language label, copy button, horizontal scroll.
class CodeBlockView extends StatefulWidget {
  const CodeBlockView({super.key, required this.language, required this.run, required this.style, this.highlights = const []});

  final String? language;
  final InlineRun run;
  final ReaderStyle style;
  final List<TextHighlight> highlights;

  @override
  State<CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<CodeBlockView> {
  bool _copied = false;
  final _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.run.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final pieces = CodeHighlighter.instance.highlight(widget.run.text, widget.language, s.code, dark: s.dark);
    final spans = <InlineSpan>[];
    var off = 0;
    for (final pc in pieces) {
      final start = off;
      final end = off + pc.text.length;
      off = end;
      var cur = start;
      for (final h in widget.highlights) {
        if (h.end <= cur || h.start >= end) continue;
        final a = h.start < cur ? cur : h.start;
        final b = h.end > end ? end : h.end;
        if (a > cur) spans.add(TextSpan(text: pc.text.substring(cur - start, a - start), style: pc.style));
        spans.add(TextSpan(
          text: pc.text.substring(a - start, b - start),
          style: pc.style.copyWith(backgroundColor: h.current ? s.findCurrent : s.findHit),
        ));
        cur = b;
      }
      if (cur < end) spans.add(TextSpan(text: pc.text.substring(cur - start), style: pc.style));
    }
    final lang = widget.language;
    return Container(
      decoration: BoxDecoration(
        color: s.codeBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: s.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: s.border))),
            child: Row(children: [
              Text(lang ?? 'text', style: TextStyle(fontSize: 12, color: s.muted)),
              const Spacer(),
              Tooltip(
                message: '复制代码',
                child: HyperlinkButton(
                  onPressed: _copy,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(_copied ? FluentIcons.check_mark : FluentIcons.copy, size: 12),
                    const SizedBox(width: 4),
                    Text(_copied ? '已复制' : '复制', style: const TextStyle(fontSize: 12)),
                  ]),
                ),
              ),
            ]),
          ),
          Scrollbar(
            controller: _hScroll,
            child: SingleChildScrollView(
              controller: _hScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Text.rich(TextSpan(children: spans), softWrap: false),
            ),
          ),
        ],
      ),
    );
  }
}
