import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/paths.dart';
import 'credential_store.dart';
import 'settings_model.dart';
import 'settings_store.dart';

final settingsStoreProvider = Provider<SettingsStore>((ref) {
  final store = SettingsStore(AppPaths.instance.settingsFile);
  ref.onDispose(store.dispose);
  return store;
});

final credentialStoreProvider = Provider<CredentialStore>((ref) => CredentialStore.platform());

/// Latest settings error message (invalid external edit), or null.
final settingsErrorProvider = NotifierProvider<SettingsErrorNotifier, String?>(SettingsErrorNotifier.new);

class SettingsErrorNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? v) => state = v;
}

/// Single source of truth for settings; used by the settings page and by
/// palette commands alike (FR-ST-06).
final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

class SettingsController extends Notifier<AppSettings> {
  late SettingsStore _store;

  @override
  AppSettings build() {
    _store = ref.watch(settingsStoreProvider);
    final r = _store.load();
    if (r.error != null) {
      Future.microtask(() => ref.read(settingsErrorProvider.notifier).set(r.error));
    }
    _store.watch((result) {
      if (result.settings != null) {
        state = result.settings!;
        ref.read(settingsErrorProvider.notifier).set(null);
      } else {
        ref.read(settingsErrorProvider.notifier).set(result.error);
      }
    });
    return r.settings ?? AppSettings.defaultSettings();
  }

  void set(String path, Object? value) {
    if (state.get(path) == value) return;
    final next = state.copyWith(path, value);
    state = next;
    _store.save(next);
  }

  void setMany(Map<String, Object?> updates) {
    final changed = <String, Object?>{};
    for (final entry in updates.entries) {
      if (state.get(entry.key) != entry.value) {
        changed[entry.key] = entry.value;
      }
    }
    if (changed.isEmpty) return;
    final next = state.copyWithMany(changed);
    state = next;
    _store.save(next);
  }

  void toggle(String path) => set(path, !(state.get(path) as bool? ?? false));

  void replaceAll(AppSettings s) {
    state = s;
    _store.save(s);
  }
}
