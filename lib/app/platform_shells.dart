import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../features/ai/ai_controller.dart';
import '../features/ai/ui/ai_panel.dart';
import '../features/library/library_controller.dart';
import '../features/library/library_transfer.dart';
import '../features/library/models.dart';
import '../features/palette/command_registry.dart';
import '../features/reader/find/find_controller.dart';
import '../features/reader/navigation/navigation_controller.dart';
import '../features/search/models.dart';
import '../features/settings/settings_controller.dart';

const macAccent = Color(0xFF3C5DAD);
const androidAccent = Color(0xFF07685A);

void openPlatformSearch(WidgetRef ref) {
  final nav = ref.read(navigationProvider);
  final scope =
      nav.view == AppView.reader &&
          ref.read(settingsProvider).defaultScope == 'currentLibrary'
      ? SearchScope.currentLibrary
      : SearchScope.allLibraries;
  ref
      .read(paletteProvider.notifier)
      .openSubmode(
        DynamicSubmode(
          title: '全文搜索',
          placeholder: '搜索文档正文、标题或代码',
          kind: DynamicModeKind.globalSearch,
          initialScope: scope,
        ),
      );
}

class MacShell extends ConsumerWidget {
  const MacShell({
    super.key,
    required this.content,
    required this.onOpenChatHistory,
  });

  final Widget content;
  final VoidCallback onOpenChatHistory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final sidebar = ref.watch(settingsProvider.select((s) => s.sidebarVisible));
    final aiVisible = ref.watch(aiControllerProvider.select((s) => s.visible));
    final nav = ref.watch(navigationProvider);
    final navigation = ref.read(navigationProvider.notifier);
    final border = dark ? const Color(0xFF3B414C) : const Color(0xFFDDE3EC);
    final chrome = dark ? const Color(0xFF22252C) : const Color(0xFFF4F6FA);
    final paper = dark ? const Color(0xFF191B20) : const Color(0xFFFFFFFF);

