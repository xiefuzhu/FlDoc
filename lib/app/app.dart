import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../features/library/library_controller.dart';
import '../features/settings/settings_controller.dart';
import '../features/settings/settings_model.dart';
import '../features/window/window_service.dart';
import 'providers.dart';
import 'shell.dart';
import 'shortcuts.dart';
import 'theme.dart';

/// Root Flutter application widget.
class FlDocApp extends ConsumerStatefulWidget {
  const FlDocApp({super.key});

  @override
  ConsumerState<FlDocApp> createState() => _FlDocAppState();
}

class _FlDocAppState extends ConsumerState<FlDocApp> {
  bool _windowBound = false;
  AppLifecycleListener? _lifecycle;
  DateTime? _lastAndroidResumeReload;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    _lifecycle = AppLifecycleListener(
      onInactive: _flushPersistence,
      onPause: _flushPersistence,
      onHide: _flushPersistence,
      onDetach: _flushPersistence,
      onExitRequested: () async {
        _flushPersistence();
        return AppExitResponse.exit;
      },
      onResume: _onAppResume,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _bindWindow());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    super.dispose();
  }

  void _flushPersistence() {
    try {
      ref.read(uiStateProvider).saveSync();
    } catch (_) {}
    try {
      ref.read(databaseProvider).checkpoint();
    } catch (_) {}
    Log.flushSyncBestEffort();
  }

  void _onAppResume() {
    if (!Platform.isAndroid) return;
    final now = DateTime.now();
    if (_lastAndroidResumeReload != null &&
        now.difference(_lastAndroidResumeReload!) < const Duration(seconds: 5)) {
      return;
    }
    try {
      final libState = ref.read(libraryProvider);
      if (libState.loadedOnce && !libState.loading) {
        _lastAndroidResumeReload = now;
        ref.read(libraryProvider.notifier).reload();
      }
    } catch (_) {}
  }

  bool _onGlobalKey(KeyEvent event) => handleAppShortcut(event, ref);

  void _bindWindow() {
    if (_windowBound) return;
    _windowBound = true;
    final ws = ref.read(windowServiceProvider);
    if (ws == null) return;
    final s = ref.read(settingsProvider);

    ws.onToggleTopmostFromTray = () {
      ref.read(settingsProvider.notifier).toggle('window.alwaysOnTop');
    };
    ws.onQuit = ws.quit;
    ws.initTray(alwaysOnTop: s.alwaysOnTop);
    _applyWindowSettings(ws, s);
  }

  void _applyWindowSettings(WindowService ws, AppSettings s) {
    ws.closeToTray = s.closeToTray;
    ws.setAlwaysOnTop(s.alwaysOnTop);
    ws.setOpacity(s.opacity);
    WindowService.setLaunchAtStartup(s.launchAtStartup);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final ws = ref.watch(windowServiceProvider);

    ref.listen(settingsProvider, (prev, next) {
      if (ws == null) return;
      if (prev == null ||
          prev.alwaysOnTop != next.alwaysOnTop ||
          prev.opacity != next.opacity ||
          prev.closeToTray != next.closeToTray ||
          prev.launchAtStartup != next.launchAtStartup) {
        _applyWindowSettings(ws, next);
      }
    });

    return FluentApp(
      title: 'flDoc',
      debugShowCheckedModeBanner: false,
      themeMode: themeModeOf(settings.theme),
      theme: buildTheme(settings, Brightness.light),
      darkTheme: buildTheme(settings, Brightness.dark),
      home: const AppShell(),
    );
  }
}
