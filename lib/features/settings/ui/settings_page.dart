import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/paths.dart';
import '../../ai/index/embed_indexer.dart';
import '../../library/library_controller.dart';
import '../../reader/mermaid/mermaid_renderer.dart';
import '../../reader/navigation/navigation_controller.dart';
import '../../search/rg/rg_service.dart';
import '../settings_controller.dart';
import '../settings_model.dart';
import 'ai_model_form.dart';

/// Settings page with 8 sections bound directly to [settingsProvider] (FR-ST-01..06).
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, required this.onRerunOobe});

  final VoidCallback onRerunOobe;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  static const _sections = <(String id, String label, IconData icon)>[
    ('general', '常规', FluentIcons.settings),
    ('appearance', '外观', FluentIcons.color),
    ('reading', '阅读', FluentIcons.reading_mode),
    ('search', '搜索', FluentIcons.search),
    ('ai', 'AI', FluentIcons.chat),
    ('window', '窗口', FluentIcons.view_all),
    ('libraries', '文档库', FluentIcons.library),
    ('about', '关于', FluentIcons.info),
  ];

  String _section = 'general';
  String? _lastHandledNavSec;
  String? _rgVersion;
  String? _webView2Version;
  bool _checkedAbout = false;

  @override
  void initState() {
    super.initState();
    final target = ref.read(navigationProvider).settingsSection;
    _lastHandledNavSec = target;
    if (target != null && _sections.any((e) => e.$1 == target)) {
      _section = target;
    }
  }

  void _ensureAboutLoaded() {
    if (_checkedAbout) return;
    _checkedAbout = true;
    final rgPath = ref.read(settingsProvider).rgPath;
    getRgVersion(rgPath).then((v) {
      if (mounted) setState(() => _rgVersion = v);
    });
    MermaidRenderer.checkWebView2Version().then((v) {
      if (mounted) setState(() => _webView2Version = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final navSec = ref.watch(navigationProvider.select((s) => s.settingsSection));
    if (navSec == null) {
      _lastHandledNavSec = null;
    } else if (_sections.any((e) => e.$1 == navSec) && navSec != _lastHandledNavSec) {
      // Honor explicit programmatic jump to a section once.
      _lastHandledNavSec = navSec;
      if (navSec != _section) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _section = navSec);
        });
      }
    }

    final settings = ref.watch(settingsProvider);
    final ctl = ref.read(settingsProvider.notifier);
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final border = dark ? const Color(0x22FFFFFF) : const Color(0x18000000);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);

    if (_section == 'about') _ensureAboutLoaded();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Section rail
        Container(
          width: 164,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
          decoration: BoxDecoration(border: Border(right: BorderSide(color: border))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                child: Text('设置', style: theme.typography.subtitle),
              ),
              for (final sec in _sections)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: GestureDetector(
                    onTap: () => setState(() => _section = sec.$1),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: _section == sec.$1
                              ? (dark ? const Color(0x18FFFFFF) : const Color(0x10000000))
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Row(
                          children: [
                            Icon(sec.$3, size: 15, color: _section == sec.$1 ? accent : null),
                            const SizedBox(width: 10),
                            Text(
                              sec.$2,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: _section == sec.$1 ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // Content pane
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 22, 28, 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: switch (_section) {
                'general' => _buildGeneral(settings, ctl),
                'appearance' => _buildAppearance(settings, ctl),
                'reading' => _buildReading(settings, ctl),
                'search' => _buildSearch(settings, ctl),
                'ai' => _buildAi(settings, ctl),
                'window' => _buildWindow(settings, ctl),
                'libraries' => _buildLibraries(settings, ctl),
                'about' => _buildAbout(theme),
                _ => const SizedBox.shrink(),
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGeneral(AppSettings s, SettingsController ctl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('常规'),
        _SettingTile(
          title: '侧边栏收起形态',
          subtitle: '按 Ctrl+B 收起侧边栏时的展示方式',
          trailing: ComboBox<String>(
            value: s.sidebarCollapsedMode,
            items: const [
              ComboBoxItem(value: 'hidden', child: Text('完全隐藏')),
              ComboBoxItem(value: 'iconBar', child: Text('图标栏')),
            ],
            onChanged: (v) {
              if (v != null) ctl.set('sidebar.collapsedMode', v);
            },
          ),
        ),
        _SettingTile(
          title: '初始设置向导 (OOBE)',
          subtitle: '重新配置库根目录、AI 模型与外观',
          trailing: Button(onPressed: widget.onRerunOobe, child: const Text('重新运行向导')),
        ),
        _SettingTile(
          title: '日志目录',
          subtitle: '保留最近 7 天日志，已对密钥脱敏',
          trailing: Button(
            onPressed: () => _openInShell(AppPaths.instance.logsDir),
            child: const Text('打开日志目录'),
          ),
        ),
      ],
    );
  }

  Widget _buildAppearance(AppSettings s, SettingsController ctl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('外观'),
        _SettingTile(
          title: '颜色主题',
          subtitle: '亮色、暗色或跟随 Windows 系统设置',
          trailing: ComboBox<String>(
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
        ),
        _SettingTile(
          title: '强调色',
          subtitle: '当前：${s.accentColor}',
          bottom: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in accentPresets.entries)
                Tooltip(
                  message: e.value,
                  child: GestureDetector(
                    onTap: () => ctl.set('appearance.accentColor', e.key),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: parseHexColor(e.key),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: s.accentColor.toUpperCase() == e.key ? Colors.white : Colors.transparent,
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _SettingTile(
          title: '正文字体',
          subtitle: '留空使用系统默认字体',
          trailing: SizedBox(
            width: 200,
            child: ComboBox<String>(
              isExpanded: true,
              value: _bodyFonts.contains(s.bodyFont) ? s.bodyFont : null,
              placeholder: Text(s.bodyFont.isEmpty ? '默认' : s.bodyFont),
              items: [for (final f in _bodyFonts) ComboBoxItem(value: f, child: Text(f))],
              onChanged: (v) {
                if (v != null) ctl.set('appearance.bodyFont', v);
              },
            ),
          ),
        ),
        _SettingTile(
          title: '代码字体',
          trailing: SizedBox(
            width: 200,
            child: ComboBox<String>(
              isExpanded: true,
              value: _codeFonts.contains(s.codeFont) ? s.codeFont : null,
              placeholder: Text(s.codeFont.isEmpty ? 'Consolas' : s.codeFont),
              items: [for (final f in _codeFonts) ComboBoxItem(value: f, child: Text(f))],
              onChanged: (v) {
                if (v != null) ctl.set('appearance.codeFont', v);
              },
            ),
          ),
        ),
        _SettingTile(
          title: '基础字号（${s.fontSize.round()} px）',
          subtitle: '范围 11–28',
          trailing: SizedBox(
            width: 200,
            child: Slider(
              min: 11,
              max: 28,
              divisions: 17,
              value: s.fontSize.clamp(11, 28),
              onChanged: (v) => ctl.set('appearance.fontSize', v.round()),
            ),
          ),
        ),
        _SettingTile(
          title: '正文最大行宽（${s.contentMaxWidth <= 0 ? '不限' : '${s.contentMaxWidth} px'}）',
          subtitle: '设 0 表示不限制宽度',
          trailing: SizedBox(
            width: 200,
            child: Slider(
              min: 0,
              max: 1600,
              divisions: 32,
              value: s.contentMaxWidth.toDouble().clamp(0, 1600),
              onChanged: (v) {
                final snapped = v < 480 ? 0 : (v / 50).round() * 50;
                ctl.set('appearance.contentMaxWidth', snapped);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReading(AppSettings s, SettingsController ctl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('阅读'),
        _SettingTile(
          title: '阅读语言',
          subtitle: '切换中文译文与英文原文（无原文时自动回退中文）',
          trailing: ComboBox<String>(
            value: s.language,
            items: const [
              ComboBoxItem(value: 'zh', child: Text('中文')),
              ComboBoxItem(value: 'original', child: Text('原文')),
            ],
            onChanged: (v) {
              if (v != null) ctl.set('reading.language', v);
            },
          ),
        ),
        _SettingTile(
          title: '字号缩放（${(s.fontScale * 100).round()}%）',
          subtitle: '快捷键 Ctrl+= / Ctrl+- / Ctrl+0',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 150,
                child: Slider(
                  min: 0.6,
                  max: 2.0,
                  divisions: 14,
                  value: s.fontScale.clamp(0.6, 2.0),
                  onChanged: (v) => ctl.set('reading.fontScale', double.parse(v.toStringAsFixed(2))),
                ),
              ),
              const SizedBox(width: 8),
              Button(onPressed: () => ctl.set('reading.fontScale', 1.0), child: const Text('重置')),
            ],
          ),
        ),
        _SettingTile(
          title: '记住阅读位置',
          subtitle: '每页按标题锚点与相对偏移自动恢复滚动位置',
          trailing: ToggleSwitch(
            checked: s.rememberPosition,
            onChanged: (v) => ctl.set('reading.rememberPosition', v),
          ),
        ),
      ],
    );
  }

  Widget _buildSearch(AppSettings s, SettingsController ctl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('搜索'),
        _SettingTile(
          title: '全局搜索默认范围',
          trailing: ComboBox<String>(
            value: s.defaultScope,
            items: const [
              ComboBoxItem(value: 'currentLibrary', child: Text('当前库')),
              ComboBoxItem(value: 'allLibraries', child: Text('全部库')),
            ],
            onChanged: (v) {
              if (v != null) ctl.set('search.defaultScope', v);
            },
          ),
        ),
        _SettingTile(
          title: '默认大小写匹配',
          trailing: ComboBox<String>(
            value: s.caseMode,
            items: const [
              ComboBoxItem(value: 'smart', child: Text('智能（含大写时区分）')),
              ComboBoxItem(value: 'sensitive', child: Text('区分大小写')),
              ComboBoxItem(value: 'ignore', child: Text('忽略大小写')),
            ],
            onChanged: (v) {
              if (v != null) ctl.set('search.caseMode', v);
            },
          ),
        ),
        _SettingTile(
          title: '最大结果数（${s.maxResults}）',
          trailing: SizedBox(
            width: 180,
            child: Slider(
              min: 50,
              max: 1000,
              divisions: 19,
              value: s.maxResults.toDouble().clamp(50, 1000),
              onChanged: (v) => ctl.set('search.maxResults', (v / 50).round() * 50),
            ),
          ),
        ),
        _SettingTile(
          title: 'ripgrep 可执行文件路径',
          subtitle: '留空使用随软件打包的内置 rg.exe',
          bottom: TextBox(
            controller: TextEditingController(text: s.rgPath),
            placeholder: '留空使用内置 rg.exe',
            onSubmitted: (v) => ctl.set('search.rgPath', v.trim()),
          ),
        ),
      ],
    );
  }

  Widget _buildAi(AppSettings s, SettingsController ctl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('对话模型（OpenAI 兼容）'),
        const Card(child: AiModelForm(key: ValueKey('ai-form-chat'), isEmbedding: false)),
        const SizedBox(height: 12),
        _SettingTile(
          title: '检索关键词改写',
          subtitle: '搜索前用对话模型将查询改写为中英同义词与符号名',
          trailing: ToggleSwitch(
            checked: s.rewriteQuery,
            onChanged: (v) => ctl.set('ai.chat.rewriteQuery', v),
          ),
        ),
        const SizedBox(height: 18),
        const _SectionTitle('嵌入模型（向量语义检索）'),
        const Card(child: AiModelForm(key: ValueKey('ai-form-embed'), isEmbedding: true)),
        const SizedBox(height: 12),
        _SettingTile(
          title: '自动增量构建向量索引',
          subtitle: '文档库加载或变更后在后台按内容 hash 增量嵌入',
          trailing: ToggleSwitch(
            checked: s.autoIndex,
            onChanged: (v) => ctl.set('ai.embedding.autoIndex', v),
          ),
        ),
        _SettingTile(
          title: '重建全部向量索引',
          subtitle: '清空旧向量并按当前嵌入模型重新构建',
          trailing: Button(
            onPressed: () {
              final libs = ref.read(libraryProvider).libraries;
              ref.read(embedIndexerProvider.notifier).indexAll(libs, forceRebuild: true);
              ref.read(noticeProvider.notifier).show('已开始重建全部向量索引');
            },
            child: const Text('立即重建'),
          ),
        ),
        const SizedBox(height: 18),
        const _SectionTitle('RAG 问答与搜索建议'),
        _SettingTile(
          title: '召回片段数 TopK（${s.ragTopK}）',
          trailing: SizedBox(
            width: 180,
            child: Slider(
              min: 3,
              max: 16,
              divisions: 13,
              value: s.ragTopK.toDouble().clamp(3, 16),
              onChanged: (v) => ctl.set('ai.rag.topK', v.round()),
            ),
          ),
        ),
        _SettingTile(
          title: '保存 AI 会话历史',
          subtitle: '关闭后会话仅保存在内存中',
          trailing: ToggleSwitch(
            checked: s.saveHistory,
            onChanged: (v) => ctl.set('ai.rag.saveHistory', v),
          ),
        ),
        _SettingTile(
          title: '全局搜索无结果时提示 AI 智能搜索',
          trailing: ToggleSwitch(
            checked: s.suggestOnNoResult,
            onChanged: (v) => ctl.set('ai.suggestOnNoResult', v),
          ),
        ),
      ],
    );
  }

  Widget _buildWindow(AppSettings s, SettingsController ctl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('窗口'),
        _SettingTile(
          title: '窗口置顶',
          subtitle: '也可点击标题栏图钉按钮切换',
          trailing: ToggleSwitch(
            checked: s.alwaysOnTop,
            onChanged: (v) => ctl.set('window.alwaysOnTop', v),
          ),
        ),
        _SettingTile(
          title: '窗口透明度（${(s.opacity * 100).round()}%）',
          subtitle: '范围 30%–100%',
          trailing: SizedBox(
            width: 200,
            child: Slider(
              min: 30,
              max: 100,
              divisions: 14,
              value: (s.opacity * 100).clamp(30, 100),
              onChanged: (v) => ctl.set('window.opacity', double.parse((v / 100).toStringAsFixed(2))),
            ),
          ),
        ),
        _SettingTile(
          title: '关闭按钮最小化到托盘',
          subtitle: '托盘右键菜单可真正退出 flDoc',
          trailing: ToggleSwitch(
            checked: s.closeToTray,
            onChanged: (v) => ctl.set('window.closeToTray', v),
          ),
        ),
        _SettingTile(
          title: '开机自启',
          subtitle: '写入当前用户启动项',
          trailing: ToggleSwitch(
            checked: s.launchAtStartup,
            onChanged: (v) => ctl.set('window.launchAtStartup', v),
          ),
        ),
        _SettingTile(
          title: '重置窗口位置与大小',
          subtitle: '恢复到主显示器居中默认尺寸',
          trailing: Button(
            onPressed: () {
              ref.read(windowServiceProvider)?.resetBounds();
              ref.read(noticeProvider.notifier).show('已重置窗口位置与大小');
            },
            child: const Text('重置'),
          ),
        ),
      ],
    );
  }

  Widget _buildLibraries(AppSettings s, SettingsController ctl) {
    final roots = s.libraryRoots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('文档库根目录'),
        for (final r in roots)
          _SettingTile(
            title: r,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(FluentIcons.folder_open, size: 14),
                  onPressed: () => _openInShell(r),
                ),
                IconButton(
                  icon: const Icon(FluentIcons.delete, size: 14),
                  onPressed: () {
                    final next = List<String>.of(roots)..remove(r);
                    ctl.set('libraryRoots', next);
                  },
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton(
              onPressed: () async {
                final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择文档库根目录');
                if (dir == null || dir.trim().isEmpty) return;
                final norm = dir.replaceAll('\\', '/');
                if (!roots.contains(norm)) {
                  ctl.set('libraryRoots', [...roots, norm]);
                }
              },
              child: const Text('添加根目录'),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: () {
                ref.read(libraryProvider.notifier).reload();
                ref.read(noticeProvider.notifier).show('正在重新扫描文档库…');
              },
              child: const Text('重新加载全部文档库'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAbout(FluentThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('关于 flDoc'),
        const _SettingTile(title: 'flDoc', subtitle: 'Windows 桌面悬浮离线文档阅读器 · 版本 0.1.3'),
        _SettingTile(
          title: 'ripgrep (rg)',
          subtitle: _rgVersion ?? '未检测到（请检查内置 rg.exe 或搜索设置中的路径）',
        ),
        _SettingTile(
          title: 'WebView2 Runtime（Mermaid 图表渲染）',
          subtitle: _webView2Version != null
              ? '已安装：$_webView2Version'
              : '未检测到 WebView2 Runtime（Mermaid 将降级显示源码；请安装 Microsoft Edge WebView2 Runtime）',
        ),
        _SettingTile(
          title: '应用数据目录',
          subtitle: AppPaths.instance.supportDir,
          trailing: Button(
            onPressed: () => _openInShell(AppPaths.instance.supportDir),
            child: const Text('打开目录'),
          ),
        ),
      ],
    );
  }

  void _openInShell(String path) {
    if (!Platform.isWindows) return;
    final winPath = path.replaceAll('/', '\\');
    if (Directory(winPath).existsSync()) {
      Process.start('explorer.exe', [winPath], runInShell: false);
    } else {
      Process.start('cmd.exe', ['/c', 'start', '', winPath], runInShell: false);
    }
  }

  static const _bodyFonts = [
    'Microsoft YaHei UI',
    'Segoe UI',
    'Microsoft YaHei',
    'Sarasa UI SC',
    'PingFang SC',
    'SimSun',
  ];

  static const _codeFonts = [
    'Cascadia Code',
    'Cascadia Mono',
    'Consolas',
    'JetBrains Mono',
    'Fira Code',
    'Courier New',
  ];
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text, style: FluentTheme.of(context).typography.subtitle),
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({required this.title, this.subtitle, this.trailing, this.bottom});

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: TextStyle(fontSize: 12, color: theme.resources.textFillColorSecondary)),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            ),
            if (bottom != null) ...[const SizedBox(height: 10), bottom!],
          ],
        ),
      ),
    );
  }
}
