import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/paths.dart';
import '../settings_controller.dart';
import '../ui/ai_model_form.dart';

/// 6-step First-Run OOBE Wizard (doc 06 §9).
class OobeDialog extends ConsumerStatefulWidget {
  const OobeDialog({
    super.key,
    required this.onComplete,
    required this.onCompleteAndImport,
  });

  final VoidCallback onComplete;
  final VoidCallback onCompleteAndImport;

  @override
  ConsumerState<OobeDialog> createState() => _OobeDialogState();
}

class _OobeDialogState extends ConsumerState<OobeDialog> {
  int _step = 0;

  static const _stepTitles = [
    '欢迎使用 flDoc',
    '配置文档库目录',
    '配置对话模型（可选）',
    '配置嵌入模型（可选）',
    '选择外观',
    '准备就绪',
  ];

  void _finish({required bool openImport}) {
    // Ensure default library root directory exists on disk.
    final roots = ref.read(settingsProvider).libraryRoots;
    if (roots.isNotEmpty) {
      try {
        Directory(roots.first).createSync(recursive: true);
      } catch (_) {}
    }
    ref.read(settingsProvider.notifier).set('oobeCompleted', true);
    if (openImport) {
      widget.onCompleteAndImport();
    } else {
      widget.onComplete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);

    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 560),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: theme.menuColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Step progress indicator
              Row(
                children: [
                  Text(_stepTitles[_step], style: theme.typography.subtitle),
                  const Spacer(),
                  Text('${_step + 1} / ${_stepTitles.length}',
                      style: TextStyle(fontSize: 12, color: theme.resources.textFillColorSecondary)),
                ],
              ),
              const SizedBox(height: 10),
              ProgressBar(value: ((_step + 1) / _stepTitles.length) * 100),
              const SizedBox(height: 18),
              // Step body
              Expanded(
                child: SingleChildScrollView(
                  child: switch (_step) {
                    0 => _stepWelcome(accent, theme),
                    1 => _stepLibraries(theme),
                    2 => const AiModelForm(key: ValueKey('ai-form-chat'), isEmbedding: false),
                    3 => const AiModelForm(key: ValueKey('ai-form-embed'), isEmbedding: true),
                    4 => _stepAppearance(theme),
                    _ => _stepDone(accent, theme),
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Footer controls
              Row(
                children: [
                  if (_step < _stepTitles.length - 1)
                    Button(
                      onPressed: () => setState(() => _step++),
                      child: const Text('跳过此步'),
                    ),
                  const Spacer(),
                  if (_step > 0) ...[
                    Button(onPressed: () => setState(() => _step--), child: const Text('上一步')),
                    const SizedBox(width: 8),
                  ],
                  if (_step < _stepTitles.length - 1)
                    FilledButton(onPressed: () => setState(() => _step++), child: const Text('下一步'))
                  else ...[
                    Button(
                      onPressed: () => _finish(openImport: true),
                      child: const Text('导入第一个文档库'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => _finish(openImport: false),
                      child: const Text('进入 Home'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepWelcome(Color accent, FluentThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'flDoc 是专为写代码场景打造的 Windows 悬浮离线文档阅读器。把在线教程交给 AI Agent 抓取到本地后，随时置顶查阅、极速检索与提问。',
          style: TextStyle(fontSize: 13.5, height: 1.6, color: theme.resources.textFillColorPrimary),
        ),
        const SizedBox(height: 18),
        _IntroStep(icon: FluentIcons.download, color: accent, title: '1. 导入', desc: '生成标准化提示词，由 AI Agent 抓取并翻译文档到本地。'),
        _IntroStep(icon: FluentIcons.reading_mode, color: accent, title: '2. 阅读', desc: '置顶悬浮在屏幕一角，支持中英切换、代码高亮、Mermaid 与公式。'),
        _IntroStep(icon: FluentIcons.chat, color: accent, title: '3. 提问', desc: '内置 ripgrep 极速搜索 + 向量语义混合召回 + 可点击引用的 RAG 问答。'),
      ],
    );
  }

  Widget _stepLibraries(FluentThemeData theme) {
    final s = ref.watch(settingsProvider);
    final ctl = ref.read(settingsProvider.notifier);
    final roots = s.libraryRoots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'flDoc 会自动扫描并监听以下根目录中的文档库（默认 ${AppPaths.defaultLibraryRoot}）：',
          style: TextStyle(fontSize: 13, color: theme.resources.textFillColorSecondary),
        ),
        const SizedBox(height: 12),
        for (final r in roots)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Card(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(FluentIcons.folder, size: 15),
                  const SizedBox(width: 10),
                  Expanded(child: Text(r, style: const TextStyle(fontSize: 13))),
                  if (roots.length > 1)
                    IconButton(
                      icon: const Icon(FluentIcons.delete, size: 13),
                      onPressed: () => ctl.set('libraryRoots', List<String>.of(roots)..remove(r)),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Button(
            onPressed: () async {
              final dir = await FilePicker.getDirectoryPath(dialogTitle: '添加文档库根目录');
              if (dir != null && dir.trim().isNotEmpty) {
                final norm = dir.replaceAll('\\', '/');
                if (!roots.contains(norm)) ctl.set('libraryRoots', [...roots, norm]);
              }
            },
            child: const Text('添加更多根目录'),
          ),
        ),
      ],
    );
  }

  Widget _stepAppearance(FluentThemeData theme) {
    final s = ref.watch(settingsProvider);
    final ctl = ref.read(settingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('颜色主题：', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 10),
            ComboBox<String>(
              value: s.theme,
              items: const [
                ComboBoxItem(value: 'system', child: Text('跟随系统')),
                ComboBoxItem(value: 'light', child: Text('亮色')),
                ComboBoxItem(value: 'dark', child: Text('暗色')),
              ],
              onChanged: (v) {
                if (v != null) ctl.set('appearance.theme', v);
              },
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Text('强调色：', style: TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in accentPresets.entries)
              GestureDetector(
                onTap: () => ctl.set('appearance.accentColor', e.key),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: parseHexColor(e.key),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: s.accentColor.toUpperCase() == e.key ? Colors.white : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text('基础字号：${s.fontSize.round()} px', style: const TextStyle(fontSize: 13)),
        Slider(
          min: 11,
          max: 24,
          divisions: 13,
          value: s.fontSize.clamp(11, 24),
          onChanged: (v) => ctl.set('appearance.fontSize', v.round()),
        ),
        const SizedBox(height: 10),
        Card(
          child: Text(
            '字号预览：flDoc 让写代码时的文档查阅更专注、更高效。',
            style: TextStyle(fontSize: s.fontSize, height: 1.6),
          ),
        ),
      ],
    );
  }

  Widget _stepDone(Color accent, FluentThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(FluentIcons.completed_solid, size: 40, color: accent),
        const SizedBox(height: 12),
        const Text('一切就绪！', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Text(
          '• 按 Ctrl+Shift+P 随时打开命令面板，执行全局搜索、符号查找、AI 问答与全部设置。\n'
          '• 点击「导入第一个文档库」即可填写网址生成 Agent 爬取提示词。\n'
          '• 随时可通过命令「首选项: 重新运行初始设置向导」回到这里。',
          style: TextStyle(fontSize: 13, height: 1.7, color: theme.resources.textFillColorSecondary),
        ),
      ],
    );
  }
}

class _IntroStep extends StatelessWidget {
  const _IntroStep({required this.icon, required this.color, required this.title, required this.desc});
  final IconData icon;
  final Color color;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(desc, style: TextStyle(fontSize: 12.5, color: FluentTheme.of(context).resources.textFillColorSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
