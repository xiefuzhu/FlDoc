import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'core/database.dart';
import 'core/log.dart';
import 'core/paths.dart';
import 'features/settings/credential_store.dart';
import 'features/settings/settings_controller.dart';
import 'features/window/ui_state.dart';
import 'features/window/window_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final paths = await AppPaths.init();
  Log.init(paths.logsDir);
  Log.info('flDoc starting (supportDir=${paths.supportDir})');

  FlutterError.onError = (details) {
    Log.error('FlutterError: ${details.exceptionAsString()}', null, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    Log.error('Uncaught platform error', error, stack);
    return true;
  };

  final db = AppDatabase.open(paths.dbFile);
  final uiState = UiState.load();
  final credStore = _createPlatformCredentialStore();
  await credStore.warmUp();

  WindowService? windowService;
  if (Platform.isWindows) {
    WindowService.setupLaunchAtStartup();
    windowService = WindowService(uiState)..init();
  }

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        uiStateProvider.overrideWithValue(uiState),
        windowServiceProvider.overrideWithValue(windowService),
        credentialStoreProvider.overrideWithValue(credStore),
      ],
      child: const FlDocApp(),
    ),
  );
}

CredentialStore _createPlatformCredentialStore() {
  if (!Platform.isAndroid) {
    return CredentialStore.platform();
  }
  const channel = MethodChannel('dev.fldoc/credentials');
  return AndroidCredentialStore(
    nativeLoadAll: () async {
      final res = await channel.invokeMapMethod<String, String>('readAll');
      return res ?? const {};
    },
    nativeWrite: (target, secret) async {
      await channel.invokeMethod<void>('write', {'target': target, 'secret': secret});
    },
    nativeDelete: (target) async {
      await channel.invokeMethod<void>('delete', {'target': target});
    },
  );
}
