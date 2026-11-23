import 'package:markdown/markdown.dart' as md;

import '../../../core/slug.dart';
import '../../library/front_matter.dart';
import 'md_model.dart';

/// Parses a Markdown page into [MdDocument].
///
/// Top-level blocks are split here (to keep source line ranges); the content
/// of each block is parsed by `package:markdown` and converted into the
/// renderer-independent node tree.
class MdParser {
  MdParser._(this._lines, this._lineOffset);

  final List<String> _lines;
  final int _lineOffset; // file line number of _lines[0] minus 1
  final SlugTracker _slugs = SlugTracker();
  final Map<String, md.LinkReference> _refs = {};
  final List<OutlineEntry> _outline = [];
  final Map<String, int> _extraAnchors = {};

  static MdDocument parse(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final fm = parseFrontMatter(normalized);
    final lines = fm.body.split('\n');
    final parser = MdParser._(lines, fm.bodyStartLine - 1);
    final blocks = parser._run();
    final doc = MdDocument(
      blocks: blocks,
      outline: parser._outline,
      frontMatter: fm.data,
      bodyStartLine: fm.bodyStartLine,
    );
    doc.extraAnchors.addAll(parser._extraAnchors);
    return doc;
  }

  // ---------------------------------------------------------------- split

  static final _fenceOpen = RegExp(r'^ {0,3}(`{3,}|~{3,})\s*([^`\s]*)?.*$');
  static final _heading = RegExp(r'^ {0,3}#{1,6}(\s|$)');
  static final _hr = RegExp(r'^ {0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$');
  static final _hrNoDash = RegExp(r'^ {0,3}((\*\s*){3,}|(_\s*){3,})$');
  static final _quote = RegExp(r'^ {0,3}>');
  static final _alertStart = RegExp(r'^ {0,3}>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$', caseSensitive: false);
  static final _listMarker = RegExp(r'^( {0,3})([-*+]|\d{1,9}[.)])(\s+|$)');
  static final _interruptList = RegExp(r'^ {0,3}([-*+]|1[.)])\s+\S');
  static final _tableSep = RegExp(r'^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$');
  static final _detailsOpen = RegExp(r'^\s*<details(\s[^>]*)?>', caseSensitive: false);
  static final _detailsClose = RegExp(r'</details>', caseSensitive: false);
  static final _mathOpen = RegExp(r'^ {0,3}\$\$');
  static final _refDef = RegExp(r'^ {0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s+["\x27(](.*)["\x27)])?\s*$');
  static final _anchorTag = RegExp(r'''<a\s+(?:id|name)=["']([^"']+)["']\s*>\s*</a>''', caseSensitive: false);

  bool _blank(String s) => s.trim().isEmpty;

