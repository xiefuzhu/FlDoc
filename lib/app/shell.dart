import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../features/ai/ai_controller.dart';
import '../features/ai/ui/ai_panel.dart';
import '../features/home/home_view.dart';
import '../features/library/android_library_import.dart';
import '../features/library/library_controller.dart';
import '../features/library/library_transfer.dart';
import '../features/library/models.dart';
import '../features/library/validator/library_validator.dart';
import '../features/palette/command_registry.dart';
import '../features/palette/palette_overlay.dart';
import '../features/reader/navigation/navigation_controller.dart';
import '../features/reader/ui/reader_view.dart';
import '../features/settings/oobe/oobe_dialog.dart';
import '../features/settings/settings_controller.dart';
import '../features/settings/ui/settings_page.dart';
import '../features/sidebar/sidebar.dart';
import 'platform_shells.dart';
import 'providers.dart';

/// Main application shell: frameless title bar + three-pane layout + overlays (doc 01 §1).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, this.platform = TargetPlatform.windows});

  final TargetPlatform platform;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  Timer? _noticeTimer;

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }

  void _openImportForm() {
    ref.read(paletteProvider.notifier).openSubmode(const FormSubmode(
          title: '从网站制作文档库',
          kind: FormModeKind.importLibrary,
        ));
  }

  void _openValidationFor(Library lib) {
    final libs = ref.read(libraryProvider).libraries;
    final res = ref.read(validationResultsProvider.notifier).runFor(lib, libs);
    ref.read(paletteProvider.notifier).openSubmode(DynamicSubmode(
          title: '校验结果 · ${lib.name}（${res.errorCount} 错误 / ${res.warningCount} 警告）',
          placeholder: '过滤问题编号或描述…',
          kind: DynamicModeKind.validationResults,
          validationSummaries: [res],
        ));
  }

  void _openChatHistory() {
    ref.read(paletteProvider.notifier).openSubmode(const DynamicSubmode(
          title: '历史对话',
          placeholder: '按标题或内容过滤历史对话…',
          kind: DynamicModeKind.chatHistory,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final nav = ref.watch(navigationProvider);
    final statusText = ref.watch(statusTextProvider);
    final notice = ref.watch(noticeProvider);
    final settingsErr = ref.watch(settingsErrorProvider);
    final pal = ref.watch(paletteProvider);
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final android = widget.platform == TargetPlatform.android;
    final mac = widget.platform == TargetPlatform.macOS;
    final viewPadding = MediaQuery.paddingOf(context);

    // Auto-clear toast notice after 3.5 seconds.
    ref.listen(noticeProvider, (_, next) {
      _noticeTimer?.cancel();
      if (next != null) {
        _noticeTimer = Timer(const Duration(milliseconds: 3500), () {
          if (mounted) ref.read(noticeProvider.notifier).clear();
        });
      }
    });

    final center = switch (nav.view) {
      AppView.home => HomeView(
          mac: mac,
          onImportLibrary: _openImportForm,
          onValidateLibrary: _openValidationFor,
        ),
      AppView.reader => ReaderView(compact: android),
      AppView.settings => SettingsPage(
          platform: widget.platform,
          onRerunOobe: () => ref.read(paletteProvider.notifier).openOobe(),
        ),
    };

    final Widget body;
    if (android) {
      body = AndroidShell(
        content: center,
        onOpenChatHistory: _openChatHistory,
        onImportFolder: () => importAndroidLibrary(ref, context),
        onImportHelp: _openImportForm,
      );
    } else if (mac) {
      body = MacShell(content: center, onOpenChatHistory: _openChatHistory);
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const RepaintBoundary(child: AppSidebar()),
          Expanded(
            child: RepaintBoundary(
              child: ColoredBox(
                color: dark ? const Color(0xFF202020) : const Color(0xFFFFFFFF),
                child: center,
              ),
            ),
          ),
          RepaintBoundary(child: AiPanel(onOpenHistory: _openChatHistory)),
        ],
      );
    }

    return Container(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        children: [
          Column(
            children: [
              if (!android && !mac) const RepaintBoundary(child: _TitleBar()),
              if (settingsErr != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                  child: InfoBar(
                    title: const Text('settings.json 加载失败（已保留旧设置）'),
                    content: Text(settingsErr),
                    severity: InfoBarSeverity.warning,
                    onClose: () => ref.read(settingsErrorProvider.notifier).set(null),
                  ),
                ),
              Expanded(child: ExcludeFocus(excluding: android && pal.open, child: body)),
            ],
          ),

          // Hover link status pill (FR-LK-04)
          if (!android && statusText != null && statusText.isNotEmpty)
            Positioned(
              left: 12,
              bottom: 10,
              child: IgnorePointer(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 520),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.menuColor.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(fontSize: 11.5, color: theme.resources.textFillColorSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),

          // Toast notification
          if (notice != null)
            Positioned(
              top: android ? viewPadding.top + 54 : mac ? 64 : 46,
              left: android ? 16 : null,
              right: 16,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: InfoBar(
                  title: Text(notice.title ?? (notice.isError ? '错误' : '提示')),
                  content: Text(notice.message),
                  severity: notice.isError ? InfoBarSeverity.error : InfoBarSeverity.info,
                  onClose: () => ref.read(noticeProvider.notifier).clear(),
                ),
              ),
            ),

          // Floating Command Palette overlay (Ctrl+Shift+P)
          if (android)
            Positioned.fill(
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
                  child: const CommandPaletteOverlay(mobile: true),
                ),
              ),
            )
          else
            const CommandPaletteOverlay(),

          // First-Run OOBE Wizard (doc 06 §9)
          if (pal.showOobe)
            OobeDialog(
              platform: widget.platform,
              onComplete: () => ref.read(paletteProvider.notifier).closeOobe(),
              onCompleteAndImport: () {
                ref.read(paletteProvider.notifier).closeOobe();
                ref.read(libraryTransferProvider).importPackage();
              },
            ),
        ],
      ),
    );
  }
}

