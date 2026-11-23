import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/palette/command_registry.dart';
import '../features/reader/find/find_controller.dart';
import '../features/reader/navigation/navigation_controller.dart';
import '../features/reader/ui/reader_view.dart';
import '../features/settings/settings_controller.dart';

/// Base fixed keyboard shortcuts (doc 05 §3).
/// Respects text input focus for `Ctrl+B` and `Alt+←/→`.
bool handleAppShortcut(KeyEvent event, WidgetRef ref) {
  if (event is! KeyDownEvent) return false;
  final key = event.logicalKey;
  final ctrl = HardwareKeyboard.instance.isControlPressed;
  final shift = HardwareKeyboard.instance.isShiftPressed;
  final alt = HardwareKeyboard.instance.isAltPressed;

  // Ctrl+Shift+P: Command Palette (works everywhere)
  if (ctrl && shift && !alt && key == LogicalKeyboardKey.keyP) {
    final pal = ref.read(paletteProvider);
    if (pal.open) {
      ref.read(paletteProvider.notifier).close();
    } else {
      ref.read(paletteProvider.notifier).openRoot();
    }
    return true;
  }

  // Esc: close Command Palette -> FindBar
  if (!ctrl && !shift && !alt && key == LogicalKeyboardKey.escape) {
    if (ref.read(paletteProvider).open) {
      ref.read(paletteProvider.notifier).close();
      return true;
    }
    if (ref.read(findProvider).open || ref.read(findProvider).active) {
      ref.read(findProvider.notifier).close();
      return true;
    }
    return false;
  }

  // Ctrl+F: Find in page when reader is active
  if (ctrl && !shift && !alt && key == LogicalKeyboardKey.keyF) {
    final nav = ref.read(navigationProvider);
    if (nav.view == AppView.reader && nav.page != null) {
      final sel = ref.read(readerSelectionProvider).trim();
      ref.read(findProvider.notifier).open(initial: sel.isNotEmpty && !sel.contains('\n') ? sel : null);
      return true;
    }
    return false;
  }

  // Ctrl+= / Ctrl+- / Ctrl+0: Font zoom
  if (ctrl && !alt) {
    if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd) {
      final next = (ref.read(settingsProvider).fontScale + 0.1).clamp(0.6, 2.0);
      ref.read(settingsProvider.notifier).set('reading.fontScale', double.parse(next.toStringAsFixed(2)));
      return true;
    }
    if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract) {
      final next = (ref.read(settingsProvider).fontScale - 0.1).clamp(0.6, 2.0);
      ref.read(settingsProvider.notifier).set('reading.fontScale', double.parse(next.toStringAsFixed(2)));
      return true;
    }
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      ref.read(settingsProvider.notifier).set('reading.fontScale', 1.0);
      return true;
    }
  }

  // Do not intercept Ctrl+B or Alt+Left/Right while typing inside an EditableText.
  if (_isTextInputFocused()) return false;

  // Ctrl+B: Toggle sidebar
  if (ctrl && !shift && !alt && key == LogicalKeyboardKey.keyB) {
    ref.read(settingsProvider.notifier).toggle('sidebar.visible');
    return true;
  }

  // Alt+Left / Alt+Right: Back / Forward
  if (alt && !ctrl && !shift && key == LogicalKeyboardKey.arrowLeft) {
    ref.read(navigationProvider.notifier).back();
    return true;
  }
  if (alt && !ctrl && !shift && key == LogicalKeyboardKey.arrowRight) {
    ref.read(navigationProvider.notifier).forward();
    return true;
  }

  return false;
}

bool _isTextInputFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}
