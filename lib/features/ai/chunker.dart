import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../library/models.dart';
import '../reader/markdown/md_model.dart';
import '../reader/markdown/md_parser.dart';

/// A retrieval unit chunked from a Markdown page (doc 06 §6.1).
class DocChunk {
  const DocChunk({
    required this.libKey,
    required this.libName,
    required this.versionId,
    required this.page,
    required this.pageTitle,
    required this.lang,
    required this.anchor,
    required this.breadcrumb,
    required this.displayText,
    required this.embedText,
    required this.contentHash,
    required this.startLine,
    required this.endLine,
  });

  final String libKey;
  final String libName;
  final String versionId;

  /// Canonical (Chinese) page path relative to version dir.
  final String page;
  final String pageTitle;

  /// `'zh'` or `'original'`.
  final String lang;

  /// Nearest heading anchor (empty string if before first heading).
  final String anchor;
  final String breadcrumb;

  /// Chunk text shown in previews and RAG context.
  final String displayText;

  /// Cleaned & bounded text sent to the embedding API.
  final String embedText;
  final String contentHash;
  final int startLine;
  final int endLine;

  String get identityKey => '$libKey|$versionId|$page|$lang|$anchor|$contentHash';
}

/// Splits Markdown pages into heading-bounded, size-controlled chunks (spec 06 §6.1).
class DocChunker {
  static const int maxChunkChars = 1500;
  static const int minChunkChars = 200;

  static final _mdImg = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
  static final _mdLink = RegExp(r'\[([^\]]+)\]\([^)]*\)');

