import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../settings/settings_controller.dart';

Future<void> importAndroidLibrary(WidgetRef ref, BuildContext context) async {
  const channel = MethodChannel('dev.fldoc/libraries');
  try {
    final root = await channel.invokeMethod<String>('importFolder');
    if (!context.mounted || root == null) return;
    final roots = ref.read(settingsProvider).libraryRoots;
    ref.read(settingsProvider.notifier).set('libraryRoots', [...roots, root]);
    ref.read(noticeProvider.notifier).show('已导入本地文档库');
  } on PlatformException catch (error) {
    if (context.mounted) {
      ref
          .read(noticeProvider.notifier)
          .show(error.message ?? '无法导入文件夹', isError: true);
    }
  }
}