  List<MdBlock> _run() {
    // Collect link reference definitions document-wide.
    var inFence = false;
    for (final l in _lines) {
      if (_fenceOpen.hasMatch(l)) inFence = !inFence;
      if (inFence) continue;
      final m = _refDef.firstMatch(l);
      if (m != null) {
        final label = m.group(1)!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        _refs.putIfAbsent(label, () => md.LinkReference(label, m.group(2)!, m.group(3)));
      }
    }

    final blocks = <MdBlock>[];
    final n = _lines.length;
    var i = 0;
    while (i < n) {
      final line = _lines[i];
      if (_blank(line)) {
        i++;
        continue;
      }
      final start = i;
      BlockKind kind;
      int end; // exclusive

      final fence = _fenceOpen.firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!;
        end = i + 1;
        while (end < n) {
          final t = _lines[end].trim();
          if (t.startsWith(marker[0] * marker.length) && t.replaceAll(marker[0], '').trim().isEmpty) {
            end++;
            break;
          }
          end++;
        }
        final lang = (fence.group(2) ?? '').toLowerCase();
        kind = lang == 'mermaid' ? BlockKind.mermaid : BlockKind.code;
      } else if (_mathOpen.hasMatch(line)) {
        kind = BlockKind.math;
        final t = line.trim();
        if (t.length > 4 && t.endsWith(r'$$')) {
          end = i + 1;
        } else {
          end = i + 1;
          while (end < n && !_lines[end].trim().endsWith(r'$$')) {
            end++;
          }
          end = end < n ? end + 1 : n;
        }
      } else if (_heading.hasMatch(line)) {
        kind = BlockKind.heading;
        end = i + 1;
      } else if (_hr.hasMatch(line)) {
        kind = BlockKind.hr;
        end = i + 1;
      } else if (_quote.hasMatch(line)) {
        kind = _alertStart.hasMatch(line) ? BlockKind.alert : BlockKind.quote;
        end = i + 1;
        while (end < n && !_blank(_lines[end]) && !_fenceOpen.hasMatch(_lines[end]) && !_heading.hasMatch(_lines[end])) {
          end++;
        }
      } else if (_listMarker.hasMatch(line)) {
        kind = BlockKind.list;
        end = _scanList(i);
      } else if (line.contains('|') && i + 1 < n && _tableSep.hasMatch(_lines[i + 1]) && _lines[i + 1].contains('-')) {
        kind = BlockKind.table;
        end = i + 2;
        while (end < n && !_blank(_lines[end]) && _lines[end].contains('|')) {
          end++;
        }
      } else if (_detailsOpen.hasMatch(line)) {
        kind = BlockKind.details;
        var depth = 0;
        end = i;
        while (end < n) {
          depth += _detailsOpen.allMatches(_lines[end]).length;
          depth -= _detailsClose.allMatches(_lines[end]).length;
          end++;
          if (depth <= 0) break;
        }
      } else {
        kind = BlockKind.paragraph;
        end = i + 1;
        while (end < n) {
          final l = _lines[end];
          if (_blank(l) ||
              _fenceOpen.hasMatch(l) ||
              _heading.hasMatch(l) ||
              _quote.hasMatch(l) ||
              _hrNoDash.hasMatch(l) ||
              _interruptList.hasMatch(l) ||
              _mathOpen.hasMatch(l) ||
              _detailsOpen.hasMatch(l)) {
            break;
          }
          end++;
          // Setext heading underline ends the paragraph.
          if (RegExp(r'^ {0,3}(=+|-+)\s*$').hasMatch(l)) break;
        }
      }
      if (end <= start) end = start + 1;
      final block = _buildBlock(blocks.length, kind, start, end);
      if (block != null) blocks.add(block);
      i = end;
    }
    return blocks;
  }

  int _indent(String s) {
    var c = 0;
    for (final ch in s.codeUnits) {
      if (ch == 0x20) {
        c++;
      } else if (ch == 0x09) {
        c += 4;
      } else {
        break;
      }
    }
    return c;
  }

  int _scanList(int startIdx) {
    final n = _lines.length;
    var end = startIdx + 1;
    var inFence = false;
    String? fenceMarker;
    while (end < n) {
      final l = _lines[end];
      final fm = _fenceOpen.firstMatch(l);
      if (inFence) {
        if (fm != null && l.trim().startsWith(fenceMarker!)) inFence = false;
        end++;
        continue;
      }
      if (fm != null && _indent(l) >= 2) {
        inFence = true;
        fenceMarker = fm.group(1)!;
        end++;
        continue;
      }
      if (_blank(l)) {
        var k = end + 1;
        while (k < n && _blank(_lines[k])) {
          k++;
        }
        if (k >= n) return k;
        final next = _lines[k];
        if (_indent(next) >= 2 || _listMarker.hasMatch(next)) {
          end = k;
          continue;
        }
        return end;
      }
      if (_indent(l) < 2 &&
          !_listMarker.hasMatch(l) &&
          (_heading.hasMatch(l) || fm != null || _hr.hasMatch(l) || _quote.hasMatch(l) || _mathOpen.hasMatch(l))) {
        return end;
      }
      end++;
    }
    return end;
  }

  // ---------------------------------------------------------------- build

  late _RunCollector _rc;

  MdBlock? _buildBlock(int index, BlockKind kind, int start, int end) {
    final lines = _lines.sublist(start, end);
    _rc = _RunCollector();
    List<MdNode> nodes;
    switch (kind) {
      case BlockKind.code:
      case BlockKind.mermaid:
        final first = _fenceOpen.firstMatch(lines.first)!;
        final marker = first.group(1)!;
        final lang = (first.group(2) ?? '').trim();
        final body = <String>[];
        for (var k = 1; k < lines.length; k++) {
          final t = lines[k].trim();
          if (k == lines.length - 1 && t.startsWith(marker[0] * marker.length) && t.replaceAll(marker[0], '').isEmpty) {
            break;
          }
          body.add(lines[k]);
        }
        final indent = _indent(lines.first);
        final code = body.map((l) => _stripIndent(l, indent)).join('\n');
        final run = _rc.run([Seg(code, styles: const {SegStyle.code})]);
        nodes = [kind == BlockKind.mermaid ? MermaidNode(run) : CodeNode(lang.isEmpty ? null : lang, run)];
      case BlockKind.math:
        var tex = lines.join('\n').trim();
        tex = tex.substring(2);
        if (tex.endsWith(r'$$')) tex = tex.substring(0, tex.length - 2);
        nodes = [MathBlockNode(_rc.run([Seg(tex.trim(), mathTex: tex.trim())]))];
      case BlockKind.alert:
        final m = _alertStart.firstMatch(lines.first)!;
        final type = AlertType.values.byName(m.group(1)!.toLowerCase());
        final inner = lines.skip(1).map((l) => l.replaceFirst(RegExp(r'^ {0,3}> ?'), '')).toList();
        nodes = [AlertNode(type, _convertAll(_parseLines(inner), index))];
      case BlockKind.details:
        nodes = [_buildDetails(lines, index)];
      default:
        final nodesMd = _parseLines(lines);
        nodes = _convertAll(nodesMd, index);
    }
    if (nodes.isEmpty) {
      // e.g. link reference definitions only
      return null;
    }
    if (nodes.length == 1 && nodes.first is HeadingNode) kind = BlockKind.heading;
    return MdBlock(
      index: index,
      kind: kind,
      startLine: start + 1 + _lineOffset,
      endLine: end + _lineOffset,
      nodes: nodes,
      runs: _rc.runs,
    );
  }

  String _stripIndent(String l, int indent) {
    var k = 0;
    while (k < indent && k < l.length && l[k] == ' ') {
      k++;
    }
    return l.substring(k);
  }

  DetailsNode _buildDetails(List<String> lines, int blockIndex) {
    final text = lines.join('\n');
    final sm = RegExp(r'<summary>([\s\S]*?)</summary>', caseSensitive: false).firstMatch(text);
    final summaryText = sm?.group(1)?.trim() ?? '详情';
    var inner = text;
    inner = inner.replaceFirst(RegExp(r'^\s*<details[^>]*>', caseSensitive: false), '');
    inner = inner.replaceFirst(RegExp(r'</details>\s*$', caseSensitive: false), '');
    if (sm != null) inner = inner.replaceFirst(sm.group(0)!, '');
    final summaryRun = _rc.run(_inlineSegs(_doc().parseInline(summaryText), const {}, null));
    final children = _convertAll(_parseLines(inner.split('\n')), blockIndex);
    return DetailsNode(summaryRun, children);
  }

  md.Document _doc() {
    final d = md.Document(
      encodeHtml: false,
      withDefaultInlineSyntaxes: true,
      blockSyntaxes: const [
        md.FencedCodeBlockSyntax(),
        md.TableSyntax(),
        md.UnorderedListWithCheckboxSyntax(),
        md.OrderedListWithCheckboxSyntax(),
      ],
      inlineSyntaxes: [
        _DisplayMathInlineSyntax(),
        _InlineMathSyntax(),
        _AnchorTagSyntax(),
        _WhitelistTagSyntax(),
        _BrSyntax(),
        md.StrikethroughSyntax(),
        md.AutolinkExtensionSyntax(),
      ],
    );
    d.linkReferences.addAll(_refs);
    return d;
  }

  List<md.Node> _parseLines(List<String> lines) => _doc().parseLines(lines);

  // ---------------------------------------------------------------- convert

  List<MdNode> _convertAll(List<md.Node> nodes, int blockIndex) {
    final out = <MdNode>[];
    final pendingInline = <md.Node>[];
    void flush() {
      if (pendingInline.isEmpty) return;
      final run = _rc.run(_inlineSegs(List.of(pendingInline), const {}, null));
      pendingInline.clear();
      if (!run.isEmpty) out.add(ParaNode(run));
    }

    for (final n in nodes) {
      if (n is md.Element && _isBlockTag(n.tag)) {
        flush();
        final c = _convert(n, blockIndex);
        if (c != null) out.add(c);
      } else {
        pendingInline.add(n);
      }
    }
    flush();
    return out;
  }

  static const _blockTags = {
    'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre', 'ul', 'ol', 'blockquote', 'table', 'hr', 'div', //
  };

  bool _isBlockTag(String t) => _blockTags.contains(t);

  MdNode? _convert(md.Element e, int blockIndex) {
    switch (e.tag) {
      case 'p':
        final children = e.children ?? const [];
        // Raw HTML anchor-only paragraphs.
        final run = _rc.run(_inlineSegs(children, const {}, null, blockIndex: blockIndex));
        if (run.isEmpty) return null;
        return ParaNode(run);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.parse(e.tag.substring(1));
        final children = List<md.Node>.of(e.children ?? const []);
        String? explicitId;
        // Strip trailing {#id} from the last text node.
        if (children.isNotEmpty && children.last is md.Text) {
          final t = (children.last as md.Text).text;
          final (rest, id) = splitExplicitAnchor(t);
          if (id != null) {
            explicitId = id;
            children[children.length - 1] = md.Text(rest);
          }
        }
        final segs = _inlineSegs(children, const {}, null, blockIndex: blockIndex);
        final text = segs.map((s) => s.text).join().trim();
        final anchor = explicitId != null ? _slugs.useExplicit(explicitId) : _slugs.unique(githubSlug(text));
        final run = _rc.run(segs);
        _outline.add(OutlineEntry(level, text, anchor, blockIndex));
        return HeadingNode(level, run, anchor);
      case 'pre':
        final code = e.children?.isNotEmpty == true ? e.children!.first : null;
        String? lang;
        var text = e.textContent;
        if (code is md.Element && code.tag == 'code') {
          final cls = code.attributes['class'];
          if (cls != null && cls.startsWith('language-')) lang = cls.substring(9);
          text = code.textContent;
        }
        if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
        final run = _rc.run([Seg(_decodeEntities(text), styles: const {SegStyle.code})]);
        if (lang == 'mermaid') return MermaidNode(run);
        return CodeNode(lang, run);
      case 'ul' || 'ol':
        final items = <ListItemNode>[];
        for (final li in (e.children ?? const <md.Node>[]).whereType<md.Element>()) {
          if (li.tag != 'li') continue;
          bool? checked;
          var kids = List<md.Node>.of(li.children ?? const []);
          // Checkbox may be first child or first child of a leading <p>.
          md.Element? box;
          if (kids.isNotEmpty && kids.first is md.Element && (kids.first as md.Element).tag == 'input') {
            box = kids.removeAt(0) as md.Element;
          } else if (kids.isNotEmpty &&
              kids.first is md.Element &&
              (kids.first as md.Element).tag == 'p' &&
              ((kids.first as md.Element).children?.isNotEmpty ?? false) &&
              (kids.first as md.Element).children!.first is md.Element &&
              ((kids.first as md.Element).children!.first as md.Element).tag == 'input') {
            final pEl = kids.first as md.Element;
            box = pEl.children!.first as md.Element;
            kids[0] = md.Element(pEl.tag, pEl.children!.sublist(1));
          }
          if (box != null) checked = box.attributes['checked'] == 'true';
          if (kids.isNotEmpty && kids.first is md.Text) {
            kids[0] = md.Text((kids.first as md.Text).text.replaceFirst(RegExp(r'^\s+'), ''));
          }
          items.add(ListItemNode(checked, _convertAll(kids, blockIndex)));
        }
        return ListNode(
          ordered: e.tag == 'ol',
          start: int.tryParse(e.attributes['start'] ?? '') ?? 1,
          items: items,
        );
      case 'blockquote':
        return QuoteNode(_convertAll(e.children ?? const [], blockIndex));
      case 'hr':
        return HrNode();
      case 'table':
        final aligns = <CellAlign>[];
        final header = <InlineRun>[];
        final rows = <List<InlineRun>>[];
        for (final section in (e.children ?? const <md.Node>[]).whereType<md.Element>()) {
          for (final tr in (section.children ?? const <md.Node>[]).whereType<md.Element>()) {
            final cells = <InlineRun>[];
            for (final cell in (tr.children ?? const <md.Node>[]).whereType<md.Element>()) {
              if (section.tag == 'thead') {
                final style = cell.attributes['align'] ?? cell.attributes['style'] ?? '';
                aligns.add(style.contains('center')
                    ? CellAlign.center
                    : style.contains('right')
                        ? CellAlign.right
                        : CellAlign.left);
              }
              cells.add(_rc.run(_inlineSegs(cell.children ?? const [], const {}, null, blockIndex: blockIndex)));
            }
            if (section.tag == 'thead') {
              header.addAll(cells);
            } else {
              rows.add(cells);
            }
          }
        }
        return TableNode(aligns, header, rows);
      default:
        final run = _rc.run(_inlineSegs(e.children ?? const [], const {}, null, blockIndex: blockIndex));
        return run.isEmpty ? null : ParaNode(run);
    }
  }

  List<Seg> _inlineSegs(List<md.Node> nodes, Set<SegStyle> styles, String? href, {int? blockIndex}) {
    final out = <Seg>[];
    for (final n in nodes) {
      if (n is md.Text) {
        var t = _softBreaks(_decodeEntities(n.text));
        // Raw HTML anchors inside text.
        t = t.replaceAllMapped(_anchorTag, (m) {
          if (blockIndex != null) _extraAnchors.putIfAbsent(m.group(1)!, () => blockIndex);
          return '';
        });
        if (t.isNotEmpty) out.add(Seg(t, styles: styles, href: href));
      } else if (n is md.Element) {
        switch (n.tag) {
          case 'strong':
            out.addAll(_inlineSegs(n.children ?? const [], {...styles, SegStyle.bold}, href, blockIndex: blockIndex));
          case 'em':
            out.addAll(_inlineSegs(n.children ?? const [], {...styles, SegStyle.italic}, href, blockIndex: blockIndex));
          case 'del':
            out.addAll(_inlineSegs(n.children ?? const [], {...styles, SegStyle.strike}, href, blockIndex: blockIndex));
          case 'code':
            out.add(Seg(_decodeEntities(n.textContent), styles: {...styles, SegStyle.code}, href: href));
          case 'kbd':
            out.add(Seg(n.textContent, styles: {...styles, SegStyle.kbd}, href: href));
          case 'sub':
            out.add(Seg(n.textContent, styles: {...styles, SegStyle.sub}, href: href));
          case 'sup':
            out.add(Seg(n.textContent, styles: {...styles, SegStyle.sup}, href: href));
          case 'a':
            out.addAll(_inlineSegs(n.children ?? const [], styles, n.attributes['href'] ?? href, blockIndex: blockIndex));
          case 'img':
            out.add(Seg(n.attributes['alt'] ?? '', imageSrc: n.attributes['src'] ?? '', href: href));
          case 'br':
            out.add(Seg('\n', lineBreak: true));
          case 'math':
            out.add(Seg(n.textContent, mathTex: n.textContent));
          case 'math-display':
            out.add(Seg(n.textContent, mathTex: '\u0000${n.textContent}'));
          case 'anchor':
            if (blockIndex != null) _extraAnchors.putIfAbsent(n.attributes['id']!, () => blockIndex);
          case 'input':
            break;
          default:
            out.addAll(_inlineSegs(n.children ?? const [], styles, href, blockIndex: blockIndex));
        }
      }
    }
    return out;
  }
}