/// Minimal frameless Win11 title bar (FR-WIN-01, FR-WIN-02).
class _TitleBar extends ConsumerWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final nav = ref.watch(navigationProvider);
    final aiVisible = ref.watch(aiControllerProvider.select((s) => s.visible));
    final ws = ref.watch(windowServiceProvider);
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final borderColor = dark ? const Color(0x22FFFFFF) : const Color(0x18000000);

    final titleText = switch (nav.view) {
      AppView.home => 'flDoc · 文档库',
      AppView.settings => 'flDoc · 设置',
      AppView.reader => nav.page != null ? '${nav.page!.title}  /  ${nav.page!.lib.name}' : 'flDoc',
    };

    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          // Always-on-top pin button (FR-WIN-02)
          Tooltip(
            message: settings.alwaysOnTop ? '取消置顶' : '窗口置顶',
            child: IconButton(
              icon: Icon(
                settings.alwaysOnTop ? FluentIcons.pinned_solid : FluentIcons.pinned,
                size: 13,
                color: settings.alwaysOnTop ? accent : theme.resources.textFillColorSecondary,
              ),
              onPressed: () => ref.read(settingsProvider.notifier).toggle('window.alwaysOnTop'),
            ),
          ),
          // Back / Forward buttons
          Tooltip(
            message: '后退 (Alt+←)',
            child: IconButton(
              icon: const Icon(FluentIcons.back, size: 11),
              onPressed: nav.canBack ? () => ref.read(navigationProvider.notifier).back() : null,
            ),
          ),
          Tooltip(
            message: '前进 (Alt+→)',
            child: IconButton(
              icon: const Icon(FluentIcons.forward, size: 11),
              onPressed: nav.canForward ? () => ref.read(navigationProvider.notifier).forward() : null,
            ),
          ),
          // Drag area + double-click maximize/restore
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: () => ws?.toggleMaximize(),
              child: DragToMoveArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      titleText,
                      style: TextStyle(fontSize: 12.5, color: theme.resources.textFillColorPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Subtle Command Palette trigger & AI Panel toggle
          Tooltip(
            message: '命令面板 (Ctrl+Shift+P)',
            child: IconButton(
              icon: Icon(FluentIcons.search, size: 12.5, color: theme.resources.textFillColorSecondary),
              onPressed: () => ref.read(paletteProvider.notifier).openRoot(),
            ),
          ),
          Tooltip(
            message: aiVisible ? '收起聊天' : '打开聊天',
            child: IconButton(
              icon: Icon(
                aiVisible ? FluentIcons.chat_solid : FluentIcons.chat,
                size: 13.5,
                color: aiVisible ? accent : theme.resources.textFillColorSecondary,
              ),
              onPressed: () => ref.read(aiControllerProvider.notifier).togglePanel(),
            ),
          ),
          const SizedBox(width: 4),
          // Minimize & Close (FR-WIN-01, FR-WIN-05)
          _WindowCaptionBtn(
            icon: FluentIcons.chrome_minimize,
            tooltip: '最小化',
            onPressed: () => ws?.minimize(),
          ),
          _WindowCaptionBtn(
            icon: FluentIcons.chrome_close,
            tooltip: settings.closeToTray ? '最小化到托盘' : '关闭',
            isClose: true,
            onPressed: () => ws?.close(),
          ),
        ],
      ),
    );
  }
}

class _WindowCaptionBtn extends StatefulWidget {
  const _WindowCaptionBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isClose = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isClose;

  @override
  State<_WindowCaptionBtn> createState() => _WindowCaptionBtnState();
}

class _WindowCaptionBtnState extends State<_WindowCaptionBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final dark = FluentTheme.of(context).brightness == Brightness.dark;
    final bg = _hovered
        ? (widget.isClose ? const Color(0xFFE81123) : (dark ? const Color(0x18FFFFFF) : const Color(0x12000000)))
        : Colors.transparent;
    final fg = (_hovered && widget.isClose)
        ? Colors.white
        : FluentTheme.of(context).resources.textFillColorPrimary;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 42,
            height: 36,
            color: bg,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 10, color: fg),
          ),
        ),
      ),
    );
  }
}
