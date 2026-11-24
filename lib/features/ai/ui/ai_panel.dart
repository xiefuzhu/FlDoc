import 'dart:collection';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../library/models.dart';
import '../../reader/markdown/md_model.dart';
import '../../reader/markdown/md_parser.dart';
import '../../reader/navigation/navigation_controller.dart';
import '../../reader/render/block_renderer.dart';
import '../../search/models.dart';
import '../../settings/settings_controller.dart';
import '../../settings/settings_model.dart';
import '../ai_controller.dart';
import '../client/openai_client.dart';
import '../history/chat_history.dart';
import 'ai_config_guard.dart';

/// Right-hand collapsible, resizable RAG AI chat panel (FR-AI-03, FR-AI-04, doc 06 §5.3).
class AiPanel extends ConsumerStatefulWidget {
  const AiPanel({super.key, required this.onOpenHistory, this.embedded = false});

  final VoidCallback onOpenHistory;
  final bool embedded;

  @override
  ConsumerState<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends ConsumerState<AiPanel> {
  final _inputCtrl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scrollCtrl = ScrollController();
  late double _width;
  bool _inputFocused = false;
  bool _refreshingModels = false;

  @override
  void initState() {
    super.initState();
    _width = ref.read(uiStateProvider).aiPanelWidth.clamp(280.0, 640.0);
    _inputFocus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted && _inputFocused != _inputFocus.hasFocus) {
      setState(() => _inputFocused = _inputFocus.hasFocus);
    }
  }

  @override
  void dispose() {
    _inputFocus.removeListener(_onFocusChange);
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    final ok = await ensureAiReady(context, ref, requireChat: true);
    if (!ok) return;
    _inputCtrl.clear();
    _scrollToBottom();
    await ref.read(aiControllerProvider.notifier).ask(text);
    _scrollToBottom();
  }

