import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/paths.dart';
import '../ai/ai_controller.dart';
import '../ai/index/embed_indexer.dart';
import '../ai/ui/ai_config_guard.dart';
import '../library/android_library_import.dart';
import '../library/library_controller.dart';
import '../library/library_transfer.dart';
import '../library/manifest_generator.dart';
import '../library/models.dart';
import '../library/validator/library_validator.dart';
import '../reader/find/find_controller.dart';
import '../reader/navigation/navigation_controller.dart';
import '../reader/ui/reader_view.dart';
import '../search/models.dart';
import '../settings/settings_controller.dart';

// ------------------------------------------------------------------ Submodes

sealed class PaletteSubmode {
  const PaletteSubmode({required this.title, this.placeholder = ''});
  final String title;
  final String placeholder;
}

class PaletteOption {
  const PaletteOption({
    required this.label,
    this.subtitle,
    this.selected = false,
    this.badge,
    this.colorSwatch,
    required this.onSelect,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final String? badge;
  final Color? colorSwatch;
  final FutureOr<void> Function(BuildContext context) onSelect;
}

class OptionListSubmode extends PaletteSubmode {
  const OptionListSubmode({
    required super.title,
    super.placeholder = '输入过滤选项…',
    required this.options,
    this.onCustomInput,
    this.customInputHint,
  });

  final List<PaletteOption> options;
  final FutureOr<bool> Function(BuildContext context, String raw)? onCustomInput;
  final String? customInputHint;
}

class TextInputSubmode extends PaletteSubmode {
  const TextInputSubmode({
    required super.title,
    required super.placeholder,
    this.initialValue = '',
    this.hint,
    this.validator,
    required this.onSubmit,
  });

  final String initialValue;
  final String? hint;
  final String? Function(String value)? validator;
  final FutureOr<void> Function(BuildContext context, String value) onSubmit;
}

enum DynamicModeKind {
  globalSearch,
  symbolSearch,
  aiSearch,
  openPage,
  gotoHeading,
  chatHistory,
  validationResults,
}

class DynamicSubmode extends PaletteSubmode {
  const DynamicSubmode({
    required super.title,
    required super.placeholder,
    required this.kind,
    this.initialQuery = '',
    this.initialScope = SearchScope.currentLibrary,
    this.validationSummaries = const [],
  });

  final DynamicModeKind kind;
  final String initialQuery;
  final SearchScope initialScope;
  final List<ValidationSummary> validationSummaries;
}

enum FormModeKind { importLibrary, aiChat, aiEmbedding, shortcuts, about }

class FormSubmode extends PaletteSubmode {
  const FormSubmode({required super.title, required this.kind});
  final FormModeKind kind;
}

class ConfirmSubmode extends PaletteSubmode {
  const ConfirmSubmode({
    required super.title,
    required this.message,
    this.confirmLabel = '确认',
    this.destructive = false,
    required this.onConfirm,
  });

  final String message;
  final String confirmLabel;
  final bool destructive;
  final FutureOr<void> Function(BuildContext context) onConfirm;
}

// ------------------------------------------------------------------ Command

class AppCommand {
  const AppCommand({
    required this.id,
    required this.category,
    required this.title,
    this.description,
    this.keywords = const [],
    this.currentValue,
    this.isEnabled,
    required this.run,
  });

  final String id;
  final String category;
  final String title;
  final String? description;
  final List<String> keywords;
  final String? Function(Ref ref)? currentValue;
  final bool Function(Ref ref)? isEnabled;
  final FutureOr<void> Function(BuildContext context, WidgetRef ref) run;

  String get fullLabel => '$category: $title';
}

// ------------------------------------------------------------------ Palette State & Controller

class PaletteState {
  const PaletteState({
    this.open = false,
    this.stack = const [],
    this.showOobe = false,
  });

  final bool open;
  final List<PaletteSubmode> stack;
  final bool showOobe;

  PaletteSubmode? get activeSubmode => stack.isEmpty ? null : stack.last;

  PaletteState copyWith({bool? open, List<PaletteSubmode>? stack, bool? showOobe}) => PaletteState(
        open: open ?? this.open,
        stack: stack ?? this.stack,
        showOobe: showOobe ?? this.showOobe,
      );
}

final paletteProvider = NotifierProvider<PaletteController, PaletteState>(PaletteController.new);

class PaletteController extends Notifier<PaletteState> {
  @override
  PaletteState build() {
    final oobeDone = ref.read(settingsProvider).oobeCompleted;
    return PaletteState(showOobe: !oobeDone && !Platform.isAndroid);
  }

  void openRoot() => state = state.copyWith(open: true, stack: const []);

  void openSubmode(PaletteSubmode mode) => state = state.copyWith(open: true, stack: [mode]);

  void pushSubmode(PaletteSubmode mode) => state = state.copyWith(open: true, stack: [...state.stack, mode]);

  void popSubmode() {
    if (state.stack.isEmpty) {
      close();
    } else {
      state = state.copyWith(stack: state.stack.sublist(0, state.stack.length - 1));
    }
  }

  void close() => state = state.copyWith(open: false, stack: const []);

  void openOobe() => state = state.copyWith(open: false, stack: const [], showOobe: true);

  void closeOobe() => state = state.copyWith(showOobe: false);

  void recordRecent(String commandId) {
    final ui = ref.read(uiStateProvider);
    final recent = List<String>.of(ui.recentCommands)..remove(commandId);
    recent.insert(0, commandId);
    if (recent.length > 5) recent.removeRange(5, recent.length);
    ui.recentCommands = recent;
  }

  List<String> get recentCommandIds => ref.read(uiStateProvider).recentCommands;
}

// ------------------------------------------------------------------ Registry (All 60 commands from doc 05)

final commandRegistryProvider = Provider<List<AppCommand>>((ref) => buildAllCommands(ref));

List<AppCommand> buildAllCommands(Ref providerRef) {
  void openInShell(String path) {
    if (!Platform.isWindows) return;
    final winPath = path.replaceAll('/', '\\');
    if (Directory(winPath).existsSync()) {
      Process.start('explorer.exe', [winPath], runInShell: false);
    } else {
      Process.start('cmd.exe', ['/c', 'start', '', winPath], runInShell: false);
    }
  }

  AppCommand boolOptionCmd({
    required String id,
    required String category,
    required String title,
    required String settingPath,
    String? description,
    List<String> keywords = const [],
  }) {
    return AppCommand(
      id: id,
      category: category,
      title: title,
      description: description,
      keywords: keywords,
      currentValue: (r) => (r.read(settingsProvider).get(settingPath) == true) ? '开' : '关',
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).get(settingPath) == true;
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: title,
              options: [
                PaletteOption(
                  label: '开',
                  selected: cur,
                  onSelect: (_) {
                    ref.read(settingsProvider.notifier).set(settingPath, true);
                    ref.read(paletteProvider.notifier).close();
                  },
                ),
                PaletteOption(
                  label: '关',
                  selected: !cur,
                  onSelect: (_) {
                    ref.read(settingsProvider.notifier).set(settingPath, false);
                    ref.read(paletteProvider.notifier).close();
                  },
                ),
              ],
            ));
      },
    );
  }

  return [
    // ======================== 2.1 导航 (9) ========================
    AppCommand(
      id: 'nav.home',
      category: '导航',
      title: '返回 Home',
      keywords: ['home', '首页', '总览'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        ref.read(navigationProvider.notifier).goHome();
      },
    ),
    AppCommand(
      id: 'nav.openPage',
      category: '导航',
      title: '打开页面',
      description: '按标题模糊查找文档页面',
      keywords: ['open', 'page', '文档'],
      isEnabled: (r) => r.read(libraryProvider).libraries.isNotEmpty,
      run: (ctx, ref) {
        final defScope = ref.read(settingsProvider).defaultScope == 'allLibraries'
            ? SearchScope.allLibraries
            : SearchScope.currentLibrary;
        ref.read(paletteProvider.notifier).pushSubmode(DynamicSubmode(
              title: '打开页面',
              placeholder: '输入页面标题或路径…',
              kind: DynamicModeKind.openPage,
              initialScope: defScope,
            ));
      },
    ),
    AppCommand(
      id: 'nav.gotoHeading',
      category: '导航',
      title: '跳转到标题',
      description: '当前页大纲导航',
      keywords: ['outline', 'heading', '目录', '大纲'],
      isEnabled: (r) => r.read(navigationProvider).view == AppView.reader && r.read(navigationProvider).page != null,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(const DynamicSubmode(
              title: '跳转到标题',
              placeholder: '输入标题关键词…',
              kind: DynamicModeKind.gotoHeading,
            ));
      },
    ),
    AppCommand(
      id: 'nav.back',
      category: '导航',
      title: '后退',
      keywords: ['back', '返回'],
      isEnabled: (r) => r.read(navigationProvider).canBack,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        ref.read(navigationProvider.notifier).back();
      },
    ),
    AppCommand(
      id: 'nav.forward',
      category: '导航',
      title: '前进',
      keywords: ['forward'],
      isEnabled: (r) => r.read(navigationProvider).canForward,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        ref.read(navigationProvider.notifier).forward();
      },
    ),
    AppCommand(
      id: 'nav.switchLibrary',
      category: '导航',
      title: '切换文档库',
      keywords: ['library', 'switch'],
      isEnabled: (r) => r.read(libraryProvider).libraries.isNotEmpty,
      run: (ctx, ref) {
        final libs = ref.read(libraryProvider).libraries;
        final curKey = ref.read(navigationProvider).location?.libKey;
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '切换文档库',
              options: [
                for (final l in libs)
                  PaletteOption(
                    label: l.name,
                    subtitle: '${l.pageCount} 页 · ${l.versions.length} 版本',
                    selected: l.key == curKey,
                    onSelect: (_) {
                      ref.read(paletteProvider.notifier).close();
                      ref.read(navigationProvider.notifier).openLibrary(l);
                    },
                  ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'nav.switchVersion',
      category: '导航',
      title: '切换版本',
      keywords: ['version'],
      isEnabled: (r) {
        final loc = r.read(navigationProvider).location;
        if (loc == null) return false;
        final lib = r.read(libraryProvider).byKey(loc.libKey);
        return lib != null && lib.versions.length > 1;
      },
      run: (ctx, ref) {
        final loc = ref.read(navigationProvider).location!;
        final lib = ref.read(libraryProvider).byKey(loc.libKey)!;
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '切换版本（${lib.name}）',
              options: [
                for (final v in lib.versions)
                  PaletteOption(
                    label: v.label,
                    subtitle: '${v.orderedPages.length} 页',
                    selected: v.id == loc.versionId,
                    onSelect: (_) {
                      ref.read(paletteProvider.notifier).close();
                      ref.read(navigationProvider.notifier).switchVersion(v.id);
                    },
                  ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'nav.openSource',
      category: '导航',
      title: '在浏览器中打开原网页',
      keywords: ['browser', 'source', 'url'],
      isEnabled: (r) => (r.read(navigationProvider).page?.sourceUrl ?? '').isNotEmpty,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        final url = ref.read(navigationProvider).page?.sourceUrl;
        if (url != null) {
          final uri = Uri.tryParse(url);
          if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
            launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        }
      },
    ),
    AppCommand(
      id: 'nav.copySourceUrl',
      category: '导航',
      title: '复制原网页链接',
      keywords: ['copy', 'url'],
      isEnabled: (r) => (r.read(navigationProvider).page?.sourceUrl ?? '').isNotEmpty,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        final url = ref.read(navigationProvider).page?.sourceUrl;
        if (url != null) {
          Clipboard.setData(ClipboardData(text: url));
          ref.read(noticeProvider.notifier).show('已复制原网页链接');
        }
      },
    ),

    // ======================== 2.2 搜索 (4) ========================
    AppCommand(
      id: 'search.global',
      category: '搜索',
      title: '全局搜索',
      description: '离线检索文档正文、标题与代码',
      keywords: ['search', 'rg', 'ripgrep', 'grep', '全文'],
      run: (ctx, ref) {
        final defScope = ref.read(settingsProvider).defaultScope == 'allLibraries'
            ? SearchScope.allLibraries
            : SearchScope.currentLibrary;
        ref.read(paletteProvider.notifier).pushSubmode(DynamicSubmode(
              title: '全局搜索',
              placeholder: '输入关键词实时搜索…',
              kind: DynamicModeKind.globalSearch,
              initialScope: defScope,
            ));
      },
    ),
    AppCommand(
      id: 'search.symbol',
      category: '搜索',
      title: '搜索符号/函数',
      description: '基于 symbols.json 索引 + 代码块正则兜底',
      keywords: ['symbol', 'function', 'api', 'class', '方法'],
      run: (ctx, ref) {
        final defScope = ref.read(settingsProvider).defaultScope == 'allLibraries'
            ? SearchScope.allLibraries
            : SearchScope.currentLibrary;
        ref.read(paletteProvider.notifier).pushSubmode(DynamicSubmode(
              title: '搜索符号/函数',
              placeholder: '输入类名、函数名或驼峰缩写（如 PS）…',
              kind: DynamicModeKind.symbolSearch,
              initialScope: defScope,
            ));
      },
    ),
    AppCommand(
      id: 'search.findInPage',
      category: '搜索',
      title: '在本页查找',
      description: 'Ctrl+F',
      keywords: ['find', 'ctrl+f'],
      isEnabled: (r) => r.read(navigationProvider).view == AppView.reader && r.read(navigationProvider).page != null,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        final sel = ref.read(readerSelectionProvider).trim();
        ref.read(findProvider.notifier).open(initial: sel.isNotEmpty && !sel.contains('\n') ? sel : null);
      },
    ),
    AppCommand(
      id: 'search.ai',
      category: '搜索',
      title: 'AI 智能搜索',
      description: '关键词改写 + 向量语义 + 符号混合召回',
      keywords: ['ai', 'semantic', 'vector', '语义', '混合'],
      run: (ctx, ref) async {
        ref.read(paletteProvider.notifier).close();
        final ok = await ensureAiReady(ctx, ref, requireChat: false);
        if (!ok) return;
        final defScope = ref.read(settingsProvider).defaultScope == 'allLibraries'
            ? SearchScope.allLibraries
            : SearchScope.currentLibrary;
        ref.read(paletteProvider.notifier).openSubmode(DynamicSubmode(
              title: 'AI 智能搜索',
              placeholder: '输入自然语言问题，按 Enter 执行混合检索…',
              kind: DynamicModeKind.aiSearch,
              initialScope: defScope,
            ));
      },
    ),

    // ======================== 2.3 AI (6) ========================
    AppCommand(
      id: 'ai.ask',
      category: 'AI',
      title: '提问',
      description: '打开 AI 面板并基于文档库回答',
      keywords: ['ask', 'rag', 'chat', '问答'],
      run: (ctx, ref) async {
        final ok = await ensureAiReady(ctx, ref, requireChat: true);
        if (!ok) return;
        ref.read(paletteProvider.notifier).pushSubmode(TextInputSubmode(
              title: 'AI 提问',
              placeholder: '输入你的问题，按 Enter 发送…',
              onSubmit: (c, value) {
                if (value.trim().isEmpty) return;
                ref.read(paletteProvider.notifier).close();
                ref.read(aiControllerProvider.notifier).ask(value.trim());
              },
            ));
      },
    ),
    AppCommand(
      id: 'ai.togglePanel',
      category: 'AI',
      title: '显示/隐藏 AI 面板',
      keywords: ['panel', 'chat', 'toggle'],
      currentValue: (r) => r.read(aiControllerProvider).visible ? '已显示' : '已隐藏',
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        ref.read(aiControllerProvider.notifier).togglePanel();
      },
    ),
    AppCommand(
      id: 'ai.newChat',
      category: 'AI',
      title: '新建对话',
      keywords: ['new', 'chat'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        ref.read(aiControllerProvider.notifier)
          ..setVisible(true)
          ..newChat();
      },
    ),
    AppCommand(
      id: 'ai.history',
      category: 'AI',
      title: '历史对话',
      description: '查看并继续已保存的 AI 对话',
      keywords: ['history', 'sessions'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(const DynamicSubmode(
              title: '历史对话',
              placeholder: '按标题或内容过滤历史对话…',
              kind: DynamicModeKind.chatHistory,
            ));
      },
    ),
    AppCommand(
      id: 'ai.deleteChat',
      category: 'AI',
      title: '删除当前对话',
      keywords: ['delete', 'remove'],
      isEnabled: (r) => r.read(aiControllerProvider).session != null,
      run: (ctx, ref) {
        final title = ref.read(aiControllerProvider).session?.title ?? '当前对话';
        ref.read(paletteProvider.notifier).pushSubmode(ConfirmSubmode(
              title: '删除当前对话',
              message: '确定要删除会话「$title」吗？此操作不可撤销。',
              confirmLabel: '删除',
              destructive: true,
              onConfirm: (_) {
                ref.read(aiControllerProvider.notifier).deleteCurrentSession();
                ref.read(paletteProvider.notifier).close();
                ref.read(noticeProvider.notifier).show('已删除对话');
              },
            ));
      },
    ),
    AppCommand(
      id: 'ai.askAboutPage',
      category: 'AI',
      title: '就当前页提问',
      description: '检索范围优先当前阅读页面',
      keywords: ['page', 'ask'],
      isEnabled: (r) => r.read(navigationProvider).view == AppView.reader && r.read(navigationProvider).location != null,
      run: (ctx, ref) async {
        final ok = await ensureAiReady(ctx, ref, requireChat: true);
        if (!ok) return;
        final loc = ref.read(navigationProvider).location!;
        final title = ref.read(navigationProvider).page?.title ?? loc.page;
        ref.read(paletteProvider.notifier).pushSubmode(TextInputSubmode(
              title: '就当前页提问（$title）',
              placeholder: '输入关于本页的问题，按 Enter 发送…',
              onSubmit: (c, value) {
                if (value.trim().isEmpty) return;
                ref.read(paletteProvider.notifier).close();
                ref.read(aiControllerProvider.notifier)
                  ..newChat(focusPage: loc)
                  ..ask(value.trim(), focusPage: loc);
              },
            ));
      },
    ),

    // ======================== 2.4 视图与阅读 (7) ========================
    AppCommand(
      id: 'view.toggleSidebar',
      category: '视图',
      title: '切换侧边栏',
      description: 'Ctrl+B',
      keywords: ['sidebar', 'toggle'],
      currentValue: (r) => r.read(settingsProvider).sidebarVisible ? '展开' : '收起',
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        ref.read(settingsProvider.notifier).toggle('sidebar.visible');
      },
    ),
    AppCommand(
      id: 'view.sidebarCollapsedMode',
      category: '视图',
      title: '侧边栏收起形态',
      keywords: ['sidebar', 'icon'],
      currentValue: (r) => r.read(settingsProvider).sidebarCollapsedMode == 'iconBar' ? '图标栏' : '完全隐藏',
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).sidebarCollapsedMode;
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '侧边栏收起形态',
              options: [
                PaletteOption(
                  label: '完全隐藏',
                  subtitle: '收起后只保留正文区',
                  selected: cur == 'hidden',
                  onSelect: (_) {
                    ref.read(settingsProvider.notifier).set('sidebar.collapsedMode', 'hidden');
                    ref.read(paletteProvider.notifier).close();
                  },
                ),
                PaletteOption(
                  label: '图标栏',
                  subtitle: '收起后保留左侧窄图标栏',
                  selected: cur == 'iconBar',
                  onSelect: (_) {
                    ref.read(settingsProvider.notifier).set('sidebar.collapsedMode', 'iconBar');
                    ref.read(paletteProvider.notifier).close();
                  },
                ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'reading.toggleLanguage',
      category: '阅读',
      title: '切换中文/原文',
      keywords: ['language', 'en', 'zh', '翻译'],
      currentValue: (r) => r.read(settingsProvider).language == 'original' ? '原文' : '中文',
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).language;
        final next = cur == 'zh' ? 'original' : 'zh';
        ref.read(settingsProvider.notifier).set('reading.language', next);
        ref.read(paletteProvider.notifier).close();
        ref.read(noticeProvider.notifier).show(next == 'original' ? '已切换为原文' : '已切换为中文');
      },
    ),
    AppCommand(
      id: 'reading.zoomIn',
      category: '阅读',
      title: '放大字号',
      description: 'Ctrl+=',
      keywords: ['zoom', 'font'],
      currentValue: (r) => '${(r.read(settingsProvider).fontScale * 100).round()}%',
      run: (ctx, ref) {
        final next = (ref.read(settingsProvider).fontScale + 0.1).clamp(0.6, 2.0);
        ref.read(settingsProvider.notifier).set('reading.fontScale', double.parse(next.toStringAsFixed(2)));
        ref.read(paletteProvider.notifier).close();
      },
    ),
    AppCommand(
      id: 'reading.zoomOut',
      category: '阅读',
      title: '缩小字号',
      description: 'Ctrl+-',
      keywords: ['zoom', 'font'],
      currentValue: (r) => '${(r.read(settingsProvider).fontScale * 100).round()}%',
      run: (ctx, ref) {
        final next = (ref.read(settingsProvider).fontScale - 0.1).clamp(0.6, 2.0);
        ref.read(settingsProvider.notifier).set('reading.fontScale', double.parse(next.toStringAsFixed(2)));
        ref.read(paletteProvider.notifier).close();
      },
    ),
    AppCommand(
      id: 'reading.zoomReset',
      category: '阅读',
      title: '重置字号',
      description: 'Ctrl+0',
      keywords: ['zoom', 'reset'],
      run: (ctx, ref) {
        ref.read(settingsProvider.notifier).set('reading.fontScale', 1.0);
        ref.read(paletteProvider.notifier).close();
      },
    ),
    boolOptionCmd(
      id: 'reading.rememberPosition',
      category: '阅读',
      title: '记住阅读位置',
      settingPath: 'reading.rememberPosition',
      keywords: ['position', 'scroll'],
    ),

    // ======================== 2.5 窗口 (6) ========================
    AppCommand(
      id: 'window.toggleAlwaysOnTop',
      category: '窗口',
      title: '切换置顶',
      keywords: ['pin', 'topmost', 'always'],
      currentValue: (r) => r.read(settingsProvider).alwaysOnTop ? '已置顶' : '未置顶',
      run: (ctx, ref) {
        ref.read(settingsProvider.notifier).toggle('window.alwaysOnTop');
        ref.read(paletteProvider.notifier).close();
      },
    ),
    AppCommand(
      id: 'window.opacity',
      category: '窗口',
      title: '设置透明度',
      keywords: ['opacity', 'alpha', '透明'],
      currentValue: (r) => '${(r.read(settingsProvider).opacity * 100).round()}%',
      run: (ctx, ref) {
        final cur = (ref.read(settingsProvider).opacity * 100).round();
        ref.read(paletteProvider.notifier).pushSubmode(TextInputSubmode(
              title: '设置窗口透明度（30–100）',
              placeholder: '输入百分比，如 90',
              initialValue: '$cur',
              hint: '允许范围：30 到 100',
              validator: (v) {
                final n = int.tryParse(v.trim());
                if (n == null || n < 30 || n > 100) return '请输入 30 到 100 之间的整数';
                return null;
              },
              onSubmit: (_, v) {
                final n = int.parse(v.trim());
                ref.read(settingsProvider.notifier).set('window.opacity', double.parse((n / 100).toStringAsFixed(2)));
                ref.read(paletteProvider.notifier).close();
              },
            ));
      },
    ),
    boolOptionCmd(
      id: 'window.closeToTray',
      category: '窗口',
      title: '关闭时最小化到托盘',
      settingPath: 'window.closeToTray',
      keywords: ['tray', 'close'],
    ),
    boolOptionCmd(
      id: 'window.launchAtStartup',
      category: '窗口',
      title: '开机自启',
      settingPath: 'window.launchAtStartup',
      keywords: ['startup', 'boot'],
    ),
    AppCommand(
      id: 'window.resetBounds',
      category: '窗口',
      title: '重置窗口位置与大小',
      keywords: ['bounds', 'center', 'reset'],
      run: (ctx, ref) {
        ref.read(windowServiceProvider)?.resetBounds();
        ref.read(paletteProvider.notifier).close();
        ref.read(noticeProvider.notifier).show('已重置窗口位置与大小');
      },
    ),
    AppCommand(
      id: 'app.quit',
      category: '应用',
      title: '退出 flDoc',
      keywords: ['quit', 'exit'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        final ws = ref.read(windowServiceProvider);
        if (ws != null) {
          ws.quit();
        } else {
          exit(0);
        }
      },
    ),

    // ======================== 2.6 首选项 (17) ========================
    AppCommand(
      id: 'pref.theme',
      category: '首选项',
      title: '颜色主题',
      keywords: ['theme', 'dark', 'light'],
      currentValue: (r) => switch (r.read(settingsProvider).theme) {
            'light' => '亮色',
            'dark' => '暗色',
            _ => '跟随系统',
          },
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).theme;
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '颜色主题',
              options: [
                for (final e in const [('system', '跟随系统'), ('light', '亮色'), ('dark', '暗色')])
                  PaletteOption(
                    label: e.$2,
                    selected: cur == e.$1,
                    onSelect: (_) {
                      ref.read(settingsProvider.notifier).set('appearance.theme', e.$1);
                      ref.read(paletteProvider.notifier).close();
                    },
                  ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'pref.accentColor',
      category: '首选项',
      title: '强调色',
      keywords: ['accent', 'color'],
      currentValue: (r) => r.read(settingsProvider).accentColor,
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).accentColor.toUpperCase();
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '强调色',
              placeholder: '选择预设色或输入 #RRGGBB 回车…',
              customInputHint: '直接输入十六进制颜色（如 #0078D4）按 Enter 应用',
              options: [
                for (final e in accentPresets.entries)
                  PaletteOption(
                    label: '${e.value} (${e.key})',
                    selected: cur == e.key,
                    colorSwatch: parseHexColor(e.key),
                    onSelect: (_) {
                      ref.read(settingsProvider.notifier).set('appearance.accentColor', e.key);
                      ref.read(paletteProvider.notifier).close();
                    },
                  ),
              ],
              onCustomInput: (_, raw) {
                final t = raw.trim();
                if (RegExp(r'^#?[0-9A-Fa-f]{6}$').hasMatch(t)) {
                  final hex = t.startsWith('#') ? t.toUpperCase() : '#${t.toUpperCase()}';
                  ref.read(settingsProvider.notifier).set('appearance.accentColor', hex);
                  ref.read(paletteProvider.notifier).close();
                  return true;
                }
                return false;
              },
            ));
      },
    ),
    AppCommand(
      id: 'pref.bodyFont',
      category: '首选项',
      title: '正文字体',
      keywords: ['font', 'body'],
      currentValue: (r) => r.read(settingsProvider).bodyFont,
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).bodyFont;
        const fonts = ['Microsoft YaHei UI', 'Segoe UI', 'Microsoft YaHei', 'Sarasa UI SC', 'PingFang SC', 'SimSun'];
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '正文字体',
              placeholder: '选择或输入任意已安装字体名…',
              options: [
                for (final f in fonts)
                  PaletteOption(
                    label: f,
                    selected: cur == f,
                    onSelect: (_) {
                      ref.read(settingsProvider.notifier).set('appearance.bodyFont', f);
                      ref.read(paletteProvider.notifier).close();
                    },
                  ),
              ],
              onCustomInput: (_, raw) {
                if (raw.trim().isEmpty) return false;
                ref.read(settingsProvider.notifier).set('appearance.bodyFont', raw.trim());
                ref.read(paletteProvider.notifier).close();
                return true;
              },
            ));
      },
    ),
    AppCommand(
      id: 'pref.codeFont',
      category: '首选项',
      title: '代码字体',
      keywords: ['font', 'code', 'mono'],
      currentValue: (r) => r.read(settingsProvider).codeFont,
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).codeFont;
        const fonts = ['Cascadia Code', 'Cascadia Mono', 'Consolas', 'JetBrains Mono', 'Fira Code', 'Courier New'];
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '代码字体',
              placeholder: '选择或输入任意等宽字体名…',
              options: [
                for (final f in fonts)
                  PaletteOption(
                    label: f,
                    selected: cur == f,
                    onSelect: (_) {
                      ref.read(settingsProvider.notifier).set('appearance.codeFont', f);
                      ref.read(paletteProvider.notifier).close();
                    },
                  ),
              ],
              onCustomInput: (_, raw) {
                if (raw.trim().isEmpty) return false;
                ref.read(settingsProvider.notifier).set('appearance.codeFont', raw.trim());
                ref.read(paletteProvider.notifier).close();
                return true;
              },
            ));
      },
    ),
    AppCommand(
      id: 'pref.fontSize',
      category: '首选项',
      title: '基础字号',
      keywords: ['font', 'size'],
      currentValue: (r) => '${r.read(settingsProvider).fontSize.round()} px',
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(TextInputSubmode(
              title: '基础字号（11–28）',
              placeholder: '输入字号，如 15',
              initialValue: '${ref.read(settingsProvider).fontSize.round()}',
              validator: (v) {
                final n = int.tryParse(v.trim());
                if (n == null || n < 11 || n > 28) return '请输入 11 到 28 之间的整数';
                return null;
              },
              onSubmit: (_, v) {
                ref.read(settingsProvider.notifier).set('appearance.fontSize', int.parse(v.trim()));
                ref.read(paletteProvider.notifier).close();
              },
            ));
      },
    ),
    AppCommand(
      id: 'pref.contentMaxWidth',
      category: '首选项',
      title: '正文行宽',
      keywords: ['width', 'line'],
      currentValue: (r) {
        final w = r.read(settingsProvider).contentMaxWidth;
        return w <= 0 ? '不限' : '$w px';
      },
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).contentMaxWidth;
        ref.read(paletteProvider.notifier).pushSubmode(TextInputSubmode(
              title: '正文最大行宽（480–1600，或输入 0 / 不限）',
              placeholder: '输入像素值或「不限」',
              initialValue: cur <= 0 ? '不限' : '$cur',
              validator: (v) {
                final t = v.trim();
                if (t == '0' || t == '不限') return null;
                final n = int.tryParse(t);
                if (n == null || n < 480 || n > 1600) return '请输入 480 到 1600 之间的整数，或输入「不限」';
                return null;
              },
              onSubmit: (_, v) {
                final t = v.trim();
                final val = (t == '0' || t == '不限') ? 0 : int.parse(t);
                ref.read(settingsProvider.notifier).set('appearance.contentMaxWidth', val);
                ref.read(paletteProvider.notifier).close();
              },
            ));
      },
    ),
    AppCommand(
      id: 'pref.searchScope',
      category: '首选项',
      title: '全局搜索默认范围',
      keywords: ['search', 'scope'],
      currentValue: (r) => r.read(settingsProvider).defaultScope == 'allLibraries' ? '全部库' : '当前库',
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).defaultScope;
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '全局搜索默认范围',
              options: [
                PaletteOption(
                  label: '当前库',
                  selected: cur != 'allLibraries',
                  onSelect: (_) {
                    ref.read(settingsProvider.notifier).set('search.defaultScope', 'currentLibrary');
                    ref.read(paletteProvider.notifier).close();
                  },
                ),
                PaletteOption(
                  label: '全部库',
                  selected: cur == 'allLibraries',
                  onSelect: (_) {
                    ref.read(settingsProvider.notifier).set('search.defaultScope', 'allLibraries');
                    ref.read(paletteProvider.notifier).close();
                  },
                ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'pref.searchCase',
      category: '首选项',
      title: '搜索大小写',
      keywords: ['case', 'search'],
      currentValue: (r) => switch (r.read(settingsProvider).caseMode) {
            'sensitive' => '区分',
            'ignore' => '忽略',
            _ => '智能',
          },
      run: (ctx, ref) {
        final cur = ref.read(settingsProvider).caseMode;
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '搜索大小写',
              options: [
                for (final e in const [('smart', '智能'), ('sensitive', '区分'), ('ignore', '忽略')])
                  PaletteOption(
                    label: e.$2,
                    selected: cur == e.$1,
                    onSelect: (_) {
                      ref.read(settingsProvider.notifier).set('search.caseMode', e.$1);
                      ref.read(paletteProvider.notifier).close();
                    },
                  ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'pref.rgPath',
      category: '首选项',
      title: 'ripgrep 路径',
      keywords: ['rg', 'ripgrep', 'path'],
      isEnabled: (_) => !Platform.isAndroid,
      currentValue: (r) => r.read(settingsProvider).rgPath.isEmpty ? '内置' : r.read(settingsProvider).rgPath,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(TextInputSubmode(
              title: 'ripgrep 路径（留空使用内置程序）',
              placeholder: Platform.isWindows ? '例如 C:\\tools\\rg.exe' : '例如 /opt/homebrew/bin/rg',
              initialValue: ref.read(settingsProvider).rgPath,
              onSubmit: (_, v) {
                ref.read(settingsProvider.notifier).set('search.rgPath', v.trim());
                ref.read(paletteProvider.notifier).close();
              },
            ));
      },
    ),
    AppCommand(
      id: 'pref.aiChat',
      category: '首选项',
      title: '配置对话模型',
      keywords: ['ai', 'chat', 'llm', 'openai', 'api'],
      currentValue: (r) => r.read(settingsProvider).chatModel.isEmpty ? '未配置' : r.read(settingsProvider).chatModel,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(const FormSubmode(
              title: '配置对话模型',
              kind: FormModeKind.aiChat,
            ));
      },
    ),
    AppCommand(
      id: 'pref.aiEmbedding',
      category: '首选项',
      title: '配置嵌入模型',
      keywords: ['ai', 'embedding', 'bge', 'siliconflow', '向量'],
      currentValue: (r) => r.read(settingsProvider).embedModel,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(const FormSubmode(
              title: '配置嵌入模型',
              kind: FormModeKind.aiEmbedding,
            ));
      },
    ),
    boolOptionCmd(
      id: 'pref.aiSuggest',
      category: '首选项',
      title: '无结果时提示 AI 搜索',
      settingPath: 'ai.suggestOnNoResult',
      keywords: ['ai', 'suggest'],
    ),
    boolOptionCmd(
      id: 'pref.aiSaveHistory',
      category: '首选项',
      title: '保存 AI 会话历史',
      settingPath: 'ai.rag.saveHistory',
      keywords: ['ai', 'history'],
    ),
    AppCommand(
      id: 'pref.openSettings',
      category: '首选项',
      title: '打开设置',
      keywords: ['settings', 'setting', 'preferences', 'config', '设置'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        ref.read(navigationProvider.notifier).openSettings();
      },
    ),
    AppCommand(
      id: 'pref.rerunOobe',
      category: '首选项',
      title: '重新运行初始设置向导',
      keywords: ['oobe', 'wizard', 'guide'],
      run: (ctx, ref) => ref.read(paletteProvider.notifier).openOobe(),
    ),

    // ======================== 2.7 文档库 ========================
    AppCommand(
      id: 'library.import',
      category: '文档库',
      title: '从网站制作文档库',
      description: '填写参数生成 Agent 爬取提示词并复制到剪贴板',
      keywords: ['import', 'crawl', 'prompt', '抓取'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(const FormSubmode(
              title: '从网站制作文档库',
              kind: FormModeKind.importLibrary,
            ));
      },
    ),
    AppCommand(
      id: 'library.importPackage',
      category: '文档库',
      title: '导入资料包',
      description: '从 .fldoc.zip 导入文档库',
      keywords: ['import', 'package', 'zip', '导入文档库'],
      run: (ctx, ref) {
        final transfer = ref.read(libraryTransferProvider);
        ref.read(paletteProvider.notifier).close();
        return transfer.importPackage();
      },
    ),
    for (final share in [false, true])
      AppCommand(
        id: share ? 'library.sharePackage' : 'library.exportPackage',
        category: '文档库',
        title: share ? '分享资料包' : '导出资料包',
        keywords: [share ? 'share' : 'export', 'package', 'zip'],
        isEnabled: (r) => r.read(libraryProvider).libraries.isNotEmpty,
        run: (ctx, ref) {
          final transfer = ref.read(libraryTransferProvider);
          final palette = ref.read(paletteProvider.notifier);
          palette.pushSubmode(OptionListSubmode(
            title: share ? '选择要分享的文档库' : '选择要导出的文档库',
            options: [
              for (final library in ref.read(libraryProvider).libraries)
                PaletteOption(
                  label: library.name,
                  subtitle: library.dir,
                  onSelect: (context) {
                    final origin = share ? libraryShareOrigin(context) : null;
                    palette.close();
                    return share ? transfer.sharePackage(library, origin) : transfer.exportPackage(library);
                  },
                ),
            ],
          ));
        },
      ),
    AppCommand(
      id: 'library.validate',
      category: '文档库',
      title: '校验文档库',
      description: '执行契约校验 V01–V20',
      keywords: ['validate', 'lint', 'check', '检查'],
      isEnabled: (r) => r.read(libraryProvider).libraries.isNotEmpty,
      run: (ctx, ref) {
        final libs = ref.read(libraryProvider).libraries;
        final curLibKey = ref.read(navigationProvider).location?.libKey;
        final curLib = curLibKey == null ? null : ref.read(libraryProvider).byKey(curLibKey);
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '校验文档库',
              options: [
                if (curLib != null)
                  PaletteOption(
                    label: '当前库：${curLib.name}',
                    onSelect: (_) {
                      final res = ref.read(validationResultsProvider.notifier).runFor(curLib, libs);
                      ref.read(paletteProvider.notifier).pushSubmode(DynamicSubmode(
                            title: '校验结果 · ${curLib.name}（${res.errorCount} 错误 / ${res.warningCount} 警告）',
                            placeholder: '过滤问题编号或描述…',
                            kind: DynamicModeKind.validationResults,
                            validationSummaries: [res],
                          ));
                    },
                  ),
                PaletteOption(
                  label: '全部文档库（${libs.length} 个）',
                  onSelect: (_) {
                    final all = ref.read(validationResultsProvider.notifier).runAll(libs);
                    final errs = all.fold<int>(0, (a, b) => a + b.errorCount);
                    final warns = all.fold<int>(0, (a, b) => a + b.warningCount);
                    ref.read(paletteProvider.notifier).pushSubmode(DynamicSubmode(
                          title: '校验结果 · 全部库（$errs 错误 / $warns 警告）',
                          placeholder: '过滤问题编号或描述…',
                          kind: DynamicModeKind.validationResults,
                          validationSummaries: all,
                        ));
                  },
                ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'library.generateManifest',
      category: '文档库',
      title: '为此文件夹生成 manifest',
      description: '为纯 Markdown 文件夹生成平铺版本 manifest.json',
      keywords: ['manifest', 'generate', 'convert'],
      isEnabled: (r) => r.read(libraryProvider).libraries.any((l) => l.format == LibraryFormat.plain),
      run: (ctx, ref) {
        final plains = ref.read(libraryProvider).libraries.where((l) => l.format == LibraryFormat.plain).toList();
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '选择纯 Markdown 库生成 manifest',
              options: [
                for (final l in plains)
                  PaletteOption(
                    label: l.name,
                    subtitle: l.dir,
                    onSelect: (_) {
                      final exists = ManifestGenerator.hasExistingManifest(l.dir);
                      ref.read(paletteProvider.notifier).pushSubmode(ConfirmSubmode(
                            title: '生成 manifest.json',
                            message: exists
                                ? '「${l.name}」已存在 manifest.json，是否覆盖？（不改动 .md 文件）'
                                : '将为「${l.name}」生成平铺版本 manifest.json（不改动任何 .md 文件）。是否继续？',
                            confirmLabel: '生成',
                            onConfirm: (_) async {
                              ManifestGenerator.generate(l);
                              ref.read(paletteProvider.notifier).close();
                              ref.read(noticeProvider.notifier).show('已生成 manifest.json');
                              await ref.read(libraryProvider.notifier).reload();
                            },
                          ));
                    },
                  ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'library.addRoot',
      category: '文档库',
      title: Platform.isAndroid ? '导入文档文件夹' : '添加库根目录',
      keywords: ['root', 'folder', 'add'],
      run: (ctx, ref) async {
        ref.read(paletteProvider.notifier).close();
        if (Platform.isAndroid) {
          await importAndroidLibrary(ref, ctx);
          return;
        }
        final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择文档库根目录');
        if (dir == null || dir.trim().isEmpty) return;
        final norm = dir.replaceAll('\\', '/');
        final roots = List<String>.of(ref.read(settingsProvider).libraryRoots);
        if (!roots.contains(norm)) {
          roots.add(norm);
          ref.read(settingsProvider.notifier).set('libraryRoots', roots);
          ref.read(noticeProvider.notifier).show('已添加文档库根目录：$norm');
        }
      },
    ),
    AppCommand(
      id: 'library.removeRoot',
      category: '文档库',
      title: '移除库根目录',
      description: '仅从配置中移除，不删除磁盘文件',
      keywords: ['root', 'remove'],
      isEnabled: (r) => r.read(settingsProvider).libraryRoots.isNotEmpty,
      run: (ctx, ref) {
        final roots = ref.read(settingsProvider).libraryRoots;
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '选择要移除的库根目录',
              options: [
                for (final r in roots)
                  PaletteOption(
                    label: r,
                    onSelect: (_) {
                      ref.read(paletteProvider.notifier).pushSubmode(ConfirmSubmode(
                            title: '移除库根目录',
                            message: '确定从配置中移除「$r」吗？不会删除磁盘上的任何文件。',
                            confirmLabel: '移除',
                            destructive: true,
                            onConfirm: (_) {
                              final next = List<String>.of(ref.read(settingsProvider).libraryRoots)..remove(r);
                              ref.read(settingsProvider.notifier).set('libraryRoots', next);
                              ref.read(paletteProvider.notifier).close();
                              ref.read(noticeProvider.notifier).show('已移除库根目录');
                            },
                          ));
                    },
                  ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'library.reload',
      category: '文档库',
      title: '重新加载全部文档库',
      keywords: ['reload', 'refresh', 'scan'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        ref.read(libraryProvider.notifier).reload();
        ref.read(noticeProvider.notifier).show('正在重新扫描全部文档库…');
      },
    ),
    AppCommand(
      id: 'library.rebuildIndex',
      category: '文档库',
      title: '重建向量索引',
      keywords: ['index', 'vector', 'embed', 'rebuild'],
      isEnabled: (r) => r.read(libraryProvider).libraries.isNotEmpty,
      run: (ctx, ref) {
        final libs = ref.read(libraryProvider).libraries;
        final curKey = ref.read(navigationProvider).location?.libKey;
        final curLib = curKey == null ? null : ref.read(libraryProvider).byKey(curKey);
        ref.read(paletteProvider.notifier).pushSubmode(OptionListSubmode(
              title: '重建向量索引',
              options: [
                if (curLib != null)
                  PaletteOption(
                    label: '当前库：${curLib.name}',
                    onSelect: (_) async {
                      final est = await ref.read(embedIndexerProvider.notifier).estimateChunkCount([curLib]);
                      ref.read(paletteProvider.notifier).pushSubmode(ConfirmSubmode(
                            title: '确认重建向量索引',
                            message: '预计为「${curLib.name}」嵌入 $est 个文本块${est > 20000 ? '（超过 2 万块）' : ''}。是否继续？',
                            confirmLabel: '开始重建',
                            onConfirm: (_) {
                              ref.read(paletteProvider.notifier).close();
                              ref.read(embedIndexerProvider.notifier).indexLibrary(curLib, forceRebuild: true);
                              ref.read(noticeProvider.notifier).show('已开始重建「${curLib.name}」向量索引');
                            },
                          ));
                    },
                  ),
                PaletteOption(
                  label: '全部库（${libs.length} 个）',
                  onSelect: (_) async {
                    final est = await ref.read(embedIndexerProvider.notifier).estimateChunkCount(libs);
                    ref.read(paletteProvider.notifier).pushSubmode(ConfirmSubmode(
                          title: '确认重建全部向量索引',
                          message: '预计为全部文档库嵌入 $est 个文本块${est > 20000 ? '（超过 2 万块）' : ''}。是否继续？',
                          confirmLabel: '开始重建',
                          onConfirm: (_) {
                            ref.read(paletteProvider.notifier).close();
                            ref.read(embedIndexerProvider.notifier).indexAll(libs, forceRebuild: true);
                            ref.read(noticeProvider.notifier).show('已开始重建全部向量索引');
                          },
                        ));
                  },
                ),
              ],
            ));
      },
    ),
    AppCommand(
      id: 'library.revealInExplorer',
      category: '文档库',
      title: '在资源管理器中打开',
      keywords: ['explorer', 'folder', 'reveal'],
      isEnabled: (r) => r.read(libraryProvider).libraries.isNotEmpty,
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        final loc = ref.read(navigationProvider).location;
        final lib = loc != null
            ? ref.read(libraryProvider).byKey(loc.libKey)
            : ref.read(libraryProvider).libraries.firstOrNull;
        if (lib != null) openInShell(lib.dir);
      },
    ),

    // ======================== 2.8 帮助 (3) ========================
    AppCommand(
      id: 'help.shortcuts',
      category: '帮助',
      title: '快捷键',
      keywords: ['shortcuts', 'keys', 'hotkeys'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(const FormSubmode(
              title: '基础快捷键',
              kind: FormModeKind.shortcuts,
            ));
      },
    ),
    AppCommand(
      id: 'help.about',
      category: '帮助',
      title: '关于 flDoc',
      keywords: ['about', 'version'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).pushSubmode(const FormSubmode(
              title: '关于 flDoc',
              kind: FormModeKind.about,
            ));
      },
    ),
    AppCommand(
      id: 'help.openLogs',
      category: '帮助',
      title: '打开日志目录',
      keywords: ['logs', 'debug'],
      run: (ctx, ref) {
        ref.read(paletteProvider.notifier).close();
        openInShell(AppPaths.instance.logsDir);
      },
    ),
  ];
}
