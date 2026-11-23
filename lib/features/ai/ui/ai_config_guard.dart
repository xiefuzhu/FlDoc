import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../reader/navigation/navigation_controller.dart';
import '../ai_controller.dart';

/// Checks AI configuration and shows a guided dialog if missing (doc 06 §8).
/// Returns true if the caller can proceed.
Future<bool> ensureAiReady(
  BuildContext context,
  WidgetRef ref, {
  required bool requireChat,
}) async {
  final status = ref.read(aiControllerProvider.notifier).checkConfig();
  if (status == AiConfigStatus.ok) return true;
  if (status == AiConfigStatus.embedMissing) {
    // Allowed to proceed; hybrid retrieval will gracefully degrade and notify.
    return true;
  }
  if (!requireChat && status == AiConfigStatus.chatMissing) {
    // AI Smart Search can still run with vector + tokenized rg when only chat is missing.
    return true;
  }

  final isBoth = status == AiConfigStatus.bothMissing;
  final goConfig = await showDialog<bool>(
    context: context,
    builder: (ctx) => ContentDialog(
      title: Text(isBoth ? '尚未配置 AI' : '尚未配置对话模型'),
      content: Text(
        isBoth
            ? '使用 AI 智能搜索与文档问答前，需要先配置对话模型或嵌入模型（API Key 将安全保存在 Windows 凭据管理器中）。'
            : 'RAG 问答需要配置 OpenAI 兼容的对话模型（Base URL、API Key 与模型名）。',
      ),
      actions: [
        Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去配置')),
      ],
    ),
  );
  if (goConfig == true) {
    ref.read(navigationProvider.notifier).openSettings(section: 'ai');
  }
  return false;
}
