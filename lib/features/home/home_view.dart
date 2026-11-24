import 'dart:collection';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../ai/index/embed_indexer.dart';
import '../library/library_controller.dart';
import '../library/library_transfer.dart';
import '../library/manifest_generator.dart';
import '../library/models.dart';
import '../library/validator/library_validator.dart';
import '../reader/navigation/navigation_controller.dart';
import '../settings/settings_controller.dart';

/// Home view: responsive library card overview (FR-HOME-01..06).
class HomeView extends ConsumerWidget {
  const HomeView({
    super.key,
    required this.onImportLibrary,
    required this.onValidateLibrary,
    this.mac = false,
  });

  final VoidCallback onImportLibrary;
  final void Function(Library lib) onValidateLibrary;
  final bool mac;

  Future<void> _addRoot(WidgetRef ref) async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择文档库根目录');
    if (dir == null || dir.trim().isEmpty) return;
    final norm = dir.replaceAll('\\', '/');
    final roots = List<String>.of(ref.read(settingsProvider).libraryRoots);
    if (!roots.contains(norm)) {
      roots.add(norm);
      ref.read(settingsProvider.notifier).set('libraryRoots', roots);
      ref.read(noticeProvider.notifier).show('已添加文档库根目录：$norm');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libState = ref.watch(libraryProvider);
    final indexMap = ref.watch(embedIndexerProvider);
    final valMap = ref.watch(validationResultsProvider);
    final theme = FluentTheme.of(context);
    final transfer = ref.read(libraryTransferProvider);

    if (libState.loading && !libState.loadedOnce) {
      return const Center(child: ProgressRing());
    }

    if (libState.libraries.isEmpty) {
      return _EmptyHome(
        onAddRoot: () => _addRoot(ref),
        onImportPackage: transfer.importPackage,
        onImport: onImportLibrary,
      );
    }

    if (mac) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 36),
        children: [
          Text('文档库', style: theme.typography.titleLarge),
          const SizedBox(height: 6),
          Text('${libState.libraries.length} 个本地文档库', style: theme.typography.caption),
          const SizedBox(height: 16),
          Wrap(spacing: 10, runSpacing: 8, children: [
            FilledButton(onPressed: transfer.importPackage, child: const Text('导入资料包')),
            Button(onPressed: () => _addRoot(ref), child: const Text('添加根目录')),
            Button(onPressed: onImportLibrary, child: const Text('从网站制作文档库')),
          ]),
          const SizedBox(height: 24),
          for (final lib in libState.libraries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Button(
                onPressed: () => ref.read(navigationProvider.notifier).openLibrary(lib),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      _LibIcon(lib: lib, accent: theme.accentColor.defaultBrushFor(theme.brightness)),
                      const SizedBox(width: 13),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(lib.name, style: theme.typography.bodyStrong),
                          Text('${lib.defaultVersion.label} · ${lib.pageCount} 页', style: theme.typography.caption),
                        ],
                      )),
                      DropDownButton(
                        title: const Text('操作'),
                        items: [
                          MenuFlyoutItem(text: const Text('导出资料包'), onPressed: () => transfer.exportPackage(lib)),
                          MenuFlyoutItem(text: const Text('分享资料包'), onPressed: () => transfer.sharePackage(lib, libraryShareOrigin(context))),
                          MenuFlyoutItem(text: const Text('校验文档库'), onPressed: () => onValidateLibrary(lib)),
                          if (lib.format == LibraryFormat.plain)
                            MenuFlyoutItem(text: const Text('生成 manifest'), onPressed: () => _confirmGenerateManifest(context, ref, lib)),
                          MenuFlyoutItem(text: const Text('重建向量索引'), onPressed: () => _rebuildIndex(context, ref, lib)),
                          MenuFlyoutItem(text: const Text('在访达中显示'), onPressed: () => _revealInExplorer(lib.dir)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('文档库', style: theme.typography.title),
              const SizedBox(width: 10),
              Text(
                '${libState.libraries.length} 个',
                style: TextStyle(fontSize: 13, color: theme.resources.textFillColorSecondary),
              ),
              const Spacer(),
              Button(onPressed: transfer.importPackage, child: const Text('导入资料包')),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final lib in libState.libraries)
                _LibraryCard(
                  lib: lib,
                  indexStatus: indexMap[lib.key],
                  validation: valMap[lib.key],
                  onOpen: () => ref.read(navigationProvider.notifier).openLibrary(lib),
                  onExport: () => transfer.exportPackage(lib),
                  onShare: (origin) => transfer.sharePackage(lib, origin),
                  onValidate: () => onValidateLibrary(lib),
                  onGenerateManifest: lib.format == LibraryFormat.plain
                      ? () => _confirmGenerateManifest(context, ref, lib)
                      : null,
                  onRebuildIndex: () => _rebuildIndex(context, ref, lib),
                  onReveal: () => _revealInExplorer(lib.dir),
                ),
              _ImportLibraryCard(onTap: onImportLibrary),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmGenerateManifest(BuildContext context, WidgetRef ref, Library lib) async {
    final exists = ManifestGenerator.hasExistingManifest(lib.dir);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('生成 manifest.json'),
        content: Text(
          exists
              ? '目录「${lib.name}」下已存在 manifest.json，是否覆盖？不会改动任何 .md 文件。'
              : '将为纯 Markdown 库「${lib.name}」生成平铺版本 manifest.json（不改动任何 .md 文件）。是否继续？',
        ),
        actions: [
          Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('生成')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      ManifestGenerator.generate(lib);
      ref.read(noticeProvider.notifier).show('已为「${lib.name}」生成 manifest.json');
      await ref.read(libraryProvider.notifier).reload();
    } catch (e) {
      ref.read(noticeProvider.notifier).show('生成 manifest 失败：$e', isError: true);
    }
  }

  Future<void> _rebuildIndex(BuildContext context, WidgetRef ref, Library lib) async {
    final indexer = ref.read(embedIndexerProvider.notifier);
    if (!indexer.isConfigured) {
      ref.read(noticeProvider.notifier).show('尚未配置嵌入模型，请前往「设置 -> AI」配置', isError: true);
      return;
    }
    final count = await indexer.estimateChunkCount([lib]);
    if (count > 20000 && context.mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => ContentDialog(
          title: const Text('确认重建向量索引'),
          content: Text('预计需要嵌入 $count 个文本块（超过 2 万块），可能产生较多接口调用。是否继续？'),
          actions: [
            Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续')),
          ],
        ),
      );
      if (ok != true) return;
    }
    ref.read(noticeProvider.notifier).show('开始重建「${lib.name}」向量索引（共约 $count 块）');
    indexer.indexLibrary(lib, forceRebuild: true);
  }

  void _revealInExplorer(String dir) {
    if (Platform.isWindows) {
      Process.start('explorer.exe', [dir.replaceAll('/', '\\')], runInShell: false);
    } else if (Platform.isMacOS) {
      Process.start('/usr/bin/open', [dir]);
    }
  }
}

class _LibraryCard extends StatefulWidget {
  const _LibraryCard({
    required this.lib,
    required this.indexStatus,
    required this.validation,
    required this.onOpen,
    required this.onExport,
    required this.onShare,
    required this.onValidate,
    this.onGenerateManifest,
    required this.onRebuildIndex,
    required this.onReveal,
  });

