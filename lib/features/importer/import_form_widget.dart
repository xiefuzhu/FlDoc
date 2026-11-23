import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../settings/settings_controller.dart';
import 'prompt_builder.dart';

/// Multi-field import form that fills `assets/prompts/import_prompt.md`,
/// copies the generated prompt to clipboard, and shows a preview (FR-LIB-04).
class ImportLibraryForm extends ConsumerStatefulWidget {
  const ImportLibraryForm({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  ConsumerState<ImportLibraryForm> createState() => _ImportLibraryFormState();
}

class _ImportLibraryFormState extends ConsumerState<ImportLibraryForm> {
  final _urlCtrl = TextEditingController();
  final _scopeCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _verIdCtrl = TextEditingController(text: 'latest');
  final _verLabelCtrl = TextEditingController(text: 'latest');
  final _maxPagesCtrl = TextEditingController(text: '300');

  late String _targetRoot;
  bool _translate = true;
  bool _scopeTouched = false;
  bool _idTouched = false;
  bool _nameTouched = false;
  bool _verLabelTouched = false;

  String? _error;
  String? _preview;

  @override
  void initState() {
    super.initState();
    final roots = ref.read(settingsProvider).libraryRoots;
    _targetRoot = roots.isNotEmpty ? roots.first : '';
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _scopeCtrl.dispose();
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _verIdCtrl.dispose();
    _verLabelCtrl.dispose();
    _maxPagesCtrl.dispose();
    super.dispose();
  }

  ImportParams _currentParams() => ImportParams(
        sourceUrl: _urlCtrl.text,
        scope: _scopeCtrl.text,
        libId: _idCtrl.text,
        libName: _nameCtrl.text,
        versionId: _verIdCtrl.text,
        versionLabel: _verLabelCtrl.text,
        targetRoot: _targetRoot,
        maxPages: int.tryParse(_maxPagesCtrl.text.trim()) ?? 300,
        translate: _translate,
      );

  void _onUrlChanged(String url) {
    setState(() {
      if (!_scopeTouched) _scopeCtrl.text = PromptBuilder.deriveScope(url);
      final derivedId = PromptBuilder.deriveLibId(url);
      if (!_idTouched) _idCtrl.text = derivedId;
      if (!_nameTouched && derivedId.isNotEmpty) {
        _nameCtrl.text = derivedId[0].toUpperCase() + derivedId.substring(1);
      }
      _error = null;
    });
  }

  Future<void> _generateAndCopy() async {
    final params = _currentParams();
    final err = PromptBuilder.validate(params);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    try {
      final template = await PromptBuilder.loadTemplate();
      final rendered = PromptBuilder.render(template, params);
      await Clipboard.setData(ClipboardData(text: rendered));
      if (!mounted) return;
      setState(() {
        _error = null;
        _preview = rendered;
      });
      ref.read(noticeProvider.notifier).show('导入提示词已生成并复制到剪贴板');
    } catch (e) {
      setState(() => _error = '生成提示词失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final roots = ref.watch(settingsProvider.select((s) => s.libraryRoots));
    if (_targetRoot.isEmpty && roots.isNotEmpty) _targetRoot = roots.first;
    final params = _currentParams();
    final exists = _idCtrl.text.trim().isNotEmpty && params.existsOnDisk;
    final theme = FluentTheme.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Field(
            label: '来源 URL *',
            child: TextBox(
              controller: _urlCtrl,
              placeholder: 'https://riverpod.dev/docs/introduction/getting_started',
              onChanged: _onUrlChanged,
            ),
          ),
          _Field(
            label: '抓取范围（URL 前缀）',
            child: TextBox(
              controller: _scopeCtrl,
              placeholder: 'https://riverpod.dev/docs/',
              onChanged: (_) => setState(() => _scopeTouched = true),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _Field(
                  label: '库 ID *',
                  trailing: exists
                      ? Text('已存在，将增量更新', style: TextStyle(fontSize: 11, color: Colors.orange))
                      : Text('首次抓取', style: TextStyle(fontSize: 11, color: theme.resources.textFillColorSecondary)),
                  child: TextBox(
                    controller: _idCtrl,
                    placeholder: 'riverpod',
                    onChanged: (_) => setState(() => _idTouched = true),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Field(
                  label: '库名 *',
                  child: TextBox(
                    controller: _nameCtrl,
                    placeholder: 'Riverpod',
                    onChanged: (_) => setState(() => _nameTouched = true),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: _Field(
                  label: '版本 ID',
                  child: TextBox(
                    controller: _verIdCtrl,
                    placeholder: 'latest',
                    onChanged: (v) {
                      if (!_verLabelTouched) _verLabelCtrl.text = v;
                      setState(() {});
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Field(
                  label: '版本显示名',
                  child: TextBox(
                    controller: _verLabelCtrl,
                    placeholder: 'latest',
                    onChanged: (_) => _verLabelTouched = true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 96,
                child: _Field(
                  label: '最大页数',
                  child: TextBox(controller: _maxPagesCtrl),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: _Field(
                  label: '目标库根目录',
                  child: roots.isEmpty
                      ? const Text('未配置根目录', style: TextStyle(fontSize: 12))
                      : ComboBox<String>(
                          isExpanded: true,
                          value: roots.contains(_targetRoot) ? _targetRoot : roots.first,
                          items: [
                            for (final r in roots)
                              ComboBoxItem<String>(value: r, child: Text(r, overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _targetRoot = v);
                          },
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: ToggleSwitch(
                  checked: _translate,
                  onChanged: (v) => setState(() => _translate = v),
                  content: const Text('英文自动翻译'),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            InfoBar(title: const Text('校验失败'), content: Text(_error!), severity: InfoBarSeverity.error),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onClose != null) ...[
                Button(onPressed: widget.onClose, child: const Text('关闭')),
                const SizedBox(width: 8),
              ],
              FilledButton(
                onPressed: _generateAndCopy,
                child: const Text('生成提示词并复制到剪贴板'),
              ),
            ],
          ),
          if (_preview != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text('提示词预览（已复制，可粘贴给任意 Agent）',
                    style: TextStyle(fontSize: 12, color: theme.resources.textFillColorSecondary)),
                const Spacer(),
                HyperlinkButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _preview!));
                    ref.read(noticeProvider.notifier).show('已重新复制到剪贴板');
                  },
                  child: const Text('再次复制', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              height: 180,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark ? const Color(0xFF1A1A1A) : const Color(0xFFF6F8FA),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _preview!,
                  style: const TextStyle(fontSize: 11.5, fontFamily: 'Consolas', height: 1.45),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child, this.trailing});

  final String label;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
              if (trailing != null) ...[const Spacer(), trailing!],
            ],
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
