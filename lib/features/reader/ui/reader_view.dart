import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../library/library_controller.dart';
import '../../settings/settings_controller.dart';
import '../find/find_bar.dart';
import '../find/find_controller.dart';
import '../links/link_resolver.dart';
import '../markdown/md_model.dart';
import '../mermaid/mermaid_block.dart';
import '../navigation/navigation_controller.dart';
import '../render/block_renderer.dart';

/// Selected text in the reader (used to pre-fill Ctrl+F per FR-FIND-01).
final readerSelectionProvider = NotifierProvider<ReaderSelectionNotifier, String>(ReaderSelectionNotifier.new);

class ReaderSelectionNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String v) => state = v;
}

/// Lazy block-based Markdown document reader (FR-RD-01..14, FR-LK-01..04).
class ReaderView extends ConsumerStatefulWidget {
  const ReaderView({super.key});

  @override
  ConsumerState<ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends ConsumerState<ReaderView> {
  final ItemScrollController _scrollCtrl = ItemScrollController();
  final ItemPositionsListener _posListener = ItemPositionsListener.create();
  int _lastScrollToken = -1;
  int _lastFindToken = -1;
  MdDocument? _lastAttachedDoc;
  String? _lastReportedPage;
  int? _lastReportedBlock;

  @override
  void initState() {
    super.initState();
    _posListener.itemPositions.addListener(_onPositionsChanged);
  }

  @override
  void dispose() {
    _posListener.itemPositions.removeListener(_onPositionsChanged);
    super.dispose();
  }

  void _onPositionsChanged() {
    final page = ref.read(navigationProvider).page;
    if (page == null) return;
    final positions = _posListener.itemPositions.value;
    if (positions.isEmpty) return;

    // Item 0 is the page header; item i+1 is doc.blocks[i].
    ItemPosition? topItem;
    for (final pos in positions) {
      if (pos.itemTrailingEdge > 0 && (topItem == null || pos.index < topItem.index)) {
        topItem = pos;
      }
    }
    if (topItem == null) return;
    final blockIdx = (topItem.index - 1).clamp(0, page.doc.blocks.isEmpty ? 0 : page.doc.blocks.length - 1);
    final pageKey = '${page.lib.key}|${page.version.id}|${page.page}';
    if (_lastReportedPage == pageKey && _lastReportedBlock == blockIdx) return;
    _lastReportedPage = pageKey;
    _lastReportedBlock = blockIdx;
    final heading = page.doc.headingAtOrBefore(blockIdx);
    final sectionStart = heading?.blockIndex ?? 0;
    final nextHeading = page.doc.outline.where((o) => o.blockIndex > sectionStart).firstOrNull;
    final sectionEnd = nextHeading?.blockIndex ?? page.doc.blocks.length;
    final span = (sectionEnd - sectionStart).clamp(1, 1 << 20);
    final ratio = ((blockIdx - sectionStart) / span).clamp(0.0, 1.0);
    ref.read(navigationProvider.notifier).reportPosition(
          anchor: heading?.anchor,
          ratio: ratio,
          blockIndex: blockIdx,
        );
  }

  void _applyScroll(PageData page, ScrollRequest req) {
    if (req.token == _lastScrollToken) return;
    _lastScrollToken = req.token;

    int targetBlock = 0;
    if (req.anchor != null) {
      final idx = page.doc.blockForAnchor(req.anchor!);
      if (idx != null) {
        targetBlock = idx;
        if (req.ratio != null && req.ratio! > 0) {
          final nextH = page.doc.outline.where((o) => o.blockIndex > idx).firstOrNull;
          final end = nextH?.blockIndex ?? page.doc.blocks.length;
          targetBlock = (idx + ((end - idx) * req.ratio!).round()).clamp(0, page.doc.blocks.length - 1);
        }
      }
    } else if (req.line != null) {
      targetBlock = page.doc.blockForLine(req.line!);
    } else if (req.blockIndex != null) {
      targetBlock = req.blockIndex!.clamp(0, page.doc.blocks.isEmpty ? 0 : page.doc.blocks.length - 1);
    }

    if (req.highlight != null && req.highlight!.isNotEmpty) {
      Future.microtask(() {
        ref.read(findProvider.notifier).highlightTransient(req.highlight!, nearBlock: targetBlock);
      });
    }

    final listIdx = (req.anchor == null && req.line == null && targetBlock == 0) ? 0 : targetBlock + 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.isAttached) return;
      _scrollCtrl.jumpTo(index: listIdx, alignment: 0.04);
    });
  }

  void _handleLink(String href, PageData page) {
    final loc = ref.read(navigationProvider).location;
    if (loc == null) return;
    final urls = ref.read(libraryProvider).urls;
    final target = resolveLink(href, loc, page.version, urls);
    switch (target) {
      case InternalLink(:final location):
        ref.read(navigationProvider.notifier).open(location);
      case AnchorLink(:final anchor):
        ref.read(navigationProvider.notifier).open(loc.copyWith(anchor: anchor));
      case ExternalLink(:final uri):
        launchUrl(uri, mode: LaunchMode.externalApplication);
      case InvalidLink(:final reason):
        ref.read(noticeProvider.notifier).show('无法打开链接：$reason', isError: true);
    }
  }

  void _handleHover(String? href, PageData page) {
    if (href == null) {
      ref.read(statusTextProvider.notifier).set(null);
      return;
    }
    final loc = ref.read(navigationProvider).location;
    if (loc == null) return;
    final libs = ref.read(libraryProvider);
    final target = resolveLink(href, loc, page.version, libs.urls);
    final label = switch (target) {
      InternalLink(:final location) =>
        '${libs.byKey(location.libKey)?.name ?? location.libKey} · ${libs.version(location.libKey, location.versionId)?.titleOf(location.page) ?? location.page}${location.anchor != null ? ' #${location.anchor}' : ''}',
      AnchorLink(:final anchor) => '本页锚点 #$anchor',
      ExternalLink(:final uri) => uri.toString(),
      InvalidLink(:final reason) => reason,
    };
    ref.read(statusTextProvider.notifier).set(label);
  }

  @override
  Widget build(BuildContext context) {
    final nav = ref.watch(navigationProvider);
    final settings = ref.watch(settingsProvider);
    final find = ref.watch(findProvider);
    final theme = FluentTheme.of(context);

    if (nav.loading && nav.page == null) {
      return const Center(child: ProgressRing());
    }
    if (nav.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: InfoBar(
            title: const Text('无法打开页面'),
            content: Text(nav.error!),
            severity: InfoBarSeverity.error,
          ),
        ),
      );
    }
    final page = nav.page;
    if (page == null) {
      return Center(
        child: Text('从左侧目录或 Home 选择一篇文档开始阅读', style: TextStyle(color: theme.resources.textFillColorSecondary)),
      );
    }

    // Keep FindController attached to the current document (only on doc change).
    if (!identical(_lastAttachedDoc, page.doc)) {
      _lastAttachedDoc = page.doc;
      Future.microtask(() {
        if (mounted) ref.read(findProvider.notifier).attach(page.doc);
      });
    }

    // Apply scroll requests from navigation.
    if (nav.scroll != null) {
      _applyScroll(page, nav.scroll!);
    }

    // Scroll to active find match when changed.
    if (find.token != _lastFindToken && find.currentMatch != null) {
      _lastFindToken = find.token;
      final blk = find.currentMatch!.block;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollCtrl.isAttached) return;
        _scrollCtrl.scrollTo(
          index: blk + 1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: 0.25,
        );
      });
    }

    final effectiveFontSize = (settings.fontSize * settings.fontScale).clamp(10.0, 42.0);
    final maxW = settings.contentMaxWidth <= 0 ? null : settings.contentMaxWidth.toDouble();
    final style = ReaderStyle(
      theme: theme,
      fontSize: effectiveFontSize,
      bodyFont: settings.bodyFont,
      codeFont: settings.codeFont,
      maxWidth: maxW,
    );

    final renderCtx = RenderContext(
      style: style,
      onLink: (href) => _handleLink(href, page),
      onHover: (href) => _handleHover(href, page),
      pageFile: page.filePath,
      libDir: page.lib.dir,
      mermaidBuilder: (src) => MermaidBlock(source: src, style: style),
    );

    Widget wrapWidth(Widget child) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW ?? double.infinity),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: child,
          ),
        ),
      );
    }

    return Stack(
      children: [
        SelectionArea(
          onSelectionChanged: (SelectedContent? content) {
            ref.read(readerSelectionProvider.notifier).set(content?.plainText ?? '');
          },
          child: ScrollablePositionedList.builder(
            key: ValueKey('${page.lib.key}|${page.version.id}|${page.page}|${page.lang}'),
            itemScrollController: _scrollCtrl,
            itemPositionsListener: _posListener,
            padding: const EdgeInsets.only(top: 20, bottom: 72),
            itemCount: page.doc.blocks.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return wrapWidth(_PageHeader(
                  page: page,
                  style: style,
                  onOpenSource: page.sourceUrl != null ? () => _handleLink(page.sourceUrl!, page) : null,
                  onToggleLang: () {
                    final next = settings.language == 'zh' ? 'original' : 'zh';
                    ref.read(settingsProvider.notifier).set('reading.language', next);
                  },
                ));
              }
              final block = page.doc.blocks[index - 1];
              return wrapWidth(
                BlockView(
                  block: block,
                  ctx: renderCtx,
                  highlights: find.highlightsFor(block.index),
                ),
              );
            },
          ),
        ),
        const Positioned(top: 10, right: 16, child: FindBar()),
      ],
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.page,
    required this.style,
    this.onOpenSource,
    required this.onToggleLang,
  });

  final PageData page;
  final ReaderStyle style;
  final VoidCallback? onOpenSource;
  final VoidCallback onToggleLang;

  @override
  Widget build(BuildContext context) {
    final s = style;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(page.title, style: s.heading(1)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${page.lib.name} · ${page.version.label}',
                style: TextStyle(fontSize: 12, color: s.muted),
              ),
              GestureDetector(
                onTap: onToggleLang,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: s.inlineCodeBg,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      page.lang == 'original' ? '原文' : '中文',
                      style: TextStyle(fontSize: 11, color: s.accent, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
              if (page.fetchedAt != null && page.fetchedAt!.isNotEmpty)
                Text(
                  '抓取于 ${_shortDate(page.fetchedAt!)}',
                  style: TextStyle(fontSize: 12, color: s.muted),
                ),
              if (page.sourceUrl != null && page.sourceUrl!.isNotEmpty)
                GestureDetector(
                  onTap: onOpenSource,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(FluentIcons.globe, size: 12, color: s.link),
                      const SizedBox(width: 4),
                      Text(
                        '原网页',
                        style: TextStyle(fontSize: 12, color: s.link, decoration: TextDecoration.underline),
                      ),
                    ]),
                  ),
                ),
            ],
          ),
          if (page.originalMissing) ...[
            const SizedBox(height: 10),
            const InfoBar(
              title: Text('暂无原文'),
              content: Text('该页面未提供英文原文，当前显示中文版本。'),
              severity: InfoBarSeverity.info,
            ),
          ],
          const SizedBox(height: 12),
          Container(height: 1, color: s.border),
        ],
      ),
    );
  }

  String _shortDate(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;
}
