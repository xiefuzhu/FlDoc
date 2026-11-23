import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../library/library_controller.dart';
import '../library/models.dart';
import '../reader/navigation/navigation_controller.dart';
import '../settings/settings_controller.dart';

/// Fluent / WPF UI Gallery inspired left navigation sidebar (FR-SB-01..08).
class AppSidebar extends ConsumerStatefulWidget {
  const AppSidebar({super.key});

  @override
  ConsumerState<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends ConsumerState<AppSidebar> {
  final Set<String> _expanded = {};
  late double _width;
  String? _lastAutoExpandedPage;

  @override
  void initState() {
    super.initState();
    _width = ref.read(uiStateProvider).sidebarWidth.clamp(200.0, 460.0);
  }

  Library? _activeLibrary(List<Library> libs, NavState nav) {
    if (libs.isEmpty) return null;
    if (nav.location != null) {
      final hit = libs.where((l) => l.key == nav.location!.libKey).firstOrNull;
      if (hit != null) return hit;
    }
    final lastKey = ref.read(uiStateProvider).lastLibraryId;
    if (lastKey != null) {
      final hit = libs.where((l) => l.key == lastKey).firstOrNull;
      if (hit != null) return hit;
    }
    return libs.first;
  }

  void _autoExpandToPage(List<TocNode> toc, String page, String prefix) {
    bool walk(List<TocNode> nodes, String pfx) {
      for (var i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        final key = '$pfx/$i:${n.title}';
        if (n.page == page) return true;
        if (n.children.isNotEmpty && walk(n.children, key)) {
          _expanded.add(key);
          return true;
        }
      }
      return false;
    }

    walk(toc, prefix);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final libState = ref.watch(libraryProvider);
    final nav = ref.watch(navigationProvider);
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final borderColor = dark ? const Color(0x22FFFFFF) : const Color(0x18000000);
    final bgColor = dark ? const Color(0xFF1A1A1A) : const Color(0xFFF5F5F5);

    if (!settings.sidebarVisible) {
      if (settings.sidebarCollapsedMode == 'iconBar') {
        return _buildIconRail(theme, borderColor, bgColor, nav, libState.libraries);
      }
      return const SizedBox.shrink();
    }

    final activeLib = _activeLibrary(libState.libraries, nav);
    final activeVer = activeLib == null
        ? null
        : (nav.location != null && nav.location!.libKey == activeLib.key
            ? (activeLib.version(nav.location!.versionId) ?? activeLib.defaultVersion)
            : activeLib.defaultVersion);

    final activePage = nav.view == AppView.reader ? nav.location?.page : null;
    if (activeLib != null && activeVer != null && activePage != null) {
      final expandKey = '${activeLib.key}|${activeVer.id}|$activePage';
      if (_lastAutoExpandedPage != expandKey) {
        _lastAutoExpandedPage = expandKey;
        _autoExpandToPage(activeVer.toc, activePage, '${activeLib.key}|${activeVer.id}');
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: _width,
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(right: BorderSide(color: borderColor)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top bar: hamburger + library selector + version selector (FR-SB-01)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                child: Row(
                  children: [
                    Tooltip(
                      message: '收起侧边栏 (Ctrl+B)',
                      child: IconButton(
                        icon: const Icon(FluentIcons.global_nav_button, size: 15),
                        onPressed: () => ref.read(settingsProvider.notifier).toggle('sidebar.visible'),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: libState.libraries.isEmpty
                          ? Text('无文档库', style: TextStyle(fontSize: 13, color: theme.resources.textFillColorSecondary))
                          : ComboBox<String>(
                              isExpanded: true,
                              value: activeLib?.key,
                              items: [
                                for (final l in libState.libraries)
                                  ComboBoxItem<String>(
                                    value: l.key,
                                    child: Text(l.name, overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (key) {
                                if (key == null) return;
                                final lib = libState.byKey(key);
                                if (lib != null) ref.read(navigationProvider.notifier).openLibrary(lib);
                              },
                            ),
                    ),
                    if (activeLib != null && activeLib.versions.length > 1 && activeVer != null) ...[
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 82,
                        child: ComboBox<String>(
                          isExpanded: true,
                          value: activeVer.id,
                          items: [
                            for (final v in activeLib.versions)
                              ComboBoxItem<String>(
                                value: v.id,
                                child: Text(v.label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                              ),
                          ],
                          onChanged: (vid) {
                            if (vid == null) return;
                            if (nav.location != null && nav.location!.libKey == activeLib.key) {
                              ref.read(navigationProvider.notifier).switchVersion(vid);
                            } else {
                              ref.read(navigationProvider.notifier).openLibrary(activeLib, versionId: vid);
                            }
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Fixed Home item (FR-SB-02)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _NavRow(
                  icon: FluentIcons.home,
                  label: 'Home',
                  selected: nav.view == AppView.home,
                  onTap: () => ref.read(navigationProvider.notifier).goHome(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Container(height: 1, color: borderColor),
              ),
              // TOC tree (FR-SB-03)
              Expanded(
                child: activeLib == null || activeVer == null
                    ? Center(
                        child: Text(
                          '暂无目录',
                          style: TextStyle(fontSize: 12, color: theme.resources.textFillColorSecondary),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
                        children: _buildTocNodes(
                          activeVer.toc,
                          activeLib,
                          activeVer,
                          activePage,
                          '${activeLib.key}|${activeVer.id}',
                          0,
                        ),
                      ),
              ),
              Container(height: 1, color: borderColor),
              // Fixed bottom Settings item (FR-SB-04)
              Padding(
                padding: const EdgeInsets.all(6),
                child: _NavRow(
                  icon: FluentIcons.settings,
                  label: '设置',
                  selected: nav.view == AppView.settings,
                  onTap: () => ref.read(navigationProvider.notifier).openSettings(),
                ),
              ),
            ],
          ),
        ),
        // Draggable splitter (FR-SB-07)
        MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: (d) {
              setState(() => _width = (_width + d.delta.dx).clamp(200.0, 460.0));
            },
            onHorizontalDragEnd: (_) => ref.read(uiStateProvider).sidebarWidth = _width,
            child: const SizedBox(width: 4),
          ),
        ),
      ],
    );
  }

  Widget _buildIconRail(
    FluentThemeData theme,
    Color borderColor,
    Color bgColor,
    NavState nav,
    List<Library> libs,
  ) {
    final activeLib = _activeLibrary(libs, nav);
    return Container(
      width: 48,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Tooltip(
            message: '展开侧边栏 (Ctrl+B)',
            child: IconButton(
              icon: const Icon(FluentIcons.global_nav_button, size: 16),
              onPressed: () => ref.read(settingsProvider.notifier).set('sidebar.visible', true),
            ),
          ),
          const SizedBox(height: 6),
          _RailIcon(
            icon: FluentIcons.home,
            tooltip: 'Home',
            selected: nav.view == AppView.home,
            onTap: () => ref.read(navigationProvider.notifier).goHome(),
          ),
          if (activeLib != null)
            _RailIcon(
              icon: FluentIcons.library,
              tooltip: '${activeLib.name}（点击展开目录）',
              selected: nav.view == AppView.reader,
              onTap: () => ref.read(settingsProvider.notifier).set('sidebar.visible', true),
            ),
          const Spacer(),
          _RailIcon(
            icon: FluentIcons.settings,
            tooltip: '设置',
            selected: nav.view == AppView.settings,
            onTap: () => ref.read(navigationProvider.notifier).openSettings(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  List<Widget> _buildTocNodes(
    List<TocNode> nodes,
    Library lib,
    LibraryVersion ver,
    String? activePage,
    String prefix,
    int depth,
  ) {
    final out = <Widget>[];
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final key = '$prefix/$i:${n.title}';
      final hasKids = n.children.isNotEmpty;
      final isExpanded = _expanded.contains(key);
      final isSelected = n.page != null && n.page == activePage;

      out.add(_TocRow(
        title: n.title,
        depth: depth,
        hasChildren: hasKids,
        expanded: isExpanded,
        selected: isSelected,
        onToggle: hasKids
            ? () => setState(() {
                  if (!_expanded.remove(key)) _expanded.add(key);
                })
            : null,
        onTap: () {
          if (n.page != null) {
            ref.read(navigationProvider.notifier).open(
                  DocLocation(libKey: lib.key, versionId: ver.id, page: n.page!),
                );
            if (hasKids && !isExpanded) {
              setState(() => _expanded.add(key));
            }
          } else if (hasKids) {
            setState(() {
              if (!_expanded.remove(key)) _expanded.add(key);
            });
          }
        },
      ));
      if (hasKids && isExpanded) {
        out.addAll(_buildTocNodes(n.children, lib, ver, activePage, key, depth + 1));
      }
    }
    return out;
  }
}

class _NavRow extends StatefulWidget {
  const _NavRow({required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final hoverBg = theme.brightness == Brightness.dark ? const Color(0x14FFFFFF) : const Color(0x0D000000);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected || _hovered ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  color: widget.selected ? accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Icon(widget.icon, size: 15, color: widget.selected ? accent : null),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: widget.selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TocRow extends StatefulWidget {
  const _TocRow({
    required this.title,
    required this.depth,
    required this.hasChildren,
    required this.expanded,
    required this.selected,
    this.onToggle,
    required this.onTap,
  });

  final String title;
  final int depth;
  final bool hasChildren;
  final bool expanded;
  final bool selected;
  final VoidCallback? onToggle;
  final VoidCallback onTap;

  @override
  State<_TocRow> createState() => _TocRowState();
}

class _TocRowState extends State<_TocRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final hoverBg = theme.brightness == Brightness.dark ? const Color(0x14FFFFFF) : const Color(0x0D000000);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 32,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: EdgeInsets.only(left: 6.0 + widget.depth * 14.0, right: 8),
          decoration: BoxDecoration(
            color: widget.selected || _hovered ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: widget.selected ? accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 4),
              if (widget.hasChildren)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onToggle,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      widget.expanded ? FluentIcons.chevron_down : FluentIcons.chevron_right,
                      size: 10,
                      color: theme.resources.textFillColorSecondary,
                    ),
                  ),
                )
              else
                const SizedBox(width: 18),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : (widget.hasChildren && widget.depth == 0 ? FontWeight.w600 : FontWeight.normal),
                    color: widget.selected ? accent : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailIcon extends StatelessWidget {
  const _RailIcon({required this.icon, required this.tooltip, required this.selected, required this.onTap});

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          icon: Icon(icon, size: 17, color: selected ? accent : null),
          onPressed: onTap,
        ),
      ),
    );
  }
}