    return Column(
      children: [
        Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: chrome,
            border: Border(bottom: BorderSide(color: border)),
          ),
          child: Row(
            children: [
              _MacAction(m.Icons.view_sidebar_outlined, '显示或隐藏侧栏', () {
                ref.read(settingsProvider.notifier).toggle('sidebar.visible');
              }),
              const SizedBox(width: 8),
              _MacAction(
                m.Icons.chevron_left,
                '后退',
                nav.canBack ? navigation.back : null,
              ),
              _MacAction(
                m.Icons.chevron_right,
                '前进',
                nav.canForward ? navigation.forward : null,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  switch (nav.view) {
                    AppView.reader => nav.page?.lib.name ?? '阅读',
                    AppView.settings => '设置',
                    AppView.home => 'flDoc',
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Button(
                style: ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(
                    dark ? const Color(0xFF2E333D) : Colors.white,
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                onPressed: () => openPlatformSearch(ref),
                child: Row(
                  children: [
                    const Icon(m.Icons.search, size: 16),
                    const SizedBox(width: 7),
                    const Text('搜索文档'),
                    const SizedBox(width: 34),
                    Text(
                      '⌘K',
                      style: TextStyle(
                        color: theme.resources.textFillColorSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _MacAction(m.Icons.bolt_outlined, '命令面板 · ⌘⇧P', () {
                ref.read(paletteProvider.notifier).openRoot();
              }),
              _MacAction(m.Icons.chat_bubble_outline, '问答', () {
                ref.read(aiControllerProvider.notifier).togglePanel();
              }, color: aiVisible ? accent : null),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (sidebar && (!aiVisible || constraints.maxWidth >= 1050))
                    Container(
                      width: 224,
                      decoration: BoxDecoration(
                        color: dark
                            ? const Color(0xFF222630)
                            : const Color(0xFFEFF3F9),
                        border: Border(right: BorderSide(color: border)),
                      ),
                      padding: const EdgeInsets.fromLTRB(11, 14, 11, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _MacRow(
                            icon: m.Icons.inventory_2_outlined,
                            label: '文档库',
                            selected: nav.view == AppView.home,
                            onTap: () => navigation.goHome(),
                          ),
                          const SizedBox(height: 12),
                          Expanded(child: DocumentOutline(compact: true)),
                          _MacRow(
                            icon: m.Icons.settings_outlined,
                            label: '设置',
                            selected: nav.view == AppView.settings,
                            onTap: navigation.openSettings,
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ColoredBox(color: paper, child: content),
                  ),
                  if (aiVisible)
                    SizedBox(
                      width: 334,
                      child: AiPanel(
                        onOpenHistory: onOpenChatHistory,
                        embedded: true,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MacAction extends StatelessWidget {
  const _MacAction(this.icon, this.label, this.onTap, {this.color});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: IconButton(
      icon: Icon(icon, size: 19, color: color),
      onPressed: onTap,
    ),
  );
}

class _MacRow extends StatelessWidget {
  const _MacRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.indent = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return Button(
      style: ButtonStyle(
        padding: WidgetStatePropertyAll(
          EdgeInsets.fromLTRB(9 + indent, 8, 7, 8),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (selected) return accent.withValues(alpha: .14);
          if (states.contains(WidgetState.hovered)) {
            return accent.withValues(alpha: .07);
          }
          return Colors.transparent;
        }),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      onPressed: onTap,
      child: Row(
        children: [
          Icon(icon, size: 16, color: selected ? accent : null),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class AndroidShell extends ConsumerWidget {
  const AndroidShell({
    super.key,
    required this.content,
    required this.onOpenChatHistory,
    required this.onImportFolder,
    required this.onImportHelp,
  });

  final Widget content;
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
    final navigation = ref.read(navigationProvider.notifier);
    final chat = ref.read(aiControllerProvider.notifier);
    final reading = !ai && nav.view == AppView.reader;
    final home = !ai && nav.view == AppView.home;
    final colors = m.ColorScheme.fromSeed(
      seedColor: theme.accentColor.defaultBrushFor(theme.brightness),
      brightness: theme.brightness,
    );
    ref.listen(navigationProvider.select((s) => (s.view, s.location)), (
      _,
      next,
    ) {
      if (next.$1 != AppView.home && ref.read(aiControllerProvider).visible) {
        chat.setVisible(false);
      }
    });

    return m.Theme(
      data: m.ThemeData(colorScheme: colors, useMaterial3: true),
      child: Builder(
        builder: (context) => PopScope(
          canPop: !palette && !ai && nav.view == AppView.home,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (palette) {
              ref.read(paletteProvider.notifier).close();
            } else if (ai) {
              chat.setVisible(false);
            } else if (findOpen) {
              ref.read(findProvider.notifier).close();
            } else if (nav.canBack) {
              navigation.back();
            } else {
              navigation.goHome(push: false);
            }
          },
          child: m.Scaffold(
            backgroundColor: colors.surface,
            appBar: m.AppBar(
              backgroundColor: colors.surface,
              automaticallyImplyLeading: false,
              leading: !ai && !home
                  ? m.IconButton(
                      tooltip: '返回',
                      icon: const Icon(m.Icons.arrow_back),
                      onPressed: () => nav.canBack
                          ? navigation.back()
                          : navigation.goHome(push: false),
                    )
                  : null,
              title: Text(
                switch ((ai, nav.view)) {
                  (true, _) => '文档问答',
                  (_, AppView.home) => 'flDoc',
                  (_, AppView.settings) => '设置',
                  (_, AppView.reader) => nav.page?.lib.name ?? '阅读',
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                if (reading)
                  m.IconButton(
                    tooltip: '章节目录',
                    onPressed: () => m.showModalBottomSheet<void>(
                      context: context,
                      useSafeArea: true,
                      showDragHandle: true,
                      isScrollControlled: true,
                      builder: (sheet) => FractionallySizedBox(
                        heightFactor: .67,
                        child: SafeArea(
                          top: false,
                          child: DocumentOutline(
                            compact: false,
                            onOpenPage: () => Navigator.pop(sheet),
                          ),
                        ),
                      ),
                    ),
                    icon: const Icon(m.Icons.format_list_bulleted),
                  ),
                m.PopupMenuButton<String>(
                  tooltip: '更多操作',
                  onSelected: (action) {
                    switch (action) {
                      case 'find':
                        ref.read(findProvider.notifier).open();
                      case 'settings':
                        chat.setVisible(false);
                        navigation.openSettings();
                      case 'search':
                        openPlatformSearch(ref);
                      case 'chat':
                        chat.setVisible(true);
                      case 'commands':
                        ref.read(paletteProvider.notifier).openRoot();
                    }
                  },
                  itemBuilder: (_) => [
                    if (reading) ...const [
                      m.PopupMenuItem(value: 'find', child: Text('页内查找')),
                      m.PopupMenuItem(value: 'search', child: Text('全文搜索')),
                      m.PopupMenuItem(value: 'chat', child: Text('文档问答')),
                    ],
                    const m.PopupMenuItem(
                      value: 'commands',
                      child: Text('命令面板'),
                    ),
                    if (nav.view != AppView.settings || ai)
                      const m.PopupMenuItem(
                        value: 'settings',
                        child: Text('设置'),
                      ),
                  ],
                ),
              ],
            ),
            body: SafeArea(
              top: false,
              bottom: reading || (!ai && nav.view == AppView.settings),
              child: ai
                  ? AiPanel(onOpenHistory: onOpenChatHistory, embedded: true)
                  : home
                  ? _AndroidLibrary(
                      onImportFolder: onImportFolder,
                      onImportHelp: onImportHelp,
                    )
                  : content,
            ),
            bottomNavigationBar: home || ai
                ? m.NavigationBar(
                    selectedIndex: ai ? 2 : 0,
                    onDestinationSelected: (index) {
                      switch (index) {
                        case 0:
                          chat.setVisible(false);
                          navigation.goHome();
                        case 1:
                          openPlatformSearch(ref);
                        case 2:
                          chat.setVisible(true);
                      }
                    },
                    destinations: const [
                      m.NavigationDestination(
                        icon: Icon(m.Icons.library_books_outlined),
                        label: '文档库',
                      ),
                      m.NavigationDestination(
                        icon: Icon(m.Icons.search),
                        label: '搜索',
                      ),
                      m.NavigationDestination(
                        icon: Icon(m.Icons.chat_bubble_outline),
                        label: '问答',
                      ),
                    ],
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _AndroidLibrary extends ConsumerWidget {
  const _AndroidLibrary({
    required this.onImportFolder,
    required this.onImportHelp,
  });

  final VoidCallback onImportFolder;
  final VoidCallback onImportHelp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryProvider);
    final theme = m.Theme.of(context);
    final transfer = ref.read(libraryTransferProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 13, 20, 24),
      children: [
        Text(
          '文档库',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          state.libraries.isEmpty
              ? '导入其他设备导出的资料包，或选择本地 Markdown 文件夹。'
              : '${state.libraries.length} 个本地文档库',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            m.FilledButton.icon(
              onPressed: transfer.importPackage,
              icon: const Icon(m.Icons.file_download_outlined),
              label: const Text('导入资料包'),
            ),
            m.OutlinedButton.icon(
              onPressed: onImportFolder,
              icon: const Icon(m.Icons.folder_open),
              label: const Text('导入文件夹'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (state.loading && !state.loadedOnce)
          const Center(child: m.CircularProgressIndicator())
        else
          for (final lib in state.libraries)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: m.Card.filled(
                margin: EdgeInsets.zero,
                child: m.ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 7,
                  ),
                  leading: Icon(
                    m.Icons.menu_book_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(lib.name),
                  subtitle: Text(
                    '${lib.defaultVersion.label} · ${lib.pageCount} 页',
                  ),
                  trailing: m.PopupMenuButton<bool>(
                    tooltip: '文档库操作',
                    onSelected: (share) {
                      if (share) {
                        transfer.sharePackage(lib, null);
                      } else {
                        transfer.exportPackage(lib);
                      }
                    },
                    itemBuilder: (_) => const [
                      m.PopupMenuItem(value: false, child: Text('导出资料包')),
                      m.PopupMenuItem(value: true, child: Text('分享资料包')),
                    ],
                  ),
                  onTap: () =>
                      ref.read(navigationProvider.notifier).openLibrary(lib),
                ),
              ),
            ),
        Align(
          alignment: Alignment.centerLeft,
          child: m.TextButton(
            onPressed: onImportHelp,
            child: const Text('从网站制作文档库'),
          ),
        ),
      ],
    );
  }
}

class DocumentOutline extends ConsumerWidget {
  const DocumentOutline({super.key, required this.compact, this.onOpenPage});

  final bool compact;
  final VoidCallback? onOpenPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraries = ref.watch(libraryProvider).libraries;
    final nav = ref.watch(navigationProvider);
    final location = nav.location;
    final lib = libraries
        .where((lib) => lib.key == location?.libKey)
        .firstOrNull;
    final version =
        lib?.version(location?.versionId ?? '') ?? lib?.defaultVersion;
    final navigation = ref.read(navigationProvider.notifier);
    final theme = FluentTheme.of(context);

    Widget caption(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(9, 9, 6, 5),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.resources.textFillColorSecondary,
        ),
      ),
    );

    final rows = <Widget>[
      if (compact) ...[
        caption('本地文档库'),
        for (final item in libraries)
          _MacRow(
            icon: m.Icons.book_outlined,
            label: item.name,
            selected: nav.view == AppView.reader && lib?.key == item.key,
            onTap: () => navigation.openLibrary(item),
          ),
      ],
      if (nav.view == AppView.reader && lib != null && version != null) ...[
        if (compact)
          caption('章节目录')
        else
          m.ListTile(title: Text(lib.name), subtitle: const Text('章节目录')),
        if (lib.versions.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: ComboBox<String>(
              value: version.id,
              isExpanded: true,
              items: [
                for (final v in lib.versions)
                  ComboBoxItem(value: v.id, child: Text(v.label)),
              ],
              onChanged: (value) {
                if (value != null) navigation.switchVersion(value);
              },
            ),
          ),
        for (final (node, depth) in _outlineEntries(version.toc))
          if (node.page == null)
            Padding(
              padding: EdgeInsets.only(left: depth * 9),
              child: caption(node.title),
            )
          else
            _pageRow(
              node.title,
              depth,
              selected: node.page == location?.page,
              open: () {
                onOpenPage?.call();
                navigation.open(
                  DocLocation(
                    libKey: lib.key,
                    versionId: version.id,
                    page: node.page!,
                  ),
                );
              },
            ),
      ],
    ];
    return ListView.builder(
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(14, 0, 14, 12),
      itemCount: rows.length,
      itemBuilder: (_, i) => rows[i],
    );
  }

  Widget _pageRow(
    String title,
    int depth, {
    required bool selected,
    required VoidCallback open,
  }) {
    final indent = depth.clamp(0, 5) * 9.0;
    if (compact) {
      return _MacRow(
        icon: m.Icons.description_outlined,
        label: title,
        indent: indent,
        selected: selected,
        onTap: open,
      );
    }
    return m.ListTile(
      selected: selected,
      contentPadding: EdgeInsets.only(left: 12 + indent, right: 12),
      leading: const Icon(m.Icons.description_outlined),
      title: Text(title),
      onTap: open,
    );
  }
}

Iterable<(TocNode, int)> _outlineEntries(
  List<TocNode> nodes, [
  int depth = 0,
]) sync* {
  for (final node in nodes) {
    yield (node, depth);
    yield* _outlineEntries(node.children, depth + 1);
  }
}
