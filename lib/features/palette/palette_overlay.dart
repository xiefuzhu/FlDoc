import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../../core/debounce.dart';
import '../../core/paths.dart';
import '../ai/ai_controller.dart';
import '../ai/history/chat_history.dart';
import '../ai/retrieval/hybrid_retriever.dart';
import '../ai/ui/ai_config_guard.dart';
import '../importer/import_form_widget.dart';
import '../library/library_controller.dart';
import '../library/models.dart';
import '../library/validator/library_validator.dart';
import '../reader/mermaid/mermaid_renderer.dart';
import '../reader/navigation/navigation_controller.dart';
import '../search/models.dart';
import '../search/rg/rg_service.dart';
import '../search/symbols/symbol_index.dart';
import '../settings/settings_controller.dart';
import '../settings/ui/ai_model_form.dart';
import 'command_registry.dart';
import 'fuzzy_match.dart';

/// Top-centered floating Command Palette with 5 submodes (doc 05 §1).
class CommandPaletteOverlay extends ConsumerStatefulWidget {
  const CommandPaletteOverlay({super.key, this.mobile = false});

  final bool mobile;

  @override
  ConsumerState<CommandPaletteOverlay> createState() => _CommandPaletteOverlayState();
}

class _CommandPaletteOverlayState extends ConsumerState<CommandPaletteOverlay> {
  final _inputCtrl = TextEditingController();
  final _inputFocus = FocusNode();
  final _listCtrl = ScrollController();

  int _selected = 0;
  int _lastStackLen = -1;
  PaletteSubmode? _lastSubmode;

  // Text input validation error
  String? _inputError;

  // Dynamic submode state
  SearchScope _scope = SearchScope.currentLibrary;
  String _caseMode = 'smart'; // smart | sensitive | ignore
  bool _wholeWord = false;
  bool _regex = false;
  bool _searching = false;
  Debouncer? _searchDebounce;
  RgCancelToken? _rgCancel;

  RgSearchResult _rgResult = const RgSearchResult();
  List<SymbolSearchHit> _symResults = const [];
  HybridSearchResult _aiResult = const HybridSearchResult();
  String _aiLastQuery = '';
  String _lastGlobalQuery = '';
  String _lastSymbolQuery = '';
  Offset? _lastPointerPos;
  List<ChatSessionModel> _sessions = const [];

