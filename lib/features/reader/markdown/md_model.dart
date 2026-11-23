/// Renderer-independent Markdown document model.
///
/// A page is a list of top-level [MdBlock]s, each mapped to source lines.
/// All visible text lives in [InlineRun]s whose offsets are assigned in
/// document order, so find-in-page, search highlighting and chunking work on
/// the same text the renderer shows.
library;

enum SegStyle { bold, italic, code, strike, kbd, sub, sup }

class Seg {
  Seg(this.text, {this.styles = const {}, this.href, this.imageSrc, this.mathTex, this.lineBreak = false});

  final String text;
  final Set<SegStyle> styles;
  final String? href;

  /// Inline image: [text] holds the alt text.
  final String? imageSrc;

  /// Inline math: [text] holds the TeX source.
  final String? mathTex;
  final bool lineBreak;
}

class InlineRun {
  InlineRun(this.segs) : text = segs.map((s) => s.text).join();

  final List<Seg> segs;
  final String text;

  /// Offset of this run inside the owning block's plain text.
  int base = 0;

  bool get isEmpty => text.trim().isEmpty && segs.every((s) => s.imageSrc == null);

  /// The run is a single image (rendered as a block image).
  bool get isSoleImage {
    final visible = segs.where((s) => s.imageSrc != null || s.text.trim().isNotEmpty).toList();
    return visible.length == 1 && visible.first.imageSrc != null;
  }
}

sealed class MdNode {}

class ParaNode extends MdNode {
  ParaNode(this.run);
  final InlineRun run;
}

class HeadingNode extends MdNode {
  HeadingNode(this.level, this.run, this.anchor);
  final int level;
  final InlineRun run;
  final String anchor;
}

class CodeNode extends MdNode {
  CodeNode(this.language, this.run);
  final String? language;

  /// Single seg containing the code.
  final InlineRun run;
  String get code => run.text;
}

class MermaidNode extends MdNode {
  MermaidNode(this.run);
  final InlineRun run;
  String get source => run.text;
}

class MathBlockNode extends MdNode {
  MathBlockNode(this.run);
  final InlineRun run;
  String get tex => run.text;
}

class ListNode extends MdNode {
  ListNode({required this.ordered, required this.start, required this.items});
  final bool ordered;
  final int start;
  final List<ListItemNode> items;
}

class ListItemNode {
  ListItemNode(this.checked, this.children);

  /// null: not a task item.
  final bool? checked;
  final List<MdNode> children;
}

class QuoteNode extends MdNode {
  QuoteNode(this.children);
  final List<MdNode> children;
}

enum AlertType { note, tip, important, warning, caution }

class AlertNode extends MdNode {
  AlertNode(this.type, this.children);
  final AlertType type;
  final List<MdNode> children;
}

enum CellAlign { left, center, right }

class TableNode extends MdNode {
  TableNode(this.aligns, this.header, this.rows);
  final List<CellAlign> aligns;
  final List<InlineRun> header;
  final List<List<InlineRun>> rows;
}

class HrNode extends MdNode {}

class DetailsNode extends MdNode {
  DetailsNode(this.summary, this.children);
  final InlineRun summary;
  final List<MdNode> children;
}

enum BlockKind { heading, paragraph, code, mermaid, math, list, quote, alert, table, hr, details, other }

class MdBlock {
  MdBlock({
    required this.index,
    required this.kind,
    required this.startLine,
    required this.endLine,
    required this.nodes,
    required this.runs,
  }) : plainText = runs.map((r) => r.text).join('\n');

  final int index;
  final BlockKind kind;

  /// 1-based inclusive file line range.
  final int startLine;
  final int endLine;
  final List<MdNode> nodes;

  /// All runs in document order (offsets assigned).
  final List<InlineRun> runs;
  final String plainText;

  HeadingNode? get heading {
    if (nodes.length == 1 && nodes.first is HeadingNode) return nodes.first as HeadingNode;
    return null;
  }
}

class OutlineEntry {
  OutlineEntry(this.level, this.text, this.anchor, this.blockIndex);
  final int level;
  final String text;
  final String anchor;
  final int blockIndex;
}

class MdDocument {
  MdDocument({required this.blocks, required this.outline, required this.frontMatter, required this.bodyStartLine});

  final List<MdBlock> blocks;
  final List<OutlineEntry> outline;
  final Map<String, dynamic> frontMatter;
  final int bodyStartLine;

  late final Map<String, int> anchorToBlock = {
    for (final o in outline) o.anchor: o.blockIndex,
    ...extraAnchors,
  };

  /// `<a id="x">` anchors found in HTML.
  final Map<String, int> extraAnchors = {};

  int? blockForAnchor(String anchor) => anchorToBlock[anchor] ?? anchorToBlock[anchor.toLowerCase()];

  /// Block containing 1-based [line] (nearest following block if between blocks).
  int blockForLine(int line) {
    if (blocks.isEmpty) return 0;
    if (line < blocks.first.startLine) return 0;
    for (final b in blocks) {
      if (line <= b.endLine) return b.index;
    }
    return blocks.last.index;
  }

  /// Nearest heading at or above [blockIndex].
  OutlineEntry? headingAtOrBefore(int blockIndex) {
    OutlineEntry? best;
    for (final o in outline) {
      if (o.blockIndex <= blockIndex) {
        best = o;
      } else {
        break;
      }
    }
    return best;
  }
}