  final Library lib;
  final LibraryIndexStatus? indexStatus;
  final ValidationSummary? validation;
  final VoidCallback onOpen;
  final VoidCallback onExport;
  final ValueChanged<Rect?> onShare;
  final VoidCallback onValidate;
  final VoidCallback? onGenerateManifest;
  final VoidCallback onRebuildIndex;
  final VoidCallback onReveal;

  @override
  State<_LibraryCard> createState() => _LibraryCardState();
}

class _LibraryCardState extends State<_LibraryCard> {
  final _flyout = FlyoutController();
  bool _hovered = false;

  @override
  void dispose() {
    _flyout.dispose();
    super.dispose();
  }

  void _showMenu([Offset? globalPos]) {
    _flyout.showFlyout(
      position: globalPos,
      builder: (ctx) => MenuFlyout(
        items: [
          MenuFlyoutItem(text: const Text('导出资料包'), onPressed: widget.onExport),
          MenuFlyoutItem(text: const Text('分享资料包'), onPressed: () => widget.onShare(libraryShareOrigin(context))),
          const MenuFlyoutSeparator(),
          MenuFlyoutItem(
            leading: const Icon(FluentIcons.check_list, size: 14),
            text: const Text('校验文档库'),
            onPressed: widget.onValidate,
          ),
          if (widget.onGenerateManifest != null)
            MenuFlyoutItem(
              leading: const Icon(FluentIcons.page_add, size: 14),
              text: const Text('为此文件夹生成 manifest'),
              onPressed: widget.onGenerateManifest,
            ),
          MenuFlyoutItem(
            leading: const Icon(FluentIcons.sync, size: 14),
            text: const Text('重建向量索引'),
            onPressed: widget.onRebuildIndex,
          ),
          const MenuFlyoutSeparator(),
          MenuFlyoutItem(
            leading: const Icon(FluentIcons.folder_open, size: 14),
            text: const Text('在资源管理器中打开'),
            onPressed: widget.onReveal,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final lib = widget.lib;
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final cardBg = dark ? const Color(0xFF2B2B2B) : const Color(0xFFFFFFFF);
    final border = _hovered
        ? accent.withValues(alpha: 0.7)
        : (dark ? const Color(0x28FFFFFF) : const Color(0x20000000));

    final (valLabel, valColor) = _validationBadge(dark);
    final indexLabel = '向量：${widget.indexStatus?.label ?? '未索引'}';

    return FlyoutTarget(
      controller: _flyout,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onOpen,
          onSecondaryTapUp: (d) => _showMenu(d.globalPosition),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 280,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border),
              boxShadow: _hovered
                  ? [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 4))]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _LibIcon(lib: lib, accent: accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            lib.name,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (lib.duplicateOfRoot != null)
                            Text(
                              '位于 ${p.basename(lib.duplicateOfRoot!)}',
                              style: TextStyle(fontSize: 11, color: Colors.orange),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    _Tag(
                      text: lib.format == LibraryFormat.contract ? '契约' : 'Markdown',
                      color: lib.format == LibraryFormat.contract ? accent : theme.resources.textFillColorSecondary,
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: '文档库操作',
                      child: IconButton(
                        icon: const Icon(FluentIcons.more, size: 14),
                        onPressed: _showMenu,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 36,
                  child: Text(
                    (lib.description != null && lib.description!.isNotEmpty) ? lib.description! : lib.dir,
                    style: TextStyle(fontSize: 12.5, color: theme.resources.textFillColorSecondary, height: 1.4),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _MetaItem('${lib.versions.length} 版本'),
                    _MetaItem('${lib.pageCount} 页'),
                    if (lib.latestCrawl != null && lib.latestCrawl!.length >= 10)
                      _MetaItem(lib.latestCrawl!.substring(0, 10)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: indexLabel,
                        child: Text(
                          indexLabel,
                          style: TextStyle(fontSize: 11.5, color: theme.resources.textFillColorSecondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _Tag(text: valLabel, color: valColor),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (String, Color) _validationBadge(bool dark) {
    if (widget.lib.loadWarning != null) {
      return ('加载警告', Colors.orange);
    }
    final v = widget.validation;
    if (v == null) return ('正常', dark ? const Color(0xFF6CCB5F) : const Color(0xFF107C10));
    if (v.errorCount > 0) return ('${v.errorCount} 错误', Colors.red);
    if (v.warningCount > 0) return ('${v.warningCount} 警告', Colors.orange);
    return ('校验通过', dark ? const Color(0xFF6CCB5F) : const Color(0xFF107C10));
  }
}

class _LibIcon extends StatelessWidget {
  const _LibIcon({required this.lib, required this.accent});

  final Library lib;
  final Color accent;

  static final LinkedHashMap<String, bool> _existsCache = LinkedHashMap();

  static bool _fileExistsCached(String path) {
    final hit = _existsCache.remove(path);
    if (hit != null) {
      _existsCache[path] = hit;
      return hit;
    }
    final exists = File(path).existsSync();
    _existsCache[path] = exists;
    if (_existsCache.length > 200) {
      _existsCache.remove(_existsCache.keys.first);
    }
    return exists;
  }

  @override
  Widget build(BuildContext context) {
    if (lib.iconPath != null && _fileExistsCached(lib.iconPath!)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(File(lib.iconPath!), width: 38, height: 38, fit: BoxFit.cover),
      );
    }
    final letter = lib.name.isEmpty ? '?' : lib.name.characters.first.toUpperCase();
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(letter, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: accent)),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: FluentTheme.of(context).resources.textFillColorSecondary),
    );
  }
}

class _ImportLibraryCard extends StatefulWidget {
  const _ImportLibraryCard({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ImportLibraryCard> createState() => _ImportLibraryCardState();
}

class _ImportLibraryCardState extends State<_ImportLibraryCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 280,
          height: 158,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _hovered ? accent.withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovered ? accent : theme.resources.surfaceStrokeColorDefault,
              width: 1.2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(FluentIcons.add, size: 26, color: accent),
              const SizedBox(height: 10),
              Text('从网站制作文档库', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: accent)),
              const SizedBox(height: 4),
              Text(
                '填写参数生成 Agent 爬取提示词',
                style: TextStyle(fontSize: 12, color: theme.resources.textFillColorSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onAddRoot, required this.onImportPackage, required this.onImport});

  final VoidCallback onAddRoot;
  final VoidCallback onImportPackage;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.library, size: 48, color: accent),
              const SizedBox(height: 16),
              Text('还没有文档库', style: theme.typography.subtitle),
              const SizedBox(height: 8),
              Text(
                '导入其他设备导出的资料包，或添加本地 Markdown 文档。',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.resources.textFillColorSecondary, height: 1.5),
              ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton(onPressed: onImportPackage, child: const Text('导入资料包')),
                  Button(onPressed: onAddRoot, child: const Text('添加库根目录')),
                  Button(onPressed: onImport, child: const Text('从网站制作文档库')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
