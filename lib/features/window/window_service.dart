import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:nativeapi/nativeapi.dart' as na;
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../../core/log.dart';
import 'ui_state.dart';

/// Window chrome behaviour: bounds memory, tray, close-to-tray, topmost,
/// opacity and launch-at-startup.
class WindowService {
  WindowService(this.uiState);

  final UiState uiState;
  na.Window? _window;
  tray.TrayIcon? _trayIcon;
  na.MenuItem? _topmostItem;
  bool closeToTray = true;
  bool _quitting = false;

  void Function()? onToggleTopmostFromTray;
  void Function()? onQuit;

  static const Rect defaultBounds = Rect.fromLTWH(0, 0, 520, 820);

  na.Window? get window => _window;

  /// Applies bounds before the first frame is shown.
  void init() {
    _window = WindowManager.instance.getCurrent();
    final w = _window;
    if (w == null) return;
    w.title = 'flDoc';
    w.titleBarStyle = TitleBarStyle.hidden;
    w.minimumSize = const Size(360, 400).toNative();
    _restoreBounds(w);
    w.addListener(_onEvent);
  }

  void _restoreBounds(na.Window w) {
    final b = uiState.windowBounds;
    if (b != null) {
      final rect = Rect.fromLTWH(
        (b['x'] as num?)?.toDouble() ?? 0,
        (b['y'] as num?)?.toDouble() ?? 0,
        (b['w'] as num?)?.toDouble() ?? defaultBounds.width,
        (b['h'] as num?)?.toDouble() ?? defaultBounds.height,
      );
      if (_isOnAnyDisplay(rect)) {
        w.bounds = rect.toNative();
        if (b['maximized'] == true) w.maximize();
        return;
      }
    }
    resetBounds();
  }

  bool _isOnAnyDisplay(Rect r) {
    try {
      final displays = na.DisplayManager.instance.getAll();
      if (displays.isEmpty) return true;
      final center = r.center;
      for (final d in displays) {
        final wa = d.workArea;
        final area = Rect.fromLTWH(wa.x, wa.y, wa.width, wa.height);
        if (area.contains(center)) return true;
      }
      return false;
    } catch (e) {
      Log.warn('display query failed: $e');
      return true;
    }
  }

  /// Centers the window on the primary display with the default size.
  void resetBounds() {
    final w = _window;
    if (w == null) return;
    if (w.isMaximized) w.unmaximize();
    w.setSize(defaultBounds.size.toNative(), false);
    w.center();
    _saveBounds();
  }

  Timer? _saveTimer;

  void _onEvent(WindowEvent event) {
    switch (event) {
      case WindowCloseRequestedEvent():
        if (closeToTray && !_quitting) {
          event.request.cancel();
          _saveBounds();
          uiState.saveSync();
          _window?.hide();
        } else {
          _saveBounds();
          uiState.saveSync();
        }
      case WindowMovedEvent() || WindowResizedEvent() || WindowMaximizedEvent() || WindowRestoredEvent():
        _saveTimer?.cancel();
        _saveTimer = Timer(const Duration(milliseconds: 500), _saveBounds);
      default:
        break;
    }
  }

  void _saveBounds() {
    final w = _window;
    if (w == null || w.isMinimized) return;
    final maximized = w.isMaximized;
    final prev = uiState.windowBounds;
    if (maximized && prev != null) {
      uiState.windowBounds = {...prev, 'maximized': true};
      return;
    }
    final r = w.bounds.toRect();
    uiState.windowBounds = {'x': r.left, 'y': r.top, 'w': r.width, 'h': r.height, 'maximized': maximized};
  }

  // ---- title bar actions ----

  void minimize() => _window?.minimize();

  void toggleMaximize() {
    final w = _window;
    if (w == null) return;
    w.isMaximized ? w.unmaximize() : w.maximize();
  }

  void close() => _window?.close();

  void showAndFocus() {
    final w = _window;
    if (w == null) return;
    if (w.isMinimized) w.restore();
    w.show();
    w.focus();
  }

  void setAlwaysOnTop(bool v) {
    _window?.isAlwaysOnTop = v;
    _topmostItem?.state = v ? na.MenuItemState.checked : na.MenuItemState.unchecked;
  }

  void setOpacity(double v) => _window?.opacity = v.clamp(0.3, 1.0);

  // ---- tray ----

  void initTray({required bool alwaysOnTop}) {
    try {
      final icon = tray.TrayIcon.create();
      if (icon == null) return;
      final img = tray.ImageAsset.fromAsset('assets/icons/tray.png');
      if (img != null) icon.icon = img;
      icon.setTooltip('flDoc');

      final menu = tray.Menu.create()!;
      final show = tray.MenuItem.createWithLabelAndType('显示主窗口', tray.MenuItemType.normal)!;
      show.addListener((e) {
        if (e is tray.MenuItemClickedEvent) showAndFocus();
      });
      final topmost = tray.MenuItem.createWithLabelAndType('切换置顶', tray.MenuItemType.checkbox)!;
      topmost.state = alwaysOnTop ? na.MenuItemState.checked : na.MenuItemState.unchecked;
      topmost.addListener((e) {
        if (e is tray.MenuItemClickedEvent) onToggleTopmostFromTray?.call();
      });
      final quit = tray.MenuItem.createWithLabelAndType('退出', tray.MenuItemType.normal)!;
      quit.addListener((e) {
        if (e is tray.MenuItemClickedEvent) onQuit?.call();
      });
      menu.addItem(show);
      menu.addItem(topmost);
      menu.addSeparator();
      menu.addItem(quit);
      icon.setContextMenu(menu);
      icon.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
      icon.addListener((e) {
        if (e is tray.TrayIconClickedEvent || e is tray.TrayIconDoubleClickedEvent) showAndFocus();
      });
      icon.setVisible(true);
      _trayIcon = icon;
      _topmostItem = topmost;
    } catch (e, st) {
      Log.error('tray init failed', e, st);
    }
  }

  /// Exits the application for real (tray "退出" / app.quit).
  void quit() {
    _quitting = true;
    _saveBounds();
    uiState.saveSync();
    try {
      _trayIcon?.dispose();
    } catch (_) {}
    _trayIcon = null;
    exit(0);
  }

  // ---- launch at startup ----

  static void setupLaunchAtStartup() {
    launchAtStartup.setup(appName: 'flDoc', appPath: Platform.resolvedExecutable);
  }

  static Future<void> setLaunchAtStartup(bool enabled) async {
    try {
      final current = await launchAtStartup.isEnabled();
      if (current == enabled) return;
      enabled ? await launchAtStartup.enable() : await launchAtStartup.disable();
    } catch (e) {
      Log.warn('launch at startup failed: $e');
    }
  }
}
