import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'find_controller.dart';

/// Floating in-page find bar (Ctrl+F) at the top-right of the reader (FR-FIND-01..06).
class FindBar extends ConsumerStatefulWidget {
  const FindBar({super.key});

  @override
  ConsumerState<FindBar> createState() => _FindBarState();
}

class _FindBarState extends ConsumerState<FindBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    final initial = ref.read(findProvider).query;
    _ctrl.text = initial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focus.requestFocus();
        _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final find = ref.watch(findProvider);
    final ctl = ref.read(findProvider.notifier);
    final theme = FluentTheme.of(context);

    ref.listen(findProvider.select((s) => s.open), (prev, next) {
      if (next) {
        final q = ref.read(findProvider).query;
        if (_ctrl.text != q) _ctrl.text = q;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _focus.requestFocus();
            _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
          }
        });
      }
    });

    if (!find.open) return const SizedBox.shrink();

    final countText = find.query.isEmpty
        ? ''
        : (find.matches.isEmpty ? '0/0' : '${find.current + 1}/${find.matches.length}');

    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            ctl.close();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            if (HardwareKeyboard.instance.isShiftPressed) {
              ctl.previous();
            } else {
              ctl.next();
            }
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        width: 360,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: theme.menuColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.16), blurRadius: 12, offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: TextBox(
                controller: _ctrl,
                focusNode: _focus,
                autofocus: true,
                textInputAction: TextInputAction.none,
                onEditingComplete: () {},
                placeholder: '在本页查找…',
                onChanged: ctl.setQuery,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (countText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  countText,
                  style: TextStyle(
                    fontSize: 12,
                    color: find.matches.isEmpty ? Colors.red : theme.resources.textFillColorSecondary,
                  ),
                ),
              ),
            _ToggleChip(
              label: 'Aa',
              tooltip: '区分大小写',
              active: find.caseSensitive,
              onPressed: ctl.toggleCase,
            ),
            const SizedBox(width: 2),
            _ToggleChip(
              label: 'ab',
              tooltip: '全词匹配',
              active: find.wholeWord,
              onPressed: ctl.toggleWholeWord,
            ),
            IconButton(
              icon: const Icon(FluentIcons.up, size: 12),
              onPressed: find.matches.isEmpty ? null : ctl.previous,
            ),
            IconButton(
              icon: const Icon(FluentIcons.down, size: 12),
              onPressed: find.matches.isEmpty ? null : ctl.next,
            ),
            IconButton(
              icon: const Icon(FluentIcons.chrome_close, size: 11),
              onPressed: ctl.close,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({required this.label, required this.tooltip, required this.active, required this.onPressed});

  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: active ? theme.accentColor.withValues(alpha: 0.22) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active ? theme.accentColor : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.w700 : FontWeight.normal,
              color: active ? theme.accentColor.defaultBrushFor(theme.brightness) : theme.resources.textFillColorPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