class _RunCollector {
  final List<InlineRun> runs = [];
  int _offset = 0;

  InlineRun run(List<Seg> segs) {
    final r = InlineRun(segs)..base = _offset;
    runs.add(r);
    _offset += r.text.length + 1;
    return r;
  }
}

String _softBreaks(String s) {
  if (!s.contains('\n')) return s;
  return s.replaceAllMapped(RegExp(r'(.?)[ \t]*\n[ \t]*(.?)'), (m) {
    final a = m.group(1)!, b = m.group(2)!;
    final cjk = RegExp(r'[\u3000-\u9fff\uff00-\uffef]');
    final sep = (a.isNotEmpty && b.isNotEmpty && cjk.hasMatch(a) && cjk.hasMatch(b)) ? '' : ' ';
    return '$a$sep$b';
  });
}

String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
    final e = m.group(1)!;
    if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
    if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
    return switch (e) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      'nbsp' => '\u00A0',
      'copy' => '©',
      'mdash' => '—',
      'ndash' => '–',
      'hellip' => '…',
      _ => m.group(0)!,
    };
  });
}

class _InlineMathSyntax extends md.InlineSyntax {
  _InlineMathSyntax() : super(r'\$(?![\s$])([^$\n]+?)(?<![\s\\])\$(?!\d)', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('math', match.group(1)!));
    return true;
  }
}

class _DisplayMathInlineSyntax extends md.InlineSyntax {
  _DisplayMathInlineSyntax() : super(r'\$\$([^$]+?)\$\$', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('math-display', match.group(1)!.trim()));
    return true;
  }
}

/// `<kbd>`, `<sub>`, `<sup>` (HTML whitelist). Other tags stay plain text.
class _WhitelistTagSyntax extends md.InlineSyntax {
  _WhitelistTagSyntax() : super(r'<(kbd|sub|sup)>([^<]*)</\1>', startCharacter: 0x3c);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text(match.group(1)!.toLowerCase(), match.group(2)!));
    return true;
  }
}

class _BrSyntax extends md.InlineSyntax {
  _BrSyntax() : super(r'<br\s*/?>', startCharacter: 0x3c);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

class _AnchorTagSyntax extends md.InlineSyntax {
  _AnchorTagSyntax() : super(r'''<a\s+(?:id|name)=["']([^"']+)["']\s*>\s*</a>''', startCharacter: 0x3c);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('anchor')..attributes['id'] = match.group(1)!);
    return true;
  }
}