  @override
  void dispose() {
    _rgCancel?.cancel();
    _searchDebounce?.dispose();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  void _resetForSubmode(PaletteSubmode? mode) {
    _rgCancel?.cancel();
    _rgCancel = null;
    _searching = false;
    _selected = 0;
    _inputError = null;
    _rgResult = const RgSearchResult();
    _symResults = const [];
    _aiResult = const HybridSearchResult();
    _aiLastQuery = '';
    _lastGlobalQuery = '';
    _lastSymbolQuery = '';
    _lastPointerPos = null;

    final settings = ref.read(settingsProvider);
    _caseMode = settings.caseMode;
    _wholeWord = false;
    _regex = false;
    _searchDebounce?.dispose();
    _searchDebounce = Debouncer(Duration(milliseconds: settings.debounceMs.clamp(50, 600)));

    if (mode is TextInputSubmode) {
      _inputCtrl.text = mode.initialValue;
      _inputCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _inputCtrl.text.length);
    } else if (mode is DynamicSubmode) {
      _scope = mode.initialScope;
      _inputCtrl.text = mode.initialQuery;
      _inputCtrl.selection = TextSelection.collapsed(offset: _inputCtrl.text.length);
      if (mode.kind == DynamicModeKind.chatHistory) {
        _sessions = ref.read(chatHistoryRepoProvider).listSessions();
      } else if (mode.kind == DynamicModeKind.symbolSearch) {
        _runSymbolSearch(mode.initialQuery);
      } else if (mode.kind == DynamicModeKind.globalSearch && mode.initialQuery.isNotEmpty) {
        _runGlobalSearch(mode.initialQuery);
      } else if (mode.kind == DynamicModeKind.aiSearch && mode.initialQuery.isNotEmpty) {
        _runAiSearch(mode.initialQuery);
      }
    } else {
      _inputCtrl.clear();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && mode is! FormSubmode && mode is! ConfirmSubmode) {
        _inputFocus.requestFocus();
      }
    });
  }

  Library? _currentLib() {
    final libs = ref.read(libraryProvider);
    final loc = ref.read(navigationProvider).location;
    if (loc != null) {
      final hit = libs.byKey(loc.libKey);
      if (hit != null) return hit;
    }
    return libs.libraries.firstOrNull;
  }

  LibraryVersion? _currentVer(Library? lib) {
    if (lib == null) return null;
    final loc = ref.read(navigationProvider).location;
    if (loc != null && loc.libKey == lib.key) return lib.version(loc.versionId) ?? lib.defaultVersion;
    return lib.defaultVersion;
  }

  Future<void> _runGlobalSearch(String q) async {
    _rgCancel?.cancel();
    if (q.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _searching = false;
          _rgResult = const RgSearchResult();
          _symResults = const [];
          _lastGlobalQuery = '';
          _selected = 0;
        });
      }
      return;
    }
    final token = RgCancelToken();
    _rgCancel = token;
    setState(() => _searching = true);

    final libs = ref.read(libraryProvider).libraries;
    final curLib = _currentLib();
    final curVer = _currentVer(curLib);
    final settings = ref.read(settingsProvider);

    // Also include top matching symbols as in doc 05 §1 diagram!
    final syms = ref.read(symbolIndexProvider).search(
          q,
          scope: _scope,
          currentLibrary: curLib,
          currentVersion: curVer,
          limit: 5,
        );

    final res = await ref.read(rgServiceProvider).search(
          query: q,
          libraries: libs,
          scope: _scope,
          currentLibrary: curLib,
          currentVersion: curVer,
          currentLang: settings.language,
          caseMode: _caseMode,
          wholeWord: _wholeWord,
          regex: _regex,
          contextLines: settings.contextLines,
          maxResults: settings.maxResults,
          cancelToken: token,
        );
    if (!mounted || token.isCancelled) return;
    setState(() {
      _searching = false;
      _rgResult = res;
      _symResults = syms;
      _lastGlobalQuery = q.trim();
      _selected = 0;
    });
  }

  Future<void> _runSymbolSearch(String q) async {
    _rgCancel?.cancel();
    final token = RgCancelToken();
    _rgCancel = token;
    setState(() => _searching = true);

    final libs = ref.read(libraryProvider).libraries;
    final curLib = _currentLib();
    final curVer = _currentVer(curLib);
    final settings = ref.read(settingsProvider);

    final hits = await ref.read(symbolIndexProvider).searchWithFallback(
          q,
          libraries: libs,
          scope: _scope,
          currentLibrary: curLib,
          currentVersion: curVer,
          rgPath: settings.rgPath,
          cancelToken: token,
        );
    if (!mounted || token.isCancelled) return;
    setState(() {
      _searching = false;
      _symResults = hits;
      _lastSymbolQuery = q.trim();
      _selected = 0;
    });
  }

  Future<void> _runAiSearch(String q) async {
    final trimmed = q.trim();
    if (trimmed.isEmpty) return;
    _rgCancel?.cancel();
    final token = RgCancelToken();
    _rgCancel = token;
    setState(() {
      _searching = true;
      _aiLastQuery = trimmed;
      _aiResult = const HybridSearchResult();
    });
    final res = await ref.read(aiControllerProvider.notifier).hybridSearch(
          trimmed,
          scope: _scope,
          cancelToken: token,
        );
    if (!mounted || token.isCancelled) return;
    setState(() {
      _searching = false;
      _aiResult = res;
      _selected = 0;
    });
  }

  void _onQueryChanged(String q, PaletteSubmode? mode) {
    setState(() {
      _selected = 0;
      _inputError = null;
    });
    if (mode is DynamicSubmode) {
      switch (mode.kind) {
        case DynamicModeKind.globalSearch:
          _searchDebounce?.call(() => _runGlobalSearch(q));
        case DynamicModeKind.symbolSearch:
          _searchDebounce?.call(() => _runSymbolSearch(q));
        case DynamicModeKind.chatHistory:
          setState(() => _sessions = ref.read(chatHistoryRepoProvider).listSessions(query: q));
        case DynamicModeKind.aiSearch:
        case DynamicModeKind.openPage:
        case DynamicModeKind.gotoHeading:
        case DynamicModeKind.validationResults:
          break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = ref.watch(paletteProvider);
    if (!pal.open) {
      _searchDebounce?.cancel();
      _rgCancel?.cancel();
      _rgCancel = null;
      _searching = false;
      _lastStackLen = -1;
      _lastSubmode = null;
      _lastGlobalQuery = '';
      _lastSymbolQuery = '';
      _lastPointerPos = null;
      return const SizedBox.shrink();
    }

    final mode = pal.activeSubmode;
    if (_lastStackLen != pal.stack.length || !identical(_lastSubmode, mode)) {
      _lastStackLen = pal.stack.length;
      _lastSubmode = mode;
      _resetForSubmode(mode);
    }

    final theme = FluentTheme.of(context);
    final size = MediaQuery.of(context).size;
    final width = (size.width * 0.6).clamp(420.0, 720.0);
    final maxH = (size.height - 88).clamp(320.0, 580.0);

    final items = _buildItems(mode);
    if (widget.mobile) return BlockSemantics(child: _buildMobile(mode, items, theme));

    return Stack(
      children: [
        // Backdrop dismiss
        Positioned.fill(
          child: GestureDetector(
            onTap: () => ref.read(paletteProvider.notifier).close(),
            child: Container(color: Colors.black.withValues(alpha: 0.25)),
          ),
        ),
        Positioned(
          top: 44,
          left: (size.width - width) / 2,
          width: width,
          child: Focus(
            onKeyEvent: (node, event) => _handleKey(event, mode, items),
            child: Container(
              constraints: BoxConstraints(maxHeight: maxH),
              decoration: BoxDecoration(
                color: theme.menuColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 8)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Breadcrumb header (when in submode)
                  if (mode != null)
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => ref.read(paletteProvider.notifier).popSubmode(),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(FluentIcons.back, size: 11, color: theme.resources.textFillColorSecondary),
                                const SizedBox(width: 6),
                                Text(
                                  '${mode.title} >',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: theme.accentColor.defaultBrushFor(theme.brightness),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(FluentIcons.chrome_close, size: 11),
                            onPressed: () => ref.read(paletteProvider.notifier).close(),
                          ),
                        ],
                      ),
                    ),

                  // Input box (for root, option list, text input, dynamic results)
                  if (mode is! FormSubmode && mode is! ConfirmSubmode)
                    Padding(
                      key: const ValueKey('palette-input-box'),
                      padding: EdgeInsets.fromLTRB(12, mode == null ? 12 : 4, 12, 8),
                      child: TextBox(
                        key: const ValueKey('palette-input-field'),
                        controller: _inputCtrl,
                        focusNode: _inputFocus,
                        autofocus: true,
                        textInputAction: TextInputAction.none,
                        onEditingComplete: () {},
                        placeholder: mode?.placeholder.isNotEmpty == true
                            ? mode!.placeholder
                            : '输入命令名称或拼音首字母（如 qjss 全局搜索）…',
                        onChanged: (q) => _onQueryChanged(q, mode),
                        suffix: _searching
                            ? const Padding(
                                padding: EdgeInsets.only(right: 8),
                                child: SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2)),
                              )
                            : null,
                      ),
                    ),

                  // Filter chips for globalSearch / symbolSearch / aiSearch / openPage
                  if (mode is DynamicSubmode &&
                      (mode.kind == DynamicModeKind.globalSearch ||
                          mode.kind == DynamicModeKind.symbolSearch ||
                          mode.kind == DynamicModeKind.aiSearch ||
                          mode.kind == DynamicModeKind.openPage))
                    _buildChipsRow(mode, theme),

                  if (mode is TextInputSubmode && (_inputError != null || mode.hint != null))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                      child: Text(
                        _inputError ?? mode.hint!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _inputError != null ? Colors.red : theme.resources.textFillColorSecondary,
                        ),
                      ),
                    ),

                  if (mode is OptionListSubmode && mode.customInputHint != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                      child: Text(
                        mode.customInputHint!,
                        style: TextStyle(fontSize: 11.5, color: theme.resources.textFillColorSecondary),
                      ),
                    ),

                  // Body by mode
                  if (mode is FormSubmode)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: _buildFormBody(mode.kind),
                      ),
                    )
                  else if (mode is ConfirmSubmode)
                    _buildConfirmBody(mode)
                  else if (mode is TextInputSubmode)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Button(
                            onPressed: () => ref.read(paletteProvider.notifier).popSubmode(),
                            child: const Text('返回'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => _submitText(mode),
                            child: const Text('确认 (Enter)'),
                          ),
                        ],
                      ),
                    )
                  else
                    Flexible(child: _buildList(items, mode, theme)),

                  // Footer status bar
                  if (mode is! FormSubmode && mode is! ConfirmSubmode && mode is! TextInputSubmode)
                    _buildFooter(mode, items, theme),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobile(PaletteSubmode? mode, List<_PaletteRowItem> items, FluentThemeData theme) {
    final colors = m.ColorScheme.fromSeed(
      seedColor: theme.accentColor.defaultBrushFor(theme.brightness),
      brightness: theme.brightness,
    );
    final ctl = ref.read(paletteProvider.notifier);
    final title = mode?.title ?? '命令面板';
    return m.Theme(
      data: m.ThemeData(colorScheme: colors, useMaterial3: true),
      child: m.Material(
        color: colors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            m.ListTile(
              leading: m.IconButton(
                tooltip: '返回',
                icon: const Icon(m.Icons.arrow_back),
                onPressed: ref.read(paletteProvider).stack.length > 1 ? ctl.popSubmode : ctl.close,
              ),
              title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            if (mode is! FormSubmode && mode is! ConfirmSubmode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: m.TextField(
                  key: const ValueKey('palette-input-field'),
                  controller: _inputCtrl,
                  focusNode: _inputFocus,
                  textInputAction: TextInputAction.search,
                  onChanged: (q) => _onQueryChanged(q, mode),
                  onSubmitted: (q) {
                    if (mode is TextInputSubmode) {
                      _submitText(mode);
                    } else if (mode is DynamicSubmode && mode.kind == DynamicModeKind.aiSearch) {
                      _runAiSearch(q);
                    }
                  },
                  decoration: m.InputDecoration(
                    hintText: mode?.placeholder.isNotEmpty == true ? mode!.placeholder : '搜索命令',
                    errorText: _inputError,
                    prefixIcon: const Icon(m.Icons.search),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(15),
                            child: SizedBox.square(dimension: 16, child: m.CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : m.IconButton(
                            tooltip: '清空',
                            icon: const Icon(m.Icons.close),
                            onPressed: () {
                              _inputCtrl.clear();
                              _onQueryChanged('', mode);
                              _inputFocus.requestFocus();
                            },
                          ),
                    filled: true,
                    border: m.OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            if (mode is DynamicSubmode &&
                const {DynamicModeKind.globalSearch, DynamicModeKind.symbolSearch, DynamicModeKind.aiSearch, DynamicModeKind.openPage}.contains(mode.kind))
              _buildChipsRow(mode, theme),
            if (mode is FormSubmode)
              Expanded(child: Padding(padding: const EdgeInsets.all(16), child: _buildFormBody(mode.kind)))
            else if (mode is ConfirmSubmode)
              Flexible(child: SingleChildScrollView(child: _buildConfirmBody(mode)))
            else if (mode is TextInputSubmode)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: m.FilledButton(onPressed: () => _submitText(mode), child: const Text('确认')),
                ),
              )
            else
              Expanded(child: _buildList(items, mode, theme)),
            if (mode is DynamicSubmode && mode.kind == DynamicModeKind.globalSearch && items.isNotEmpty)
              _buildFooter(mode, items, theme),
          ],
        ),
      ),
    );
  }

  KeyEventResult _handleKey(KeyEvent event, PaletteSubmode? mode, List<_PaletteRowItem> items) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isEnter = key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;

    if (key == LogicalKeyboardKey.escape) {
      ref.read(paletteProvider.notifier).close();
      return KeyEventResult.handled;
    }

    if (mode is FormSubmode) return KeyEventResult.ignored;

    if (mode is ConfirmSubmode) {
      if (isEnter) {
        mode.onConfirm(context);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.backspace && _inputCtrl.text.isEmpty && mode != null) {
      ref.read(paletteProvider.notifier).popSubmode();
      return KeyEventResult.handled;
    }

    if (mode is TextInputSubmode) {
      if (isEnter) {
        _submitText(mode);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.tab && mode is DynamicSubmode) {
      // Cycle scope chip on Tab
      setState(() {
        _scope = _scope == SearchScope.currentLibrary ? SearchScope.allLibraries : SearchScope.currentLibrary;
      });
      _rerunDynamic(mode);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown && items.isNotEmpty) {
      setState(() => _selected = (_selected + 1) % items.length);
      _ensureVisible();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && items.isNotEmpty) {
      setState(() => _selected = (_selected - 1 + items.length) % items.length);
      _ensureVisible();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown && items.isNotEmpty) {
      setState(() => _selected = (_selected + 8).clamp(0, items.length - 1));
      _ensureVisible();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp && items.isNotEmpty) {
      setState(() => _selected = (_selected - 8).clamp(0, items.length - 1));
      _ensureVisible();
      return KeyEventResult.handled;
    }
    if (isEnter) {
      if (mode is DynamicSubmode && mode.kind == DynamicModeKind.aiSearch) {
        final q = _inputCtrl.text.trim();
        if (q.isNotEmpty && q != _aiLastQuery) {
          _runAiSearch(q);
          return KeyEventResult.handled;
        }
      }
      if (mode is DynamicSubmode &&
          (mode.kind == DynamicModeKind.globalSearch || mode.kind == DynamicModeKind.symbolSearch)) {
        final q = _inputCtrl.text.trim();
        final lastQ = mode.kind == DynamicModeKind.globalSearch ? _lastGlobalQuery : _lastSymbolQuery;
        if (q.isNotEmpty) {
          if ((_searchDebounce?.isPending ?? false) || (!_searching && q != lastQ)) {
            _searchDebounce?.cancel();
            if (mode.kind == DynamicModeKind.globalSearch) {
              _runGlobalSearch(q);
            } else {
              _runSymbolSearch(q);
            }
            return KeyEventResult.handled;
          }
          if (_searching || q != lastQ) {
            return KeyEventResult.handled;
          }
        }
      }
      if (items.isNotEmpty && _selected < items.length) {
        items[_selected].onActivate?.call();
        return KeyEventResult.handled;
      }
      if (mode is OptionListSubmode && mode.onCustomInput != null) {
        mode.onCustomInput!(context, _inputCtrl.text);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _ensureVisible() {
    if (!_listCtrl.hasClients) return;
    final target = _selected * 42.0;
    final pos = _listCtrl.offset;
    final viewH = _listCtrl.position.viewportDimension;
    if (target < pos) {
      _listCtrl.jumpTo(target);
    } else if (target + 48 > pos + viewH) {
      _listCtrl.jumpTo((target + 48 - viewH).clamp(0, _listCtrl.position.maxScrollExtent));
    }
  }

  void _submitText(TextInputSubmode mode) {
    final v = _inputCtrl.text;
    final err = mode.validator?.call(v);
    if (err != null) {
      setState(() => _inputError = err);
      return;
    }
    mode.onSubmit(context, v);
  }

  void _rerunDynamic(DynamicSubmode mode) {
    final q = _inputCtrl.text;
    switch (mode.kind) {
      case DynamicModeKind.globalSearch:
        _runGlobalSearch(q);
      case DynamicModeKind.symbolSearch:
        _runSymbolSearch(q);
      case DynamicModeKind.aiSearch:
        if (q.trim().isNotEmpty) _runAiSearch(q);
      default:
        setState(() {});
    }
  }

  Widget _buildChipsRow(DynamicSubmode mode, FluentThemeData theme) {
    final curLib = _currentLib();
    final scopeLabel = _scope == SearchScope.currentLibrary
        ? '当前库${curLib != null ? ': ${curLib.name}' : ''}'
        : '全部库';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          _ChipBtn(
            label: scopeLabel,
            active: true,
            onTap: () {
              setState(() {
                _scope = _scope == SearchScope.currentLibrary ? SearchScope.allLibraries : SearchScope.currentLibrary;
              });
              _rerunDynamic(mode);
              _inputFocus.requestFocus();
            },
          ),
          if (mode.kind == DynamicModeKind.globalSearch) ...[
            _ChipBtn(
              label: _caseMode == 'sensitive' ? 'Aa 区分' : (_caseMode == 'ignore' ? 'aa 忽略' : 'Aa 智能'),
              active: _caseMode == 'sensitive',
              onTap: () {
                setState(() {
                  _caseMode = switch (_caseMode) {
                    'smart' => 'sensitive',
                    'sensitive' => 'ignore',
                    _ => 'smart',
                  };
                });
                _rerunDynamic(mode);
                _inputFocus.requestFocus();
              },
            ),
            _ChipBtn(
              label: 'ab 全词',
              active: _wholeWord,
              onTap: () {
                setState(() => _wholeWord = !_wholeWord);
                _rerunDynamic(mode);
                _inputFocus.requestFocus();
              },
            ),
            _ChipBtn(
              label: '.* 正则',
              active: _regex,
              onTap: () {
                setState(() => _regex = !_regex);
                _rerunDynamic(mode);
                _inputFocus.requestFocus();
              },
            ),
          ],
          if (mode.kind == DynamicModeKind.aiSearch)
            _ChipBtn(
              label: 'Enter 检索',
              active: false,
              onTap: () {
                _runAiSearch(_inputCtrl.text);
                _inputFocus.requestFocus();
              },
            ),
        ],
      ),
    );
  }

  List<_PaletteRowItem> _buildItems(PaletteSubmode? mode) {
    final q = _inputCtrl.text.trim();
    if (mode == null) {
      return _buildRootCommands(q);
    }
    if (mode is OptionListSubmode) {
      final out = <_PaletteRowItem>[];
      for (final opt in mode.options) {
        if (q.isNotEmpty && fuzzyScore(q, opt.label, extra: [opt.subtitle ?? '']) <= 0) continue;
        out.add(_PaletteRowItem(
          title: opt.label,
          subtitle: opt.subtitle,
          badge: opt.badge,
          checked: opt.selected,
          colorSwatch: opt.colorSwatch,
          onActivate: () => opt.onSelect(context),
        ));
      }
      if (out.isEmpty && q.isNotEmpty && mode.onCustomInput != null) {
        out.add(_PaletteRowItem(
          title: '使用自定义值：$q',
          onActivate: () => mode.onCustomInput!(context, q),
        ));
      }
      return out;
    }
    if (mode is DynamicSubmode) {
      return switch (mode.kind) {
        DynamicModeKind.globalSearch => _buildGlobalSearchItems(q),
        DynamicModeKind.symbolSearch => _buildSymbolItems(),
        DynamicModeKind.aiSearch => _buildAiSearchItems(q),
        DynamicModeKind.openPage => _buildOpenPageItems(q),
        DynamicModeKind.gotoHeading => _buildGotoHeadingItems(q),
        DynamicModeKind.chatHistory => _buildChatHistoryItems(),
        DynamicModeKind.validationResults => _buildValidationItems(mode.validationSummaries, q),
      };
    }
    return const [];
  }

  List<_PaletteRowItem> _buildRootCommands(String q) {
    final enabledCmds = ref.read(_enabledCommandsProvider);
    if (q.isEmpty) {
      final recentIds = ref.read(paletteProvider.notifier).recentCommandIds;
      final byId = {for (final c in enabledCmds) c.id: c};
      final out = <_PaletteRowItem>[];
      for (final id in recentIds) {
        final cmd = byId[id];
        if (cmd != null) out.add(_cmdRow(cmd, recent: true));
      }
      for (final cmd in enabledCmds) {
        if (recentIds.contains(cmd.id)) continue;
        out.add(_cmdRow(cmd));
      }
      return out;
    }

    final scored = <(AppCommand, int)>[];
    for (final cmd in enabledCmds) {
      final s = fuzzyScore(q, '${cmd.category} ${cmd.title}', extra: [cmd.title, cmd.id, ...cmd.keywords]);
      if (s > 0) scored.add((cmd, s));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final e in scored) _cmdRow(e.$1)];
  }

  _PaletteRowItem _cmdRow(AppCommand cmd, {bool recent = false}) {
    final val = ref.read(_commandCurrentValuesProvider)[cmd.id];
    return _PaletteRowItem(
      category: cmd.category,
      title: cmd.title,
      subtitle: cmd.description,
      badge: val ?? (recent ? '最近使用' : null),
      onActivate: () {
        ref.read(paletteProvider.notifier).recordRecent(cmd.id);
        cmd.run(context, ref);
      },
    );
  }

  _PaletteRowItem _symbolRow(SymbolSearchHit s, String q) {
    final highlightText = s.displayName.isNotEmpty ? s.displayName : q;
    return _PaletteRowItem(
      category: '符号',
      title: s.displayName,
      subtitle: '${s.entry?.kind ?? ''} · ${s.lib.name} / ${s.pageTitle}',
      badge: s.entry?.kind,
      onActivate: () {
        ref.read(paletteProvider.notifier).close();
        ref.read(navigationProvider.notifier).open(
              DocLocation(
                libKey: s.lib.key,
                versionId: s.version.id,
                page: s.page,
                anchor: s.anchor,
                highlight: highlightText.isNotEmpty ? highlightText : null,
              ),
            );
      },
    );
  }

  List<_PaletteRowItem> _buildGlobalSearchItems(String q) {
    final out = <_PaletteRowItem>[];
    if (_rgResult.error != null) {
      out.add(_PaletteRowItem(title: _rgResult.error!, isError: true));
      return out;
    }
    final strongAnchoredSyms = <SymbolSearchHit>[];
    final secondarySyms = <SymbolSearchHit>[];
    for (final s in _symResults) {
      if (s.score >= 700 && s.anchor != null && s.anchor!.isNotEmpty) {
        strongAnchoredSyms.add(s);
      } else {
        secondarySyms.add(s);
      }
    }

    String pageKey(String libKey, String verId, String page) => '$libKey|$verId|$page';
    final coveredPages = <String>{};

    for (final s in strongAnchoredSyms) {
      coveredPages.add(pageKey(s.lib.key, s.version.id, s.page));
      out.add(_symbolRow(s, q));
    }
    // Page-grouped rg hits
    for (final g in _rgResult.groups) {
      coveredPages.add(pageKey(g.lib.key, g.version.id, g.page));
      for (final hit in g.hits.take(3)) {
        final ctxPreview = [
          if (hit.contextBefore.isNotEmpty) hit.contextBefore.last.trim(),
          hit.lineText.trim(),
          if (hit.contextAfter.isNotEmpty) hit.contextAfter.first.trim(),
        ].where((s) => s.isNotEmpty).join('  ');
        out.add(_PaletteRowItem(
          title: '${g.pageTitle} · ${g.lib.name} ${g.version.id}',
          subtitle: 'L${hit.lineNumber}  $ctxPreview',
          badge: '${g.hits.length} 处命中',
          onActivate: () {
            ref.read(paletteProvider.notifier).close();
            ref.read(navigationProvider.notifier).open(
                  DocLocation(
                    libKey: g.lib.key,
                    versionId: g.version.id,
                    page: g.page,
                    line: hit.lineNumber,
                    highlight: q,
                  ),
                );
          },
        ));
      }
    }
    for (final s in secondarySyms) {
      if (coveredPages.contains(pageKey(s.lib.key, s.version.id, s.page))) continue;
      out.add(_symbolRow(s, q));
    }
    // Empty result -> suggest AI Smart Search (FR-GS-06)
    if (out.isEmpty && q.isNotEmpty && !_searching && ref.read(settingsProvider).suggestOnNoResult) {
      out.add(_PaletteRowItem(
        category: 'AI',
        title: '用 AI 智能搜索 "$q"',
        subtitle: '使用关键词改写 + 向量语义混合召回',
        onActivate: () async {
          final ok = await ensureAiReady(context, ref, requireChat: false);
          if (!ok) return;
          ref.read(paletteProvider.notifier).pushSubmode(DynamicSubmode(
                title: 'AI 智能搜索',
                placeholder: '输入自然语言问题，按 Enter 检索…',
                kind: DynamicModeKind.aiSearch,
                initialQuery: q,
                initialScope: _scope,
              ));
        },
      ));
    }
    return out;
  }

  List<_PaletteRowItem> _buildSymbolItems() {
    return [
      for (final s in _symResults)
        _PaletteRowItem(
          title: s.displayName,
          subtitle: s.isCodeFallback
              ? '${s.lib.name} / ${s.pageTitle} · L${s.line ?? 1}'
              : '${s.entry?.signature ?? s.entry?.summary ?? ''} · ${s.lib.name} / ${s.pageTitle}',
          badge: s.isCodeFallback ? '代码匹配' : (s.entry?.kind ?? 'symbol'),
          onActivate: () {
            ref.read(paletteProvider.notifier).close();
            ref.read(navigationProvider.notifier).open(
                  DocLocation(
                    libKey: s.lib.key,
                    versionId: s.version.id,
                    page: s.page,
                    anchor: s.anchor,
                    line: s.line,
                    highlight: _inputCtrl.text.trim(),
                  ),
                );
          },
        ),
    ];
  }

  List<_PaletteRowItem> _buildAiSearchItems(String q) {
    final out = <_PaletteRowItem>[];
    if (_aiResult.vectorNotice != null) {
      out.add(_PaletteRowItem(
        category: '提示',
        title: _aiResult.vectorNotice!,
        subtitle: '点击前往设置配置嵌入模型',
        onActivate: () {
          ref.read(paletteProvider.notifier).close();
          ref.read(navigationProvider.notifier).openSettings(section: 'ai');
        },
      ));
    }
    if (_aiResult.chunks.isNotEmpty) {
      // Pinned top action: let AI answer based on these results (FR-AI-02)
      out.add(_PaletteRowItem(
        category: 'AI 问答',
        title: '让 AI 基于这些结果回答「$_aiLastQuery」',
        subtitle: '打开右侧 AI 面板，带引用流式回答',
        badge: 'Enter',
        onActivate: () async {
          ref.read(paletteProvider.notifier).close();
          final ok = await ensureAiReady(context, ref, requireChat: true);
          if (!ok) return;
          ref.read(aiControllerProvider.notifier).ask(_aiLastQuery, preRetrieved: _aiResult.chunks);
        },
      ));
    }
    for (final ch in _aiResult.chunks) {
      final tags = ch.sources
          .map((s) => switch (s) {
                RetrievalSource.keyword => '关键词',
                RetrievalSource.semantic => '语义',
                RetrievalSource.symbol => '符号',
              })
          .join('+');
      final preview = ch.text.replaceAll('\n', ' ');
      out.add(_PaletteRowItem(
        title: '${ch.pageTitle} · ${ch.breadcrumb}',
        subtitle: '${ch.libName} · ${preview.length > 100 ? '${preview.substring(0, 100)}…' : preview}',
        badge: tags,
        onActivate: () {
          ref.read(paletteProvider.notifier).close();
          ref.read(navigationProvider.notifier).open(
                DocLocation(
                  libKey: ch.libKey,
                  versionId: ch.versionId,
                  page: ch.page,
                  anchor: ch.anchor.isEmpty ? null : ch.anchor,
                ),
              );
        },
      ));
    }
    return out;
  }

  List<_PaletteRowItem> _buildOpenPageItems(String q) {
    final libs = ref.read(libraryProvider).libraries;
    final curLib = _currentLib();
    final targets = (_scope == SearchScope.currentLibrary && curLib != null)
        ? [(curLib, _currentVer(curLib)!)]
        : [for (final l in libs) (l, l.defaultVersion)];

    final scored = <(_PaletteRowItem, int)>[];
    for (final (lib, ver) in targets) {
      for (final pg in ver.orderedPages) {
        final title = ver.titleOf(pg) ?? pg;
        final s = q.isEmpty ? 1 : fuzzyScore(q, title, extra: [pg, lib.name]);
        if (s <= 0) continue;
        scored.add((
          _PaletteRowItem(
            title: title,
            subtitle: '${lib.name} · $pg',
            onActivate: () {
              ref.read(paletteProvider.notifier).close();
              ref.read(navigationProvider.notifier).open(
                    DocLocation(libKey: lib.key, versionId: ver.id, page: pg),
                  );
            },
          ),
          s,
        ));
      }
    }
    if (q.isNotEmpty) scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(60).map((e) => e.$1).toList();
  }

  List<_PaletteRowItem> _buildGotoHeadingItems(String q) {
    final page = ref.read(navigationProvider).page;
    final loc = ref.read(navigationProvider).location;
    if (page == null || loc == null) return const [];
    final out = <_PaletteRowItem>[];
    for (final o in page.doc.outline) {
      if (q.isNotEmpty && fuzzyScore(q, o.text, extra: [o.anchor]) <= 0) continue;
      final indent = '  ' * (o.level - 1).clamp(0, 5);
      out.add(_PaletteRowItem(
        title: '$indent${o.text}',
        badge: 'H${o.level}',
        onActivate: () {
          ref.read(paletteProvider.notifier).close();
          ref.read(navigationProvider.notifier).open(loc.copyWith(anchor: o.anchor));
        },
      ));
    }
    return out;
  }

  List<_PaletteRowItem> _buildChatHistoryItems() {
    return [
      for (final s in _sessions)
        _PaletteRowItem(
          title: s.title,
          subtitle: DateTime.fromMillisecondsSinceEpoch(s.updatedAt).toLocal().toString().substring(0, 16),
          badge: s.scope.all ? '全部库' : '当前库',
          onActivate: () {
            ref.read(paletteProvider.notifier).close();
            ref.read(aiControllerProvider.notifier).loadSession(s);
          },
        ),
    ];
  }

  List<_PaletteRowItem> _buildValidationItems(List<ValidationSummary> summaries, String q) {
    final out = <_PaletteRowItem>[];
    for (final sum in summaries) {
      final lib = ref.read(libraryProvider).byKey(sum.libKey);
      if (sum.issues.isEmpty) {
        out.add(_PaletteRowItem(
          category: '通过',
          title: '${lib?.name ?? sum.libKey}：未发现契约错误或警告',
          badge: 'OK',
        ));
        continue;
      }
      for (final issue in sum.issues) {
        if (q.isNotEmpty &&
            fuzzyScore(q, '${issue.code} ${issue.message}', extra: [issue.page ?? '', issue.file ?? '']) <= 0) {
          continue;
        }
        out.add(_PaletteRowItem(
          category: '${issue.code} ${issue.isError ? '错误' : '警告'}',
          title: issue.message,
          subtitle: '${lib?.name ?? sum.libKey}${issue.page != null ? ' · ${issue.page}' : ''}${issue.line != null ? ':${issue.line}' : ''}',
          isError: issue.isError,
          onActivate: () {
            ref.read(paletteProvider.notifier).close();
            if (lib != null && issue.versionId != null && issue.page != null) {
              ref.read(navigationProvider.notifier).open(
                    DocLocation(libKey: lib.key, versionId: issue.versionId!, page: issue.page!, line: issue.line),
                  );
            } else if (issue.file != null && Platform.isWindows) {
              Process.start('explorer.exe', ['/select,${issue.file!.replaceAll('/', '\\')}'], runInShell: false);
            }
          },
        ));
      }
    }
    return out;
  }

  Widget _buildList(List<_PaletteRowItem> items, PaletteSubmode? mode, FluentThemeData theme) {
    if (items.isEmpty) {
      final msg = _searching
          ? '正在搜索…'
          : (mode is DynamicSubmode && mode.kind == DynamicModeKind.aiSearch && _aiLastQuery.isEmpty)
              ? '输入问题后按 Enter 开始 AI 混合召回'
              : '没有匹配项';
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(msg, style: TextStyle(fontSize: 13, color: theme.resources.textFillColorSecondary))),
      );
    }
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final dark = theme.brightness == Brightness.dark;
    final selBg = dark ? const Color(0x22FFFFFF) : const Color(0x14000000);

    return ListView.builder(
      controller: _listCtrl,
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final it = items[index];
        final isSel = index == _selected;
        return GestureDetector(
          onTap: () {
            setState(() => _selected = index);
            it.onActivate?.call();
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onHover: (event) {
              final prev = _lastPointerPos;
              _lastPointerPos = event.position;
              if (prev != null && (event.position - prev).distanceSquared > 4.0 && _selected != index) {
                setState(() => _selected = index);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isSel ? selBg : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                children: [
                  if (it.checked) ...[
                    Icon(FluentIcons.check_mark, size: 12, color: accent),
                    const SizedBox(width: 8),
                  ],
                  if (it.colorSwatch != null) ...[
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(color: it.colorSwatch, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (it.category != null) ...[
                              Text(
                                '${it.category}: ',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: it.isError ? Colors.red : accent,
                                ),
                              ),
                            ],
                            Expanded(
                              child: Text(
                                it.title,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: it.isError ? Colors.red : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (it.subtitle != null && it.subtitle!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              it.subtitle!,
                              style: TextStyle(fontSize: 11.5, color: theme.resources.textFillColorSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (it.badge != null && it.badge!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: dark ? const Color(0x18FFFFFF) : const Color(0x10000000),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        it.badge!,
                        style: TextStyle(fontSize: 11, color: theme.resources.textFillColorSecondary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFooter(PaletteSubmode? mode, List<_PaletteRowItem> items, FluentThemeData theme) {
    String left = '${items.length} 项';
    if (mode is DynamicSubmode && mode.kind == DynamicModeKind.globalSearch) {
      left = '共 ${_rgResult.totalHits} 处 / ${_rgResult.groups.length} 个页面${_rgResult.truncated ? '（结果过多，已截断）' : ''}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.resources.surfaceStrokeColorDefault)),
      ),
      child: Row(
        children: [
          if (widget.mobile)
            Expanded(child: Text(left, style: TextStyle(fontSize: 12, color: theme.resources.textFillColorSecondary)))
          else ...[
          Text(left, style: TextStyle(fontSize: 11, color: theme.resources.textFillColorSecondary)),
          const Spacer(),
          Text(
            '↑↓ 选择   Enter 确认   ${mode != null ? 'Backspace 返回   ' : ''}Esc 关闭',
            style: TextStyle(fontSize: 11, color: theme.resources.textFillColorSecondary),
          ),
          ],
        ],
      ),
    );
  }

  Widget _buildConfirmBody(ConfirmSubmode mode) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(mode.message, style: const TextStyle(fontSize: 13.5, height: 1.5)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Button(
                onPressed: () => ref.read(paletteProvider.notifier).popSubmode(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => mode.onConfirm(context),
                child: Text(mode.confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFormBody(FormModeKind kind) {
    return switch (kind) {
      FormModeKind.importLibrary => ImportLibraryForm(onClose: () => ref.read(paletteProvider.notifier).close()),
      FormModeKind.aiChat => SingleChildScrollView(
          child: AiModelForm(
            key: const ValueKey('ai-form-chat'),
            isEmbedding: false,
            onSaved: () => ref.read(paletteProvider.notifier).close(),
          ),
        ),
      FormModeKind.aiEmbedding => SingleChildScrollView(
          child: AiModelForm(
            key: const ValueKey('ai-form-embed'),
            isEmbedding: true,
            onSaved: () => ref.read(paletteProvider.notifier).close(),
          ),
        ),
      FormModeKind.shortcuts => _ShortcutsHelp(),
      FormModeKind.about => _AboutHelp(rgPath: ref.read(settingsProvider).rgPath),
    };
  }
}

/// Evaluates enabled commands inside ProviderScope (with proper `Ref`).
final _enabledCommandsProvider = Provider<List<AppCommand>>((ref) {
  // Watch key state that impacts command availability.
  ref.watch(libraryProvider);
  ref.watch(navigationProvider);
  ref.watch(aiControllerProvider);
  ref.watch(settingsProvider);
  final all = ref.watch(commandRegistryProvider);
  return [
    for (final c in all)
      if (c.isEnabled == null || c.isEnabled!(ref)) c,
  ];
});

final _commandCurrentValuesProvider = Provider<Map<String, String?>>((ref) {
  ref.watch(settingsProvider);
  ref.watch(aiControllerProvider);
  final all = ref.watch(commandRegistryProvider);
  return {
    for (final c in all)
      if (c.currentValue != null) c.id: c.currentValue!(ref),
  };
});

class _PaletteRowItem {
  const _PaletteRowItem({
    this.category,
    required this.title,
    this.subtitle,
    this.badge,
    this.checked = false,
    this.colorSwatch,
    this.isError = false,
    this.onActivate,
  });

  final String? category;
  final String title;
  final String? subtitle;
  final String? badge;
  final bool checked;
  final Color? colorSwatch;
  final bool isError;
  final VoidCallback? onActivate;
}

class _ChipBtn extends StatelessWidget {
  const _ChipBtn({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: active ? accent.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: active ? accent : theme.resources.surfaceStrokeColorDefault),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 11.5, color: active ? accent : theme.resources.textFillColorSecondary),
          ),
        ),
      ),
    );
  }
}

class _ShortcutsHelp extends StatelessWidget {
  static const _rows = [
    ('Ctrl+Shift+P', '打开命令面板', '全局'),
    ('Ctrl+F', '在本页查找', '阅读页'),
    ('Enter / Shift+Enter', '下一个 / 上一个匹配', '查找条'),
    ('Ctrl+B', '切换侧边栏', '全局（非输入框）'),
    ('Alt+← / Alt+→', '后退 / 前进', '全局（非输入框）'),
    ('Ctrl+= / Ctrl+- / Ctrl+0', '放大 / 缩小 / 重置字号', '全局'),
    ('Esc', '关闭命令面板 / 查找条 / 对话框', '浮层'),
    ('Enter / Shift+Enter', '发送 / 换行', 'AI 面板输入框'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in _rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 190,
                  child: Text(r.$1, style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.w600, fontSize: 12.5)),
                ),
                Expanded(child: Text(r.$2, style: const TextStyle(fontSize: 13))),
                Text(r.$3, style: TextStyle(fontSize: 11.5, color: FluentTheme.of(context).resources.textFillColorSecondary)),
              ],
            ),
          ),
      ],
    );
  }
}

class _AboutHelp extends StatefulWidget {
  const _AboutHelp({required this.rgPath});
  final String rgPath;

  @override
  State<_AboutHelp> createState() => _AboutHelpState();
}

class _AboutHelpState extends State<_AboutHelp> {
  String? _rg;
  String? _wv2;

  @override
  void initState() {
    super.initState();
    getSearchEngineLabel(widget.rgPath).then((v) {
      if (mounted) setState(() => _rg = v);
    });
    MermaidRenderer.checkWebView2Version().then((v) {
      if (mounted) setState(() => _wv2 = v ?? '未安装（Mermaid 降级显示源码）');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('flDoc 0.1.6', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('全文搜索引擎：${_rg ?? '检测中…'}', style: const TextStyle(fontSize: 12.5)),
        const SizedBox(height: 4),
        if (Platform.isWindows) Text('WebView2：${_wv2 ?? '检测中…'}', style: const TextStyle(fontSize: 12.5)),
        const SizedBox(height: 4),
        SelectableText('数据目录：${AppPaths.instance.supportDir}', style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
