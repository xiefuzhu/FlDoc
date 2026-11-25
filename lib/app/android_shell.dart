import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/ai/ai_controller.dart';
import '../features/ai/ui/ai_panel.dart';
import '../features/library/library_controller.dart';
import '../features/library/library_transfer.dart';
import '../features/palette/command_registry.dart';
import '../features/reader/find/find_controller.dart';
import '../features/reader/navigation/navigation_controller.dart';
import '../features/settings/settings_controller.dart';
import 'platform_shells.dart';

const androidWideLayoutWidth = 720.0;
const _threePaneWidth = 960.0;
const _sidebarWidth = 216.0;
const _chatWidth = 320.0;
const _touchButtonStyle = ButtonStyle(
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  ),
);

class AndroidShell extends ConsumerWidget {
  const AndroidShell({
    super.key,
    required this.content,
    required this.wide,
    required this.onOpenChatHistory,
    required this.onImportFolder,
    required this.onImportHelp,
  });

  final Widget content;
  final bool wide;
  final VoidCallback onOpenChatHistory;
  final VoidCallback onImportFolder;
  final VoidCallback onImportHelp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = FluentTheme.of(context);
    final nav = ref.watch(navigationProvider);
    final ai = ref.watch(aiControllerProvider.select((s) => s.visible));
    final palette = ref.watch(paletteProvider.select((s) => s.open));
    final findOpen = ref.watch(findProvider.select((s) => s.open));
    final sidebar = ref.watch(settingsProvider.select((s) => s.sidebarVisible));
    final navigation = ref.read(navigationProvider.notifier);
    final chat = ref.read(aiControllerProvider.notifier);
    final commands = ref.read(paletteProvider.notifier);
    final reading = nav.view == AppView.reader;
    final home = nav.view == AppView.home;
    final fullScreenChat = ai && !wide;
    final chrome = theme.resources.solidBackgroundFillColorBase;
    final border = BorderSide(color: theme.resources.surfaceStrokeColorDefault);

    if (!wide) {
      ref.listen(navigationProvider.select((s) => (s.view, s.location)), (
        _,
        next,
      ) {
        if (next.$1 != AppView.home && ref.read(aiControllerProvider).visible) {
          chat.setVisible(false);
        }
      });
    }

    void back() {
      if (nav.canBack) {
        navigation.back();
      } else {
        navigation.goHome(push: false);
      }
    }

    void openHome() {
      if (!wide) chat.setVisible(false);
      navigation.goHome();
    }

    void openSettings() {
      if (!wide) chat.setVisible(false);
      navigation.openSettings();
    }

