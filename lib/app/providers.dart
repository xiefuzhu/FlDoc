import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database.dart';
import '../features/window/ui_state.dart';
import '../features/window/window_service.dart';

/// Overridden in main() / tests.
final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError('databaseProvider'));
final uiStateProvider = Provider<UiState>((ref) => throw UnimplementedError('uiStateProvider'));
final windowServiceProvider = Provider<WindowService?>((ref) => null);

/// Transient status text (link hover target etc.).
final statusTextProvider = NotifierProvider<StatusTextNotifier, String?>(StatusTextNotifier.new);

class StatusTextNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

/// Toast-style notifications displayed by the shell.
class AppNotice {
  AppNotice(this.message, {this.isError = false, this.title});
  final String message;
  final String? title;
  final bool isError;
  final DateTime at = DateTime.now();
}

final noticeProvider = NotifierProvider<NoticeNotifier, AppNotice?>(NoticeNotifier.new);

class NoticeNotifier extends Notifier<AppNotice?> {
  @override
  AppNotice? build() => null;

  void show(String message, {bool isError = false, String? title}) =>
      state = AppNotice(message, isError: isError, title: title);

  void clear() => state = null;
}