  Future<void> _refreshModels() async {
    if (_refreshingModels) return;
    setState(() => _refreshingModels = true);
    try {
      final models = await ref.read(aiControllerProvider.notifier).refreshChatModels();
      if (!mounted) return;
      ref.read(noticeProvider.notifier).show('已刷新 ${models.length} 个模型');
    } catch (e) {
      if (!mounted) return;
      ref.read(noticeProvider.notifier).show('刷新模型列表失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _refreshingModels = false);
    }
  }

  void _jumpCitation(ChatCitation c) {
    ref.read(navigationProvider.notifier).open(
          DocLocation(
            libKey: c.libKey,
            versionId: c.versionId,
            page: c.page,
            anchor: c.anchor.isEmpty ? null : c.anchor,
            highlight: c.breadcrumb.isNotEmpty ? c.breadcrumb.split('>').last.trim() : null,
          ),
        );
  }

  void _openAiSettings() {
    ref.read(navigationProvider.notifier).openSettings(section: 'ai');
  }

  @override
  Widget build(BuildContext context) {
    final ai = ref.watch(aiControllerProvider);
    if (!ai.visible) return const SizedBox.shrink();

    final ctl = ref.read(aiControllerProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final settingsCtl = ref.read(settingsProvider.notifier);
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final borderColor = dark ? const Color(0x22FFFFFF) : const Color(0x18000000);
    final bgColor = dark ? const Color(0xFF1C1C1C) : const Color(0xFFF9F9F9);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);

    ref.listen(aiControllerProvider.select((s) => s.streamingContent.length + s.messages.length), (_, _) {
      _scrollToBottom();
    });

    final style = ReaderStyle(
      theme: theme,
      fontSize: (settings.fontSize * 0.92).clamp(12.0, 18.0),
      bodyFont: settings.bodyFont,
      codeFont: settings.codeFont,
      maxWidth: null,
    );

    final panel = Container(
          width: widget.embedded ? double.infinity : _width,
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(left: BorderSide(color: borderColor)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: borderColor))),
                child: Row(
                  children: [
                    Icon(FluentIcons.chat, size: 15, color: accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ai.session?.title ?? '聊天',
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Scope toggle chip
                    Tooltip(
                      message: '切换检索范围',
                      child: GestureDetector(
                        onTap: () => ctl.setScope(
                          ai.scope == SearchScope.currentLibrary ? SearchScope.allLibraries : SearchScope.currentLibrary,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            ai.scope == SearchScope.currentLibrary ? '当前库' : '全部库',
                            style: TextStyle(fontSize: 11, color: accent, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                    Tooltip(
                      message: '新建对话',
                      child: IconButton(
                        icon: const Icon(FluentIcons.add, size: 13),
                        onPressed: () => ctl.newChat(),
                      ),
                    ),
                    Tooltip(
                      message: '历史对话',
                      child: IconButton(
                        icon: const Icon(FluentIcons.history, size: 13),
                        onPressed: widget.onOpenHistory,
                      ),
                    ),
                    Tooltip(
                      message: '收起聊天',
                      child: IconButton(
                        icon: const Icon(FluentIcons.chrome_close, size: 11),
                        onPressed: () => ctl.setVisible(false),
                      ),
                    ),
                  ],
                ),
              ),

              if (ai.vectorNotice != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  color: Colors.orange.withValues(alpha: 0.12),
                  child: Row(
                    children: [
                      Icon(FluentIcons.info, size: 13, color: Colors.orange),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(ai.vectorNotice!, style: const TextStyle(fontSize: 11.5)),
                      ),
                      HyperlinkButton(
                        onPressed: _openAiSettings,
                        child: const Text('配置嵌入模型', style: TextStyle(fontSize: 11.5)),
                      ),
                    ],
                  ),
                ),

              // Message list
              Expanded(
                child: ai.messages.isEmpty && !ai.streaming
                    ? _EmptyChat(focusPage: ai.focusPage)
                    : ListView(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(12),
                        children: [
                          for (final m in ai.messages)
                            _MessageBubble(
                              message: m,
                              style: style,
                              onCitationTap: _jumpCitation,
                            ),
                          if (ai.streaming)
                            _MessageBubble(
                              message: ChatMessageModel(
                                sessionId: ai.session?.id ?? '',
                                role: 'assistant',
                                content: ai.streamingContent.isEmpty ? '正在检索并思考…' : ai.streamingContent,
                                reasoning: ai.streamingReasoning,
                                citations: ai.streamingCitations,
                                createdAt: 0,
                              ),
                              style: style,
                              streaming: true,
                              onCitationTap: _jumpCitation,
                            ),
                        ],
                      ),
              ),

              // Error banner
              if (ai.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: InfoBar(
                    title: const Text('请求失败'),
                    content: Text(ai.error!),
                    severity: InfoBarSeverity.error,
                    action: Wrap(
                      spacing: 6,
                      children: [
                        Button(onPressed: ctl.retryLast, child: const Text('重试')),
                        if (ai.errorKind == AiErrorKind.unauthorized)
                          FilledButton(
                            onPressed: _openAiSettings,
                            child: const Text('打开对话模型配置'),
                          ),
                      ],
                    ),
                  ),
                ),

              // Copilot-style composer card (input + model / reasoning / context controls)
              _buildComposerCard(
                context: context,
                ai: ai,
                ctl: ctl,
                settings: settings,
                settingsCtl: settingsCtl,
                theme: theme,
                dark: dark,
                accent: accent,
                borderColor: borderColor,
              ),
            ],
          ),
    );
    if (widget.embedded) return panel;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: (d) {
              setState(() => _width = (_width - d.delta.dx).clamp(280.0, 640.0));
            },
            onHorizontalDragEnd: (_) => ref.read(uiStateProvider).aiPanelWidth = _width,
            child: const SizedBox(width: 4),
          ),
        ),
        panel,
      ],
    );
  }

  Widget _buildComposerCard({
    required BuildContext context,
    required AiPanelState ai,
    required AiController ctl,
    required AppSettings settings,
    required SettingsController settingsCtl,
    required FluentThemeData theme,
    required bool dark,
    required Color accent,
    required Color borderColor,
  }) {
    final cardBg = dark ? const Color(0xFF252526) : const Color(0xFFFFFFFF);
    final cardBorder = _inputFocused ? accent.withValues(alpha: 0.75) : borderColor;

    final modelChoices = <String>[];
    final seenModels = <String>{};
    for (final raw in [
      if (settings.chatModel.trim().isNotEmpty) settings.chatModel.trim(),
      ...settings.chatModels,
    ]) {
      final m = raw.trim();
      if (m.isNotEmpty && seenModels.add(m)) modelChoices.add(m);
    }

    final reasoningLabel = switch (settings.chatReasoningEffort) {
      'low' => '思考: 低',
      'medium' => '思考: 中',
      'high' => '思考: 高',
      _ => '思考: 默认',
    };
    final contextLabel = settings.chatContextWindow == 500000 ? '500k' : '274k';

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cardBorder),
        ),
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    (event.logicalKey == LogicalKeyboardKey.enter ||
                        event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  if (!ai.streaming) _send();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextBox(
                controller: _inputCtrl,
                focusNode: _inputFocus,
                placeholder: '向文档提问… (Enter 发送，Shift+Enter 换行)',
                maxLines: 6,
                minLines: 2,
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                decoration: WidgetStateProperty.all(const BoxDecoration()),
                foregroundDecoration: WidgetStateProperty.all(const BoxDecoration()),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Model selector
                      DropDownButton(
                        placement: FlyoutPlacementMode.topLeft,
                        buttonBuilder: (ctx, onOpen) => _ComposerPill(
                          tooltip: '切换对话模型',
                          label: settings.chatModel.trim().isNotEmpty ? settings.chatModel.trim() : '选择模型',
                          maxWidth: 132,
                          onPressed: onOpen,
                        ),
                        items: [
                          for (final m in modelChoices)
                            MenuFlyoutItem(
                              leading: m == settings.chatModel
                                  ? Icon(FluentIcons.check_mark, size: 11, color: accent)
                                  : const SizedBox(width: 11),
                              text: Text(m, overflow: TextOverflow.ellipsis),
                              onPressed: () => settingsCtl.set('ai.chat.model', m),
                            ),
                          if (modelChoices.isNotEmpty) const MenuFlyoutSeparator(),
                          MenuFlyoutItem(
                            leading: const Icon(FluentIcons.sync, size: 12),
                            text: Text(_refreshingModels ? '正在刷新…' : '刷新模型列表'),
                            onPressed: _refreshingModels ? null : _refreshModels,
                          ),
                          MenuFlyoutItem(
                            leading: const Icon(FluentIcons.settings, size: 12),
                            text: const Text('配置对话模型…'),
                            onPressed: _openAiSettings,
                          ),
                        ],
                      ),

                      // Reasoning effort selector
                      DropDownButton(
                        placement: FlyoutPlacementMode.topLeft,
                        buttonBuilder: (ctx, onOpen) => _ComposerPill(
                          tooltip: '设置思考强度',
                          label: reasoningLabel,
                          onPressed: onOpen,
                        ),
                        items: [
                          for (final opt in const [
                            ('auto', '默认（自动）'),
                            ('low', '低 (low)'),
                            ('medium', '中 (medium)'),
                            ('high', '高 (high)'),
                          ])
                            MenuFlyoutItem(
                              leading: settings.chatReasoningEffort == opt.$1
                                  ? Icon(FluentIcons.check_mark, size: 11, color: accent)
                                  : const SizedBox(width: 11),
                              text: Text(opt.$2),
                              onPressed: () => settingsCtl.set('ai.chat.reasoningEffort', opt.$1),
                            ),
                        ],
                      ),

                      // Context window selector (default 274k & 500k)
                      DropDownButton(
                        placement: FlyoutPlacementMode.topLeft,
                        buttonBuilder: (ctx, onOpen) => _ComposerPill(
                          tooltip: '设置上下文大小',
                          label: contextLabel,
                          onPressed: onOpen,
                        ),
                        items: [
                          for (final opt in const [
                            (274000, '274k（默认）'),
                            (500000, '500k'),
                          ])
                            MenuFlyoutItem(
                              leading: settings.chatContextWindow == opt.$1
                                  ? Icon(FluentIcons.check_mark, size: 11, color: accent)
                                  : const SizedBox(width: 11),
                              text: Text(opt.$2),
                              onPressed: () => settingsCtl.set('ai.chat.contextWindow', opt.$1),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (ai.streaming)
                  FilledButton(
                    onPressed: ctl.stop,
                    style: const ButtonStyle(
                      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10, vertical: 5)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.stop, size: 11),
                        SizedBox(width: 4),
                        Text('停止', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  )
                else
                  FilledButton(
                    onPressed: _send,
                    style: const ButtonStyle(
                      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
                    ),
                    child: const Icon(FluentIcons.send, size: 13),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerPill extends StatefulWidget {
  const _ComposerPill({
    required this.tooltip,
    required this.label,
    required this.onPressed,
    this.maxWidth,
  });

  final String tooltip;
  final String label;
  final VoidCallback? onPressed;
  final double? maxWidth;

  @override
  State<_ComposerPill> createState() => _ComposerPillState();
}

class _ComposerPillState extends State<_ComposerPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final bg = _hovered
        ? (dark ? const Color(0x1EFFFFFF) : const Color(0x12000000))
        : (dark ? const Color(0x10FFFFFF) : const Color(0x08000000));
    final fg = theme.resources.textFillColorSecondary;

    Widget labelWidget = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11.5, color: fg),
    );
    if (widget.maxWidth != null) {
      labelWidget = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth!),
        child: labelWidget,
      );
    }

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                labelWidget,
                const SizedBox(width: 4),
                Icon(FluentIcons.chevron_down, size: 9, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.style,
    required this.onCitationTap,
    this.streaming = false,
  });

  final ChatMessageModel message;
  final ReaderStyle style;
  final void Function(ChatCitation) onCitationTap;
  final bool streaming;

  static final LinkedHashMap<String, MdDocument> _mdCache = LinkedHashMap();

  MdDocument _parseCached(String content) {
    if (streaming) return MdParser.parse(content);
    final hit = _mdCache.remove(content);
    if (hit != null) {
      _mdCache[content] = hit;
      return hit;
    }
    final parsed = MdParser.parse(content);
    _mdCache[content] = parsed;
    if (_mdCache.length > 200) {
      _mdCache.remove(_mdCache.keys.first);
    }
    return parsed;
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final s = style;

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 28),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: s.accent.withValues(alpha: s.dark ? 0.28 : 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(message.content, style: s.body.copyWith(fontSize: 13.5)),
        ),
      );
    }

    final doc = _parseCached(message.content);
    final citMap = {for (final c in message.citations) '[${c.index}]': c};

    final renderCtx = RenderContext(
      style: s,
      onLink: (_) {},
      onHover: (_) {},
      pageFile: '',
      libDir: '',
      citationBuilder: (token, textStyle) {
        final cit = citMap[token];
        if (cit == null) return null;
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Tooltip(
              message: '${cit.libName} / ${cit.title} / ${cit.breadcrumb}\n${cit.snippet}',
              child: GestureDetector(
                onTap: () => onCitationTap(cit),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: s.accent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      token,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: s.accent),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: s.surface.withValues(alpha: s.dark ? 0.7 : 0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: s.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message.reasoning.isNotEmpty) ...[
            Expander(
              header: Row(
                children: [
                  Icon(FluentIcons.lightbulb, size: 13, color: s.muted),
                  const SizedBox(width: 6),
                  Text('思考过程', style: TextStyle(fontSize: 12, color: s.muted)),
                ],
              ),
              content: SelectableText(
                message.reasoning,
                style: TextStyle(fontSize: 12, color: s.muted, height: 1.5),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final block in doc.blocks) BlockView(block: block, ctx: renderCtx),
              ],
            ),
          ),
          if (streaming)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2)),
              ),
            ),
          if (message.citations.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(height: 1, color: s.border),
            const SizedBox(height: 8),
            Text('引用来源', style: TextStyle(fontSize: 11.5, color: s.muted, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in message.citations)
                  Tooltip(
                    message: c.snippet,
                    child: GestureDetector(
                      onTap: () => onCitationTap(c),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: s.inlineCodeBg,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: s.border),
                          ),
                          child: Text(
                            '[${c.index}] ${c.title}${c.breadcrumb.isNotEmpty && c.breadcrumb != c.title ? ' · ${c.breadcrumb}' : ''}',
                            style: TextStyle(fontSize: 11.5, color: s.link),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({this.focusPage});
  final DocLocation? focusPage;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Zen ask what ?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
                color: theme.resources.textFillColorPrimary.withValues(alpha: 0.85),
              ),
            ),
            if (focusPage != null) ...[
              const SizedBox(height: 8),
              Text(
                '当前页：${focusPage!.page}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: theme.resources.textFillColorSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
