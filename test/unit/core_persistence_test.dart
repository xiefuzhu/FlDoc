import 'dart:convert';
import 'dart:io';

import 'package:fldoc/app/providers.dart';
import 'package:fldoc/core/database.dart';
import 'package:fldoc/core/natural_sort.dart';
import 'package:fldoc/core/paths.dart';
import 'package:fldoc/core/slug.dart';
import 'package:fldoc/core/url_normalize.dart';
import 'package:fldoc/features/palette/command_registry.dart';
import 'package:fldoc/features/settings/credential_store.dart';
import 'package:fldoc/features/settings/settings_controller.dart';
import 'package:fldoc/features/settings/settings_model.dart';
import 'package:fldoc/features/settings/settings_store.dart';
import 'package:fldoc/features/window/ui_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('slug, natural sort, and url normalization', () {
    expect(githubSlug('Hello World!'), 'hello-world');
    expect(githubSlug('安装 依赖'), '安装-依赖');
    expect(githubSlug('Ref.watch() & Co'), 'refwatch--co');
    expect(githubSlug('snake_case-ok'), 'snake_case-ok');
    expect(githubSlug('中文，标点。'), '中文标点');
    expect(splitExplicitAnchor('安装依赖 {#install-dependencies}'), ('安装依赖', 'install-dependencies'));
    expect(splitExplicitAnchor('No anchor'), ('No anchor', null));

    final t = SlugTracker();
    expect([t.unique('intro'), t.unique('intro'), t.unique('intro'), t.unique('other')],
        ['intro', 'intro-1', 'intro-2', 'other']);

    final list = ['page10.md', 'page2.md', 'Page1.md', 'a.md']..sort(naturalCompare);
    expect(list, ['a.md', 'Page1.md', 'page2.md', 'page10.md']);

    expect(normalizeUrl('http://www.Riverpod.dev/docs/intro/'), 'https://riverpod.dev/docs/intro');
    expect(normalizeUrl('https://riverpod.dev/docs/intro.html#x'), 'https://riverpod.dev/docs/intro');
    expect(normalizeUrl('https://a.dev/docs/index.html'), 'https://a.dev/docs');
    expect(normalizeUrl('https://a.dev/docs/?q=1'), 'https://a.dev/docs');
    expect(normalizeUrl('https://a.dev/docs/?q=1', keepQuery: true), 'https://a.dev/docs?q=1');
    expect(normalizeUrl('https://a.dev/a%7eb'), 'https://a.dev/a~b');
    expect(normalizeUrl('mailto:x@y.z'), isNull);
    expect(normalizedUrlVariants('https://a.dev/p?id=2'), ['https://a.dev/p', 'https://a.dev/p?id=2']);
  });

  test('SettingsStore & UiState atomic persistence, defaults, and backup recovery', () {
    final s = AppSettings.fromJson({
      'appearance': {'theme': 'dark', 'custom': 1},
      'extra': {'a': true},
      'window': {'opacity': 'bad'},
    });
    expect(s.theme, 'dark');
    expect(s.fontSize, 15);
    expect(s.opacity, 1.0);
    expect(s.toJson()['extra'], {'a': true});
    expect((s.toJson()['appearance'] as Map)['custom'], 1);

    final bad = SettingsStore.parse('{\n  "a": 1,\n  "b": \n}');
    expect(bad.settings, isNull);
    expect(bad.error, contains('第 4 行'));

    final tmp = Directory.systemTemp.createTempSync('fldoc_persist_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    AppPaths.setForTest(tmp.path);

    final settingsPath = p.join(tmp.path, 'settings.json');
    final store = SettingsStore(settingsPath);
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(() {
      store.dispose();
      container.dispose();
    });

    final ctl = container.read(settingsProvider.notifier);
    ctl.setMany({
      'ai.chat.baseUrl': 'https://api.example.com/v1',
      'ai.chat.model': 'gpt-4o',
      'ai.chat.models': ['gpt-4o', 'o3-mini'],
      'ai.chat.reasoningEffort': 'high',
      'ai.chat.contextWindow': 500000,
    });
    ctl.set('ai.chat.model', 'o3-mini');
    ctl.set('ai.chat.contextWindow', 274000);

    // Corrupt primary settings.json -> backup snapshot must recover the prior valid save.
    File(settingsPath).writeAsStringSync('{corrupted', flush: true);
    final recovered = SettingsStore(settingsPath).load().settings!;
    expect(recovered.chatBaseUrl, 'https://api.example.com/v1');
    expect(recovered.chatModels, ['gpt-4o', 'o3-mini']);
    expect(recovered.chatReasoningEffort, 'high');

    // UiState saveSync + backup recovery.
    final ui = UiState({});
    ui.sidebarWidth = 310;
    ui.saveSync();
    ui.aiPanelWidth = 420;
    ui.saveSync();
    File(AppPaths.instance.stateFile).writeAsStringSync('{corrupted', flush: true);
    final uiReloaded = UiState.load();
    expect(uiReloaded.sidebarWidth, 310);
  });

  test('AppDatabase WAL pragmas, reading position, and checkpoint', () {
    final tmp = Directory.systemTemp.createTempSync('fldoc_db_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final db = AppDatabase.open(p.join(tmp.path, 'fldoc.db'));
    addTearDown(db.close);

    final jm = db.db.select('PRAGMA journal_mode;').first.values.first as String;
    expect(jm.toLowerCase(), 'wal');
    db.saveReadingPosition('lib1', '1.0', 'pages/a.md', 'sec', 0.42);
    final pos = db.readingPosition('lib1', '1.0', 'pages/a.md');
    expect(pos?.anchor, 'sec');
    expect(pos?.ratio, closeTo(0.42, 1e-6));
    db.checkpoint(truncate: true);
  });

  test('CredentialStore: LocalVault, AndroidCredentialStore, and Windows DPAPI', () async {
    final tmp = Directory.systemTemp.createTempSync('fldoc_cred_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final vaultPath = p.join(tmp.path, 'credentials.vault');
    final vault = LocalVaultCredentialStore(vaultFilePath: vaultPath);
    vault.write('flDoc/chat', 'sk-first-key-1234');
    vault.write('flDoc/embedding', 'sk-embed-key-5678');
    vault.write('flDoc/chat', 'sk-chat-updated-1234');
    expect(vault.read('flDoc/chat'), 'sk-chat-updated-1234');
    expect(vault.read('flDoc/embedding'), 'sk-embed-key-5678');

    // Tampered ciphertext fails HMAC verification cleanly.
    final doc = jsonDecode(File(vaultPath).readAsStringSync()) as Map<String, dynamic>;
    final entries = doc['entries'] as Map<String, dynamic>;
    (entries['flDoc/chat'] as Map<String, dynamic>)['c'] = base64Encode([1, 2, 3, 4]);
    File(vaultPath).writeAsStringSync(jsonEncode(doc), flush: true);
    expect(vault.read('flDoc/chat'), isNull);

    // Corrupted primary JSON recovers both keys from .bak snapshot.
    File(vaultPath).writeAsStringSync('{corrupted', flush: true);
    expect(vault.read('flDoc/chat'), 'sk-first-key-1234');
    expect(vault.read('flDoc/embedding'), 'sk-embed-key-5678');

    vault.delete('flDoc/chat');
    expect(vault.read('flDoc/chat'), isNull);
    expect(vault.read('flDoc/embedding'), 'sk-embed-key-5678');

    final androidStore = AndroidCredentialStore(
      vaultFilePath: p.join(tmp.path, 'android.vault'),
      nativeLoadAll: () async => {'flDoc/chat': 'sk-native-9999'},
    );
    await androidStore.warmUp();
    expect(androidStore.read('flDoc/chat'), 'sk-native-9999');

    if (Platform.isWindows) {
      final winStore = WindowsCredentialStore(fallbackFilePath: p.join(tmp.path, 'credentials.dpapi'));
      const target = 'flDoc/unit-test-temp';
      winStore.write(target, 'sk-verify-12345678');
      expect(winStore.read(target), 'sk-verify-12345678');
      expect(maskSecret(winStore.read(target)), 'sk-****5678');
      winStore.delete(target);

      // Oversized secret (>2560 bytes) exercises Windows DPAPI fallback cleanly.
      final longSecret = 'sk-${'a' * 3000}';
      winStore.write(target, longSecret);
      expect(winStore.read(target), longSecret);
      winStore.delete(target);
      expect(winStore.read(target), isNull);
    }
  });

  test('command registry exposes required commands without removed mica/settings.json items', () {
    final tmp = Directory.systemTemp.createTempSync('fldoc_cmd_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    AppPaths.setForTest(tmp.path);
    final db = AppDatabase.inMemory();
    final ui = UiState({});
    final store = SettingsStore(p.join(tmp.path, 'settings.json'));
    store.save(AppSettings.defaultSettings().copyWith('oobeCompleted', true));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        uiStateProvider.overrideWithValue(ui),
        windowServiceProvider.overrideWithValue(null),
        settingsStoreProvider.overrideWithValue(store),
        credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      ],
    );
    addTearDown(() {
      store.dispose();
      ui.dispose();
      container.dispose();
      db.close();
    });

    final cmds = container.read(commandRegistryProvider);
    final ids = cmds.map((c) => c.id).toSet();
    for (final id in const [
      'nav.home', 'nav.openPage', 'search.global', 'search.findInPage', 'ai.ask',
      'view.toggleSidebar', 'reading.toggleLanguage', 'window.toggleAlwaysOnTop',
      'pref.theme', 'pref.aiChat', 'pref.aiEmbedding', 'pref.openSettings',
      'library.import', 'library.validate', 'help.about',
    ]) {
      expect(ids, contains(id));
    }
    expect(ids, isNot(contains('pref.mica')));
    expect(ids, isNot(contains('pref.openSettingsJson')));
    expect(cmds.firstWhere((c) => c.id == 'pref.openSettings').title, '打开设置');
  });
}
