import 'dart:io';
import 'dart:ui' as ui;

import 'package:fldoc/app/app.dart';
import 'package:fldoc/app/providers.dart';
import 'package:fldoc/core/database.dart';
import 'package:fldoc/core/log.dart';
import 'package:fldoc/core/paths.dart';
import 'package:fldoc/features/ai/ai_controller.dart';
import 'package:fldoc/features/library/library_controller.dart';
import 'package:fldoc/features/library/models.dart';
import 'package:fldoc/features/palette/command_registry.dart';
import 'package:fldoc/features/reader/find/find_controller.dart';
import 'package:fldoc/features/reader/mermaid/mermaid_renderer.dart';
import 'package:fldoc/features/reader/navigation/navigation_controller.dart';
import 'package:fldoc/features/search/models.dart';
import 'package:fldoc/features/settings/credential_store.dart';
import 'package:fldoc/features/settings/settings_controller.dart';
import 'package:fldoc/features/settings/settings_model.dart';
import 'package:fldoc/features/settings/settings_store.dart';
import 'package:fldoc/features/window/ui_state.dart';
import 'package:fldoc/features/window/window_service.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// Visual verification runner executed on real Windows desktop (`flutter run -d windows -t tool/visual_verify.dart`).
/// Captures pixel-accurate PNG screenshots of every required view via RepaintBoundary
/// with real Windows fonts, real Impeller rendering, real rg.exe, and real WebView2 Mermaid!
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final outDir = Platform.environment['FLDOC_SCREENSHOT_DIR'] ?? p.join(Directory.current.path, 'build', 'visual_verify');
  Directory(outDir).createSync(recursive: true);

  final tmpSupport = Directory.systemTemp.createTempSync('fldoc_visual_');
  final paths = await AppPaths.init(overrideSupportDir: tmpSupport.path);
  Log.init(paths.logsDir);

  final fixturesRoot = p.normalize(p.join(Directory.current.path, 'test', 'fixtures', 'libraries')).replaceAll('\\', '/');
  final store = SettingsStore(paths.settingsFile);
  store.save(
    AppSettings.defaultSettings()
        .copyWith('oobeCompleted', true)
        .copyWith('libraryRoots', [fixturesRoot])
        .copyWith('appearance.theme', 'dark'),
  );

  final db = AppDatabase.open(paths.dbFile);
  final uiState = UiState({
    'sidebarWidth': 260,
    'aiPanelWidth': 360,
    'aiPanelVisible': false,
    'window': {'x': 120, 'y': 80, 'w': 1240, 'h': 800, 'maximized': false},
  });

  WindowService? ws;
  if (Platform.isWindows) {
    ws = WindowService(uiState)..init();
  }

  final boundaryKey = GlobalKey();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      uiStateProvider.overrideWithValue(uiState),
      windowServiceProvider.overrideWithValue(ws),
      settingsStoreProvider.overrideWithValue(store),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
    ],
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(key: boundaryKey, child: const FlDocApp()),
    ),
  );

  Future<void> settle([int ms = 600]) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> snap(String name) async {
    await settle(400);
    final boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      stdout.writeln('SNAP_FAIL $name: no boundary');
      return;
    }
    final image = await boundary.toImage(pixelRatio: 1.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (byteData != null) {
      final f = File(p.join(outDir, '$name.png'));
      f.writeAsBytesSync(byteData.buffer.asUint8List());
      stdout.writeln('SNAP_OK $name -> ${f.path} (${f.lengthSync()} bytes)');
    }
  }

  try {
    // Wait for libraries to finish loading.
    for (var i = 0; i < 40; i++) {
      if (container.read(libraryProvider).loadedOnce) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // 1. Home (Dark)
    await snap('01_home_dark');

    // 2. Reader (Dark) — open sample-riverpod index.md (has code, alert, table, task list, LaTeX, SVG, Mermaid)
    final riverpod = container.read(libraryProvider).libraries.firstWhere((l) => l.id == 'sample-riverpod');
    await container.read(navigationProvider.notifier).openLibrary(riverpod);
    await settle(2500); // give WebView2 time to render Mermaid!
    await snap('02_reader_dark');

    // 3. Reader scrolled to Architecture + LaTeX + SVG + Mermaid!
    await container.read(navigationProvider.notifier).open(
          DocLocation(libKey: riverpod.key, versionId: '3.x', page: 'pages/index.md', anchor: 'architecture-demo'),
        );
    await settle(3000);
    await snap('03_reader_math_mermaid_dark');

    // 4. Reader (Light) + FindBar active
    container.read(settingsProvider.notifier).set('appearance.theme', 'light');
    await container.read(navigationProvider.notifier).open(
          DocLocation(libKey: riverpod.key, versionId: '3.x', page: 'pages/index.md', anchor: 'install-dependencies'),
        );
    container.read(findProvider.notifier).open(initial: 'ProviderScope');
    await settle(800);
    await snap('04_reader_light_find');
    container.read(findProvider.notifier).close();

    // 5. Sidebar collapsed (iconBar) + AI Panel visible
    container.read(settingsProvider.notifier).set('sidebar.collapsedMode', 'iconBar');
    container.read(settingsProvider.notifier).set('sidebar.visible', false);
    container.read(aiControllerProvider.notifier).setVisible(true);
    await settle(500);
    await snap('05_iconbar_and_ai_panel');

    // Restore sidebar, hide AI panel, switch back to dark for palette/global search
    container.read(aiControllerProvider.notifier).setVisible(false);
    container.read(settingsProvider.notifier).set('sidebar.visible', true);
    container.read(settingsProvider.notifier).set('appearance.theme', 'dark');

    // 6. Command Palette root
    container.read(paletteProvider.notifier).openRoot();
    await settle(400);
    await snap('06_palette_root');

    // 7. Global Search submode with real rg.exe query
    container.read(paletteProvider.notifier).openSubmode(const DynamicSubmode(
          title: '全局搜索',
          placeholder: '输入关键词实时搜索…',
          kind: DynamicModeKind.globalSearch,
          initialQuery: 'ProviderScope',
          initialScope: SearchScope.allLibraries,
        ));
    await settle(1000);
    await snap('07_global_search');
    container.read(paletteProvider.notifier).close();

    // 8. Settings page (AI section)
    container.read(navigationProvider.notifier).openSettings(section: 'ai');
    await settle(500);
    await snap('08_settings_ai');

    // 9. OOBE Wizard
    container.read(paletteProvider.notifier).openOobe();
    await settle(500);
    await snap('09_oobe');

    // Check WebView2 + Mermaid cache files!
    final wv2 = await MermaidRenderer.checkWebView2Version();
    final mmdFiles = Directory(paths.mermaidCacheDir).listSync();
    stdout.writeln('WEBVIEW2_VERSION=$wv2');
    stdout.writeln('MERMAID_CACHE_COUNT=${mmdFiles.length}');
    for (final f in mmdFiles) {
      stdout.writeln('  MERMAID_CACHE=${p.basename(f.path)} (${File(f.path).lengthSync()} bytes)');
    }
  } finally {
    await MermaidRenderer.instance.dispose();
    db.close();
    try {
      tmpSupport.deleteSync(recursive: true);
    } catch (_) {}
    exit(0);
  }
}
