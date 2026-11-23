import 'dart:convert';
import 'dart:io';

import 'package:fldoc/app/app.dart';
import 'package:fldoc/app/providers.dart';
import 'package:fldoc/core/database.dart';
import 'package:fldoc/core/paths.dart';
import 'package:fldoc/features/ai/ai_controller.dart';
import 'package:fldoc/features/library/library_controller.dart';
import 'package:fldoc/features/palette/command_registry.dart' show DynamicModeKind, DynamicSubmode, paletteProvider;
import 'package:fldoc/features/palette/palette_overlay.dart';
import 'package:fldoc/features/reader/find/find_controller.dart';
import 'package:fldoc/features/reader/navigation/navigation_controller.dart';
import 'package:fldoc/features/search/symbols/symbol_index.dart';
import 'package:fldoc/features/settings/credential_store.dart';
import 'package:fldoc/features/settings/settings_controller.dart';
import 'package:fldoc/features/settings/settings_model.dart';
import 'package:fldoc/features/settings/settings_store.dart';
import 'package:fldoc/features/window/ui_state.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final fixturesRoot = p.normalize(p.join(Directory.current.path, 'test', 'fixtures', 'libraries'));

  (ProviderContainer, Directory, AppDatabase, SettingsStore, UiState) makeEnv({String? customRoot}) {
    final tmp = Directory.systemTemp.createTempSync('fldoc_wt_');
    AppPaths.setForTest(tmp.path);
    final db = AppDatabase.inMemory();
    final ui = UiState({});
    final store = SettingsStore(p.join(tmp.path, 'settings.json'));
    store.save(
      AppSettings.defaultSettings()
          .copyWith('oobeCompleted', true)
          .copyWith('libraryRoots', [(customRoot ?? fixturesRoot).replaceAll('\\', '/')]),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        uiStateProvider.overrideWithValue(ui),
        windowServiceProvider.overrideWithValue(null),
        settingsStoreProvider.overrideWithValue(store),
        credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      ],
    );
    return (container, tmp, db, store, ui);
  }

  testWidgets('end-to-end app smoke: Home -> Reader -> Find -> Palette focus -> Chat panel persistence -> Settings',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (container, tmp, db, store, ui) = makeEnv();
    addTearDown(() {
      store.dispose();
      ui.dispose();
      container.dispose();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const FlDocApp()));
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        if (container.read(libraryProvider).loadedOnce) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 1. Home -> Reader & language toggle.
    expect(find.text('Riverpod'), findsWidgets);
    expect(find.text('plain-notes'), findsWidgets);
    await tester.tap(find.text('Riverpod').last);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (container.read(navigationProvider).page != null) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(container.read(navigationProvider).view, AppView.reader);
    expect(find.text('快速开始'), findsWidgets);

    container.read(settingsProvider.notifier).set('reading.language', 'original');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (container.read(navigationProvider).page?.lang == 'original') break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Getting Started'), findsWidgets);

    // 2. FindBar.
    container.read(findProvider.notifier).open(initial: 'ProviderScope');
    await tester.pump();
    expect(find.textContaining('1/'), findsOneWidget);
    container.read(findProvider.notifier).close();
    await tester.pump();

    // 3. Command Palette Enter keeps EditableText focus for global search.
    container.read(paletteProvider.notifier).openRoot();
    await tester.pump();
    await tester.enterText(find.byType(TextBox).first, 'qjss');
    await tester.pump();
    expect(find.text('全局搜索'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 50));

    final sub = container.read(paletteProvider).activeSubmode;
    expect(sub, isA<DynamicSubmode>());
    expect((sub as DynamicSubmode).kind, DynamicModeKind.globalSearch);
    final primaryCtx = FocusManager.instance.primaryFocus?.context;
    final editable = primaryCtx?.widget is EditableText
        ? primaryCtx!.widget as EditableText
        : primaryCtx?.findAncestorWidgetOfExactType<EditableText>();
    expect(editable, isNotNull);
    tester.testTextInput.enterText('ProviderScope');
    await tester.pump();
    expect(editable!.controller.text, 'ProviderScope');
    container.read(paletteProvider.notifier).close();
    await tester.pump();

    // 4. Sidebar iconBar + Chat panel (Zen layout, non-bot icon, persistent controls).
    container.read(settingsProvider.notifier).set('sidebar.collapsedMode', 'iconBar');
    container.read(settingsProvider.notifier).set('sidebar.visible', false);
    container.read(aiControllerProvider.notifier).setVisible(true);
    await tester.pump();
    expect(find.byIcon(FluentIcons.global_nav_button), findsOneWidget);
    expect(find.text('聊天'), findsOneWidget);
    expect(find.text('Zen ask what ?'), findsOneWidget);
    expect(find.byIcon(FluentIcons.chat_bot), findsNothing);
    expect(find.byIcon(FluentIcons.chat), findsWidgets);

    await tester.tap(find.text('思考: 默认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.text('高 (high)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    await tester.tap(find.text('274k'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.text('500k'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    final reloaded = SettingsStore(p.join(tmp.path, 'settings.json')).load().settings!;
    expect(reloaded.chatReasoningEffort, 'high');
    expect(reloaded.chatContextWindow, 500000);

    // 5. Settings page.
    container.read(navigationProvider.notifier).openSettings(section: 'appearance');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('颜色主题'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('global search ranks dedicated page above anchorless catalog index and opens it on Enter',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final libRoot = Directory.systemTemp.createTempSync('fldoc_wt_gs_');
    addTearDown(() => libRoot.deleteSync(recursive: true));

    final pagesDir = Directory(p.join(libRoot.path, 'flutter', 'latest', 'pages'))..createSync(recursive: true);
    Directory(p.join(pagesDir.path, 'reference')).createSync(recursive: true);
    Directory(p.join(pagesDir.path, 'cookbook', 'forms')).createSync(recursive: true);

    File(p.join(libRoot.path, 'flutter', 'manifest.json')).writeAsStringSync(jsonEncode({
      'schema': 'fldoc.library/1',
      'id': 'flutter',
      'name': 'Flutter',
      'sourceLanguage': 'en',
      'displayLanguage': 'zh-CN',
      'defaultVersion': 'latest',
      'versions': [
        {
          'id': 'latest',
          'label': 'latest',
          'dir': 'latest',
          'toc': [
            {'title': 'Flutter Widget 索引', 'page': 'pages/reference/widgets.md'},
            {'title': '处理文本输入', 'page': 'pages/cookbook/forms/text-input.md'},
            {'title': '入门指南', 'page': 'pages/intro.md'},
          ],
        },
      ],
    }));

    File(p.join(libRoot.path, 'flutter', 'latest', 'symbols.json')).writeAsStringSync(jsonEncode({
      'schema': 'fldoc.symbols/1',
      'symbols': [
        {
          'name': 'TextField',
          'qualifiedName': 'TextField',
          'kind': 'class',
          'page': 'pages/reference/widgets.md',
          'anchor': '',
        },
      ],
    }));

    File(p.join(pagesDir.path, 'reference', 'widgets.md')).writeAsStringSync(
      '---\ntitle: Flutter Widget 索引\n---\n\n[TextField](a.md) 文本输入框。[TextField](a.md) 示例。\n',
    );
    File(p.join(pagesDir.path, 'cookbook', 'forms', 'text-input.md')).writeAsStringSync(
      '---\ntitle: 处理文本输入\n---\n\n## TextField {#textfield}\n\n使用 TextField 构建并自定义输入框。\n',
    );
    File(p.join(pagesDir.path, 'intro.md')).writeAsStringSync(
      '---\ntitle: 入门指南\n---\n\n在根组件使用 ProviderScope 管理状态。\n',
    );

    final (container, tmp, db, store, ui) = makeEnv(customRoot: libRoot.path);
    addTearDown(() {
      store.dispose();
      ui.dispose();
      container.dispose();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const FlDocApp()));
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        if (container.read(libraryProvider).loadedOnce) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pump();
    expect(container.read(symbolIndexProvider).length, 1);

    container.read(paletteProvider.notifier).openRoot();
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('palette-input-field')), 'qjss');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((container.read(paletteProvider).activeSubmode as DynamicSubmode).kind, DynamicModeKind.globalSearch);

    final paletteFinder = find.byType(CommandPaletteOverlay);
    final introHit = find.descendant(of: paletteFinder, matching: find.textContaining('入门指南 · Flutter'));
    final textInputHit = find.descendant(of: paletteFinder, matching: find.textContaining('处理文本输入 · Flutter'));
    final widgetsHit = find.descendant(of: paletteFinder, matching: find.textContaining('Flutter Widget 索引 · Flutter'));

    // 1. Populate an initial global search result for "ProviderScope".
    await tester.enterText(find.byKey(const ValueKey('palette-input-field')), 'ProviderScope');
    await tester.pump(const Duration(milliseconds: 650));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (introHit.evaluate().isNotEmpty) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    }
    expect(introHit, findsWidgets);

    // 2. Type "TextField" and press Enter while debounce is still pending:
    //    must trigger search for "TextField" instead of opening stale "intro.md".
    await tester.enterText(find.byKey(const ValueKey('palette-input-field')), 'TextField');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(container.read(paletteProvider).open, isTrue);
    expect(container.read(navigationProvider).page, isNull);

    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (textInputHit.evaluate().isNotEmpty) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    }
    expect(textInputHit, findsWidgets);
    expect(widgetsHit, findsWidgets);
    expect(
      find.descendant(of: paletteFinder, matching: find.textContaining('class · Flutter / Flutter Widget 索引')),
      findsNothing,
    );
    expect(
      tester.getTopLeft(textInputHit.first).dy,
      lessThan(tester.getTopLeft(widgetsHit.first).dy),
    );

    // 3. Pressing Enter now opens the dedicated heading match page, not widgets.md.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (container.read(navigationProvider).page != null) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(container.read(paletteProvider).open, isFalse);
    expect(container.read(navigationProvider).page?.page, 'pages/cookbook/forms/text-input.md');

    await tester.pump(const Duration(seconds: 1));
  });
}
