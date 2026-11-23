import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/log.dart';
import '../../ai/client/openai_client.dart';
import '../../ai/index/embed_indexer.dart';
import '../credential_store.dart';
import '../settings_controller.dart';

/// Reusable OpenAI-compatible Chat or Embedding model config form.
/// Shared by Settings page, OOBE wizard, and Command Palette forms (FR-AI-05, FR-AI-06, FR-ST-03).
class AiModelForm extends ConsumerStatefulWidget {
  const AiModelForm({super.key, required this.isEmbedding, this.onSaved});

  final bool isEmbedding;
  final VoidCallback? onSaved;

  static bool isLocalBaseUrl(String baseUrl) => OpenAiClient.isLocalBaseUrl(baseUrl);

  @override
  ConsumerState<AiModelForm> createState() => _AiModelFormState();
}

class _AiModelFormState extends ConsumerState<AiModelForm> {
  final _baseUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _client = OpenAiClient();

  List<String> _fetchedModels = const [];
  bool _fetchingModels = false;
  bool _testing = false;
  String? _statusMsg;
  bool _statusError = false;
  String _maskedCurrent = '未配置';

  String get _credTarget => widget.isEmbedding ? CredentialStore.embeddingTarget : CredentialStore.chatTarget;
  String get _baseUrlPath => widget.isEmbedding ? 'ai.embedding.baseUrl' : 'ai.chat.baseUrl';
  String get _modelPath => widget.isEmbedding ? 'ai.embedding.model' : 'ai.chat.model';

  static String _credentialStorageLabel() {
    if (Platform.isWindows) return 'Windows 凭据管理器';
    if (Platform.isMacOS) return 'macOS 钥匙串';
    if (Platform.isAndroid) return 'Android 安全存储';
    return '本地加密存储';
  }

  @override
  void initState() {
    super.initState();
    _loadFromSettings();
  }