  /// Strips image syntax and link URLs while preserving link anchor text.
  static String cleanForEmbedding(String text) {
    var out = text.replaceAll(_mdImg, '');
    out = out.replaceAllMapped(_mdLink, (m) => m.group(1) ?? '');
    return out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Chunks a single parsed [MdDocument].
  static List<DocChunk> chunkDocument({
    required String libKey,
    required String libName,
    required String versionId,
    required String page,
    required String pageTitle,
    required String lang,
    required MdDocument doc,
  }) {
    if (doc.blocks.isEmpty) return const [];

    // 1. Group blocks into sections delimited by H2 / H3 headings.
    final sections = <_Section>[];
    String? curH2;
    String? curH3;
    var curAnchor = '';
    var curBreadcrumb = pageTitle;
    var curBlocks = <MdBlock>[];

    void flushSection() {
      if (curBlocks.isEmpty) return;
      sections.add(_Section(
        anchor: curAnchor,
        breadcrumb: curBreadcrumb,
        blocks: List<MdBlock>.of(curBlocks),
      ));
      curBlocks.clear();
    }

    for (final b in doc.blocks) {
      final h = b.heading;
      if (h != null && (h.level == 2 || h.level == 3)) {
        flushSection();
        final hText = h.run.text.trim();
        if (h.level == 2) {
          curH2 = hText;
          curH3 = null;
        } else {
          curH3 = hText;
        }
        curAnchor = h.anchor;
        curBreadcrumb = [
          if (curH2 != null && curH2.isNotEmpty) curH2,
          if (curH3 != null && curH3.isNotEmpty) curH3,
        ].join(' > ');
        if (curBreadcrumb.isEmpty) curBreadcrumb = pageTitle;
      }
      curBlocks.add(b);
    }
    flushSection();

    // 2. Prefer Markdown block boundaries with one block of overlap.
    final rawPieces = <_RawPiece>[];
    for (final sec in sections) {
      final blockTexts = sec.blocks.map(_blockToText).toList();
      final totalLen = blockTexts.fold<int>(0, (a, b) => a + b.length + 2);
      if (totalLen <= maxChunkChars || sec.blocks.length == 1) {
        rawPieces.add(_RawPiece(
          anchor: sec.anchor,
          breadcrumb: sec.breadcrumb,
          blocks: sec.blocks,
          texts: blockTexts,
        ));
        continue;
      }
      var i = 0;
      while (i < sec.blocks.length) {
        final pieceBlocks = <MdBlock>[];
        final pieceTexts = <String>[];
        var len = 0;
        var j = i;
        while (j < sec.blocks.length) {
          final t = blockTexts[j];
          if (pieceBlocks.isNotEmpty && len + t.length + 2 > maxChunkChars) break;
          pieceBlocks.add(sec.blocks[j]);
          pieceTexts.add(t);
          len += t.length + 2;
          j++;
        }
        rawPieces.add(_RawPiece(
          anchor: sec.anchor,
          breadcrumb: sec.breadcrumb,
          blocks: pieceBlocks,
          texts: pieceTexts,
        ));
        if (j >= sec.blocks.length) break;
        // 1-block overlap unless single huge block forced step of 1.
        i = (j - i > 1) ? j - 1 : j;
      }
    }

    // 3. Merge tiny chunks (< 200 chars) into previous chunk.
    final merged = <_RawPiece>[];
    for (final pc in rawPieces) {
      final textLen = pc.texts.fold<int>(0, (a, b) => a + b.length);
      if (merged.isNotEmpty && textLen < minChunkChars) {
        final prev = merged.last;
        final prevLen = prev.texts.fold<int>(0, (a, b) => a + b.length);
        if (prevLen + textLen <= maxChunkChars + 400) {
          prev.blocks.addAll(pc.blocks);
          prev.texts.addAll(pc.texts);
          continue;
        }
      }
      merged.add(_RawPiece(
        anchor: pc.anchor,
        breadcrumb: pc.breadcrumb,
        blocks: List<MdBlock>.of(pc.blocks),
        texts: List<String>.of(pc.texts),
      ));
    }

    // 4. Split any remaining oversized text, including a single large Markdown block.
    final chunks = <DocChunk>[];
    for (final pc in merged) {
      final displayText = pc.texts.join('\n\n').trim();
      if (displayText.isEmpty) continue;
      final fullHeader = '$libName / $pageTitle / ${pc.breadcrumb}';
      final header = fullHeader.substring(0, _safeEnd(fullHeader, maxChunkChars ~/ 3));
      for (final text in _splitText(displayText, maxChunkChars - header.length - 1)) {
        final cleaned = cleanForEmbedding(text);
        final embedText = '$header\n$cleaned';
        chunks.add(DocChunk(
          libKey: libKey,
          libName: libName,
          versionId: versionId,
          page: page,
          pageTitle: pageTitle,
          lang: lang,
          anchor: pc.anchor,
          breadcrumb: pc.breadcrumb,
          displayText: text,
          embedText: embedText,
          contentHash: sha256.convert(utf8.encode(embedText)).toString(),
          startLine: pc.blocks.first.startLine,
          endLine: pc.blocks.last.endLine,
        ));
      }
    }
    return chunks;
  }

  /// Chunks all pages (both Chinese and original `.en.md` if present) of a library version.
  static List<DocChunk> chunkVersion(Library lib, LibraryVersion version, {bool strict = false}) {
    final out = <DocChunk>[];
    for (final pg in version.orderedPages) {
      final zhAbs = version.absPath(pg);
      if (!p.isWithin(version.absDir, zhAbs) || !File(zhAbs).existsSync()) {
        if (strict) throw FileSystemException('无法读取文档库页面', pg);
        continue;
      }
      final pageTitle = version.titleOf(pg) ?? p.basenameWithoutExtension(pg);
      try {
        final zhText = File(zhAbs).readAsStringSync();
        final zhDoc = MdParser.parse(zhText);
        out.addAll(chunkDocument(
          libKey: lib.key,
          libName: lib.name,
          versionId: version.id,
          page: pg,
          pageTitle: pageTitle,
          lang: 'zh',
          doc: zhDoc,
        ));

        // Original English file if present.
        final meta = version.pages[pg];
        final origName = meta?.original ??
            (pg.toLowerCase().endsWith('.md') ? '${p.basenameWithoutExtension(pg)}.en.md' : null);
        if (origName != null) {
          final origAbs = p.normalize(p.join(p.dirname(zhAbs), origName));
          if (p.isWithin(version.absDir, origAbs) && File(origAbs).existsSync()) {
            final enText = File(origAbs).readAsStringSync();
            final enDoc = MdParser.parse(enText);
            final enTitle = enDoc.frontMatter['title']?.toString() ?? pageTitle;
            out.addAll(chunkDocument(
              libKey: lib.key,
              libName: lib.name,
              versionId: version.id,
              page: pg,
              pageTitle: enTitle,
              lang: 'original',
              doc: enDoc,
            ));
          }
        }
      } catch (_) {
        if (strict) rethrow;
      }
    }
    return out;
  }

  static String _blockToText(MdBlock b) {
    if (b.kind == BlockKind.code && b.nodes.isNotEmpty && b.nodes.first is CodeNode) {
      final c = b.nodes.first as CodeNode;
      return '```${c.language ?? ''}\n${c.code}\n```';
    }
    return b.plainText;
  }

  static Iterable<String> _splitText(String text, int limit) sync* {
    var start = 0;
    while (start < text.length) {
      var end = _safeEnd(text, start + limit);
      if (end < text.length) {
        final newline = text.lastIndexOf('\n', end - 1);
        final midpoint = start + limit ~/ 2;
        final boundary = newline >= midpoint ? newline : text.lastIndexOf(' ', end - 1);
        if (boundary >= midpoint) end = boundary + 1;
      }
      final part = text.substring(start, end);
      if (part.trim().isNotEmpty) yield part;
      start = end;
    }
  }

  static int _safeEnd(String text, int end) {
    if (end >= text.length) return text.length;
    final next = text.codeUnitAt(end);
    return next >= 0xDC00 && next <= 0xDFFF ? end - 1 : end;
  }
}

class _Section {
  _Section({required this.anchor, required this.breadcrumb, required this.blocks});
  final String anchor;
  final String breadcrumb;
  final List<MdBlock> blocks;
}

class _RawPiece {
  _RawPiece({required this.anchor, required this.breadcrumb, required this.blocks, required this.texts});
  final String anchor;
  final String breadcrumb;
  final List<MdBlock> blocks;
  final List<String> texts;
}
