import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../features/ai/ai_controller.dart';
import '../features/ai/ui/ai_panel.dart';
import '../features/library/library_controller.dart';
import '../features/library/models.dart';
import '../features/palette/command_registry.dart';
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

class DocumentOutline extends ConsumerWidget {
  const DocumentOutline({
    super.key,
    required this.compact,
    this.touch = false,
    this.onOpenPage,
  });

  final bool compact;
  final bool touch;
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
          _row(
            icon: touch ? FluentIcons.library : m.Icons.book_outlined,
            label: item.name,
            selected: nav.view == AppView.reader && lib?.key == item.key,
            onTap: () => navigation.openLibrary(item),
          ),
      ],
      if (nav.view == AppView.reader && lib != null && version != null) ...[
        if (compact) caption('章节目录') else caption(lib.name),
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
            _row(
              icon: touch ? FluentIcons.document : m.Icons.description_outlined,
              label: node.title,
              indent: depth.clamp(0, 5) * 9.0,
              selected: node.page == location?.page,
              onTap: () {
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

  Widget _row({
    required IconData icon,
    required String label,
    double indent = 0,
    required bool selected,
    required VoidCallback onTap,
  }) {
    if (!touch) {
      return _MacRow(
        icon: icon,
        label: label,
        indent: indent,
        selected: selected,
        onTap: onTap,
      );
    }
    return ListTile.selectable(
      selected: selected,
      contentPadding: EdgeInsets.fromLTRB(10 + indent, 12, 8, 12),
      leading: Icon(icon, size: 16),
      title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      onPressed: onTap,
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