  @override
  void didUpdateWidget(covariant AiModelForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isEmbedding != widget.isEmbedding) {
      _statusMsg = null;
      _statusError = false;
      _apiKeyCtrl.clear();
      _loadFromSettings();
    }
  }

  void _loadFromSettings() {
    final s = ref.read(settingsProvider);
    _baseUrlCtrl.text = widget.isEmbedding ? s.embedBaseUrl : s.chatBaseUrl;
    _modelCtrl.text = widget.isEmbedding ? s.embedModel : s.chatModel;
    _fetchedModels = widget.isEmbedding ? const [] : _mergeModels([s.chatModels]);
    final existingKey = ref.read(credentialStoreProvider).read(_credTarget);
    _maskedCurrent = maskSecret(existingKey);
  }

  static List<String> _mergeModels(Iterable<Iterable<String>> sources) {
    final seen = <String>{};
    final out = <String>[];
    for (final list in sources) {
      for (final raw in list) {
        final m = raw.trim();
        if (m.isNotEmpty && seen.add(m)) {
          out.add(m);
        }
      }
    }
    return out;
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  String _effectiveApiKey() {
    final typed = _apiKeyCtrl.text.trim();
    if (typed.isNotEmpty) return typed;
    return ref.read(credentialStoreProvider).read(_credTarget) ?? '';
  }

  void _saveConfig() {
    final baseUrl = _baseUrlCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final typedKey = _apiKeyCtrl.text.trim();

    try {
      final ctl = ref.read(settingsProvider.notifier);
      final updates = <String, Object?>{
        _baseUrlPath: baseUrl,
        _modelPath: model,
      };
      if (!widget.isEmbedding) {
        final existing = ref.read(settingsProvider).chatModels;
        final merged = _mergeModels([
          if (model.isNotEmpty) [model],
          _fetchedModels,
          existing,
        ]);
        _fetchedModels = merged;
        updates['ai.chat.models'] = merged;
      }
      ctl.setMany(updates);

      final creds = ref.read(credentialStoreProvider);
      if (typedKey.isNotEmpty) {
        creds.write(_credTarget, typedKey);
        final verifiedKey = creds.read(_credTarget);
        if (verifiedKey != typedKey) {
          throw StateError('API Key 写入校验失败，未能持久保存');
        }
        _maskedCurrent = maskSecret(verifiedKey);
        _apiKeyCtrl.clear();
      } else {
        _maskedCurrent = maskSecret(creds.read(_credTarget));
      }

      final saved = ref.read(settingsProvider);
      final savedBase = widget.isEmbedding ? saved.embedBaseUrl : saved.chatBaseUrl;
      final savedModel = widget.isEmbedding ? saved.embedModel : saved.chatModel;
      if (savedBase != baseUrl || savedModel != model) {
        throw StateError('配置持久化校验失败');
      }

      if (widget.isEmbedding) {
        ref.read(embedIndexerProvider.notifier).refreshStatuses();
      }
      setState(() {
        _statusMsg = '配置已保存';
        _statusError = false;
      });
      ref.read(noticeProvider.notifier).show(widget.isEmbedding ? '嵌入模型配置已保存' : '对话模型配置已保存');
      widget.onSaved?.call();
    } catch (e, st) {
      Log.error('save AI config failed (embedding=${widget.isEmbedding})', e, st);
      if (mounted) {
        setState(() {
          _statusMsg = '保存配置失败：$e';
          _statusError = true;
        });
      }
      ref.read(noticeProvider.notifier).show('保存配置失败：$e', isError: true);
    }
  }

  void _clearKey() {
    try {
      ref.read(credentialStoreProvider).delete(_credTarget);
      _apiKeyCtrl.clear();
      setState(() {
        _maskedCurrent = '未配置';
        _statusMsg = '已清除保存的 API Key';
        _statusError = false;
      });
      if (widget.isEmbedding) {
        ref.read(embedIndexerProvider.notifier).refreshStatuses();
      }
    } catch (e, st) {
      Log.error('clear AI key failed', e, st);
      setState(() {
        _statusMsg = '清除 API Key 失败：$e';
        _statusError = true;
      });
    }
  }

  Future<void> _fetchModels() async {
    setState(() {
      _fetchingModels = true;
      _statusMsg = null;
    });
    try {
      final list = await _client.listModels(baseUrl: _baseUrlCtrl.text, apiKey: _effectiveApiKey());
      if (!mounted) return;
      if (!widget.isEmbedding && list.isNotEmpty) {
        final merged = _mergeModels([
          if (_modelCtrl.text.trim().isNotEmpty) [_modelCtrl.text.trim()],
          list,
          ref.read(settingsProvider).chatModels,
        ]);
        ref.read(settingsProvider.notifier).set('ai.chat.models', merged);
      }
      setState(() {
        _fetchedModels = list;
        _fetchingModels = false;
        _statusMsg = '已获取 ${list.length} 个模型';
        _statusError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetchingModels = false;
        _statusMsg = e.toString();
        _statusError = true;
      });
    }
  }

  Future<void> _testConnection() async {
    final base = _baseUrlCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final key = _effectiveApiKey();
    final allowEmptyKey = AiModelForm.isLocalBaseUrl(base);
    if (base.isEmpty || model.isEmpty || (!allowEmptyKey && key.isEmpty)) {
      setState(() {
        _statusMsg = '请先填写 Base URL、API Key 与模型名';
        _statusError = true;
      });
      return;
    }
    setState(() {
      _testing = true;
      _statusMsg = null;
    });
    try {
      if (widget.isEmbedding) {
        final r = await _client.testEmbedding(baseUrl: base, apiKey: key, model: model);
        if (!mounted) return;
        setState(() {
          _testing = false;
          _statusMsg = '连接成功：维度 ${r.dim}，耗时 ${r.elapsedMs} ms';
          _statusError = false;
        });
      } else {
        final ms = await _client.testChat(baseUrl: base, apiKey: key, model: model);
        if (!mounted) return;
        setState(() {
          _testing = false;
          _statusMsg = '连接成功：耗时 $ms ms';
          _statusError = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _statusMsg = e.toString();
        _statusError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider, (prev, next) {
      if (prev == null) return;
      final prevBase = widget.isEmbedding ? prev.embedBaseUrl : prev.chatBaseUrl;
      final nextBase = widget.isEmbedding ? next.embedBaseUrl : next.chatBaseUrl;
      if (prevBase != nextBase && _baseUrlCtrl.text.trim() == prevBase) {
        _baseUrlCtrl.text = nextBase;
      }
      final prevModel = widget.isEmbedding ? prev.embedModel : prev.chatModel;
      final nextModel = widget.isEmbedding ? next.embedModel : next.chatModel;
      if (prevModel != nextModel && _modelCtrl.text.trim() == prevModel) {
        _modelCtrl.text = nextModel;
      }
      if (!widget.isEmbedding && prev.chatModels != next.chatModels && mounted) {
        setState(() {
          _fetchedModels = _mergeModels([_fetchedModels, next.chatModels]);
        });
      }
    });

    final theme = FluentTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Base URL', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        TextBox(
          controller: _baseUrlCtrl,
          placeholder: widget.isEmbedding ? 'https://api.siliconflow.cn/v1' : 'https://api.openai.com/v1',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Text('API Key', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
            const SizedBox(width: 8),
            Text(
              '当前：$_maskedCurrent',
              style: TextStyle(
                fontSize: 11.5,
                color: _maskedCurrent == '未配置' ? theme.resources.textFillColorSecondary : Colors.green,
              ),
            ),
            const Spacer(),
            if (_maskedCurrent != '未配置')
              HyperlinkButton(
                onPressed: _clearKey,
                child: const Text('清除密钥', style: TextStyle(fontSize: 11.5)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        PasswordBox(
          controller: _apiKeyCtrl,
          placeholder: _maskedCurrent == '未配置'
              ? '输入 API Key（存入${_credentialStorageLabel()}）'
              : '留空保持已保存的密钥，或输入新密钥覆盖',
          revealMode: PasswordRevealMode.peek,
        ),
        const SizedBox(height: 10),
        const Text('模型名称', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: TextBox(
                controller: _modelCtrl,
                placeholder: widget.isEmbedding ? 'BAAI/bge-m3' : 'gpt-4o-mini / deepseek-chat / ...',
              ),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: _fetchingModels ? null : _fetchModels,
              child: Text(_fetchingModels ? '获取中…' : '获取模型列表'),
            ),
          ],
        ),
        if (_fetchedModels.isNotEmpty) ...[
          const SizedBox(height: 8),
          ComboBox<String>(
            isExpanded: true,
            placeholder: const Text('从服务器返回的模型中选择…'),
            value: _fetchedModels.contains(_modelCtrl.text) ? _modelCtrl.text : null,
            items: [
              for (final m in _fetchedModels) ComboBoxItem<String>(value: m, child: Text(m, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _modelCtrl.text = v);
            },
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Button(
              onPressed: _testing ? null : _testConnection,
              child: Text(_testing ? '测试中…' : '测试连接'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saveConfig,
              child: const Text('保存配置'),
            ),
          ],
        ),
        if (_statusMsg != null) ...[
          const SizedBox(height: 8),
          InfoBar(
            title: Text(_statusError ? '提示' : '成功'),
            content: Text(_statusMsg!),
            severity: _statusError ? InfoBarSeverity.error : InfoBarSeverity.success,
          ),
        ],
      ],
    );
  }
}