    return PopScope(
      canPop: !palette && !ai && !findOpen && home,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (palette) {
          commands.close();
        } else if (ai) {
          chat.setVisible(false);
        } else if (findOpen) {
          ref.read(findProvider.notifier).close();
        } else {
          back();
        }
      },
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fitsThreePanes = constraints.maxWidth >= _threePaneWidth;
              final showSidebar = wide && sidebar && (!ai || fitsThreePanes);
              return Column(
                children: [
                  Container(
                    constraints: const BoxConstraints(minHeight: 54),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: chrome,
                      border: Border(bottom: border),
                    ),
                    child: Row(
                      children: [
                        if (wide)
                          _TouchAction(
                            FluentIcons.open_pane,
                            showSidebar ? '收起侧栏' : '展开侧栏',
                            () {
                              if (ai && !fitsThreePanes) chat.setVisible(false);
                              ref
                                  .read(settingsProvider.notifier)
                                  .set('sidebar.visible', !showSidebar);
                            },
                          ),
                        if (wide || (!home && !fullScreenChat))
                          _TouchAction(
                            FluentIcons.back,
                            '返回',
                            !home || nav.canBack ? back : null,
                          ),
                        if (wide)
                          _TouchAction(
                            FluentIcons.forward,
                            '前进',
                            nav.canForward ? navigation.forward : null,
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            fullScreenChat
                                ? '文档问答'
                                : switch (nav.view) {
                                    AppView.home => 'flDoc',
                                    AppView.reader =>
                                      nav.page?.lib.name ?? '阅读',
                                    AppView.settings => '设置',
                                  },
                            style: theme.typography.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (reading && !fullScreenChat && !showSidebar)
                          _TouchAction(
                            FluentIcons.bulleted_list,
                            '章节目录',
                            () => _showOutline(context),
                          ),
                        if (wide) ...[
                          Button(
                            style: _touchButtonStyle,
                            onPressed: () => openPlatformSearch(ref),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(FluentIcons.search, size: 15),
                                SizedBox(width: 8),
                                Text('搜索文档'),
                              ],
                            ),
                          ),
                          _TouchAction(
                            FluentIcons.chat,
                            ai ? '关闭问答' : '打开问答',
                            chat.togglePanel,
                            selected: ai,
                          ),
                        ],
                        _TouchMenu(
                          label: '更多操作',
                          items: [
                            if (reading && !fullScreenChat)
                              MenuFlyoutItem(
                                text: const Text('页内查找'),
                                onPressed: () =>
                                    ref.read(findProvider.notifier).open(),
                              ),
                            if (!wide && !home && !fullScreenChat) ...[
                              MenuFlyoutItem(
                                text: const Text('全文搜索'),
                                onPressed: () => openPlatformSearch(ref),
                              ),
                              MenuFlyoutItem(
                                text: const Text('文档问答'),
                                onPressed: () => chat.setVisible(true),
                              ),
                            ],
                            MenuFlyoutItem(
                              text: const Text('命令面板'),
                              onPressed: commands.openRoot,
                            ),
                            if (nav.view != AppView.settings || fullScreenChat)
                              MenuFlyoutItem(
                                text: const Text('设置'),
                                onPressed: openSettings,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            right: wide && ai ? _chatWidth : 0,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (showSidebar)
                                Container(
                                  width: _sidebarWidth,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: chrome,
                                    border: Border(right: border),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      ListTile.selectable(
                                        leading: const Icon(
                                          FluentIcons.library,
                                          size: 17,
                                        ),
                                        title: const Text('文档库'),
                                        selected: home,
                                        onPressed: openHome,
                                      ),
                                      const Expanded(
                                        child: DocumentOutline(
                                          compact: true,
                                          touch: true,
                                        ),
                                      ),
                                      ListTile.selectable(
                                        leading: const Icon(
                                          FluentIcons.settings,
                                          size: 17,
                                        ),
                                        title: const Text('设置'),
                                        selected: nav.view == AppView.settings,
                                        onPressed: openSettings,
                                      ),
                                    ],
                                  ),
                                ),
                              Expanded(
                                key: const ValueKey('android-content'),
                                child: Visibility(
                                  visible: !fullScreenChat,
                                  maintainState: true,
                                  child: ColoredBox(
                                    color: theme
                                        .resources
                                        .solidBackgroundFillColorQuarternary,
                                    child: home
                                        ? _AndroidLibrary(
                                            wide: wide,
                                            onImportFolder: onImportFolder,
                                            onImportHelp: onImportHelp,
                                          )
                                        : content,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (ai)
                          Positioned(
                            top: 0,
                            bottom: 0,
                            right: 0,
                            width: wide ? _chatWidth : constraints.maxWidth,
                            child: AiPanel(
                              onOpenHistory: onOpenChatHistory,
                              embedded: true,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!wide && (home || ai))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: chrome,
                        border: Border(top: border),
                      ),
                      child: Row(
                        children: [
                          _BottomDestination(
                            FluentIcons.library,
                            '文档库',
                            openHome,
                            selected: !ai,
                          ),
                          _BottomDestination(
                            FluentIcons.search,
                            '搜索',
                            () => openPlatformSearch(ref),
                          ),
                          _BottomDestination(
                            FluentIcons.chat,
                            '问答',
                            () => chat.setVisible(true),
                            selected: ai,
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _showOutline(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        final theme = FluentTheme.of(context);
        return Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            widthFactor: 1,
            heightFactor: .67,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              child: ColoredBox(
                color: theme.menuColor,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 18,
                        right: 8,
                        top: 4,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '章节目录',
                              style: theme.typography.subtitle,
                            ),
                          ),
                          _TouchAction(
                            FluentIcons.chrome_close,
                            '关闭目录',
                            () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: DocumentOutline(
                        compact: false,
                        touch: true,
                        onOpenPage: () => Navigator.pop(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TouchAction extends StatelessWidget {
  const _TouchAction(
    this.icon,
    this.label,
    this.onPressed, {
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return Tooltip(
      message: label,
      child: IconButton(
        icon: Icon(icon, size: 18, color: selected ? accent : null),
        onPressed: onPressed,
        style: const ButtonStyle(
          padding: WidgetStatePropertyAll(EdgeInsets.all(15)),
        ),
      ),
    );
  }
}

class _TouchMenu extends StatelessWidget {
  const _TouchMenu({required this.label, required this.items});

  final String label;
  final List<MenuFlyoutItemBase> items;

  @override
  Widget build(BuildContext context) {
    return DropDownButton(
      placement: FlyoutPlacementMode.bottomRight,
      buttonBuilder: (context, onOpen) =>
          _TouchAction(FluentIcons.more, label, onOpen),
      items: items,
    );
  }
}

class _BottomDestination extends StatelessWidget {
  const _BottomDestination(
    this.icon,
    this.label,
    this.onPressed, {
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return Expanded(
      child: Semantics(
        selected: selected,
        child: Button(
          onPressed: onPressed,
          style: ButtonStyle(
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 7),
            ),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.hovered)) {
                return theme.resources.subtleFillColorSecondary;
              }
              return selected
                  ? accent.withValues(alpha: .12)
                  : Colors.transparent;
            }),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: selected ? accent : null),
              const SizedBox(height: 4),
              Text(
                label,
                style: theme.typography.caption?.copyWith(
                  color: selected ? accent : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AndroidLibrary extends ConsumerWidget {
  const _AndroidLibrary({
    required this.wide,
    required this.onImportFolder,
    required this.onImportHelp,
  });

  final bool wide;
  final VoidCallback onImportFolder;
  final VoidCallback onImportHelp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryProvider);
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final transfer = ref.read(libraryTransferProvider);
    final inset = wide ? 28.0 : 16.0;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: ListView(
          padding: EdgeInsets.fromLTRB(inset, wide ? 24 : 16, inset, 24),
          children: [
            Text('文档库', style: theme.typography.title),
            const SizedBox(height: 4),
            Text(
              state.loading && !state.loadedOnce
                  ? '正在读取文档库…'
                  : state.libraries.isEmpty
                  ? '导入其他设备导出的资料包，或选择本地 Markdown 文件夹。'
                  : '${state.libraries.length} 个本地文档库',
              style: theme.typography.body?.copyWith(
                color: theme.resources.textFillColorSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  style: _touchButtonStyle,
                  onPressed: transfer.importPackage,
                  child: const Text('导入资料包'),
                ),
                Button(
                  style: _touchButtonStyle,
                  onPressed: onImportFolder,
                  child: const Text('导入文件夹'),
                ),
                HyperlinkButton(
                  onPressed: onImportHelp,
                  child: const Text('从网站制作文档库'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (state.loading && !state.loadedOnce)
              const Center(child: ProgressRing())
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final cardWidth = width >= 600 ? (width - 10) / 2 : width;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final lib in state.libraries)
                        SizedBox(
                          width: cardWidth,
                          child: Card(
                            padding: EdgeInsets.zero,
                            child: ListTile(
                              margin: EdgeInsets.zero,
                              leading: Icon(
                                FluentIcons.reading_mode,
                                size: 20,
                                color: accent,
                              ),
                              title: Text(
                                lib.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${lib.defaultVersion.label} · ${lib.pageCount} 页',
                              ),
                              onPressed: () => ref
                                  .read(navigationProvider.notifier)
                                  .openLibrary(lib),
                              trailing: _TouchMenu(
                                label: '文档库操作',
                                items: [
                                  MenuFlyoutItem(
                                    text: const Text('导出资料包'),
                                    onPressed: () =>
                                        transfer.exportPackage(lib),
                                  ),
                                  MenuFlyoutItem(
                                    text: const Text('分享资料包'),
                                    onPressed: () =>
                                        transfer.sharePackage(lib, null),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
