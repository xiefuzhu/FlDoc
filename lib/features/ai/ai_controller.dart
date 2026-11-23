import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/log.dart';
import '../library/library_controller.dart';
import '../library/models.dart';
import '../reader/navigation/navigation_controller.dart';
import '../search/models.dart';
import '../search/rg/rg_service.dart';
import '../search/symbols/symbol_index.dart';
import '../settings/credential_store.dart';
import '../settings/settings_controller.dart';
import 'client/openai_client.dart';
import 'history/chat_history.dart';
import 'index/embed_indexer.dart';
import 'retrieval/hybrid_retriever.dart';

enum AiConfigStatus { ok, bothMissing, chatMissing, embedMissing }

class AiPanelState {
  const AiPanelState({
    this.visible = false,
    this.session,
    this.messages = const [],
    this.scope = SearchScope.currentLibrary,
    this.streaming = false,
    this.streamingContent = '',
    this.streamingReasoning = '',
    this.streamingCitations = const [],
    this.vectorNotice,
    this.error,
    this.errorKind,
    this.lastQuestion,
    this.focusPage,
  });

  final bool visible;
  final ChatSessionModel? session;
  final List<ChatMessageModel> messages;
  final SearchScope scope;
  final bool streaming;
  final String streamingContent;
  final String streamingReasoning;
  final List<ChatCitation> streamingCitations;
  final String? vectorNotice;
  final String? error;
  final AiErrorKind? errorKind;
  final String? lastQuestion;
  final DocLocation? focusPage;

  AiPanelState copyWith({
    bool? visible,
    ChatSessionModel? session,
    bool clearSession = false,
    List<ChatMessageModel>? messages,
    SearchScope? scope,
    bool? streaming,
    String? streamingContent,
    String? streamingReasoning,
    List<ChatCitation>? streamingCitations,
    String? vectorNotice,
    bool clearVectorNotice = false,
    String? error,
    AiErrorKind? errorKind,
    bool clearError = false,
    String? lastQuestion,
    DocLocation? focusPage,
    bool clearFocusPage = false,
  }) =>
      AiPanelState(
        visible: visible ?? this.visible,
        session: clearSession ? null : (session ?? this.session),
        messages: messages ?? this.messages,
        scope: scope ?? this.scope,
        streaming: streaming ?? this.streaming,
        streamingContent: streamingContent ?? this.streamingContent,
        streamingReasoning: streamingReasoning ?? this.streamingReasoning,
        streamingCitations: streamingCitations ?? this.streamingCitations,
        vectorNotice: clearVectorNotice ? null : (vectorNotice ?? this.vectorNotice),
        error: clearError ? null : (error ?? this.error),
        errorKind: clearError ? null : (errorKind ?? this.errorKind),
        lastQuestion: lastQuestion ?? this.lastQuestion,
        focusPage: clearFocusPage ? null : (focusPage ?? this.focusPage),
      );
}

final chatHistoryRepoProvider = Provider<ChatHistoryRepo>((ref) {
  return ChatHistoryRepo(ref.watch(databaseProvider));
});

final aiControllerProvider = NotifierProvider<AiController, AiPanelState>(AiController.new);

class AiController extends Notifier<AiPanelState> {
  final OpenAiClient _client = OpenAiClient();
  AiCancelToken? _cancel;

  @override
  AiPanelState build() {
    final ui = ref.read(uiStateProvider);
    final defScope = ref.read(settingsProvider).defaultScope == 'allLibraries'
        ? SearchScope.allLibraries
        : SearchScope.currentLibrary;
    return AiPanelState(visible: ui.aiPanelVisible, scope: defScope);
  }

  /// Evaluates whether Chat and/or Embedding models are configured (spec 06 §8).
  AiConfigStatus checkConfig() {
    final s = ref.read(settingsProvider);
    final creds = ref.read(credentialStoreProvider);
    final chatKey = creds.read(CredentialStore.chatTarget) ?? '';
    final embedKey = creds.read(CredentialStore.embeddingTarget) ?? '';
    final chatLocal = OpenAiClient.isLocalBaseUrl(s.chatBaseUrl);
    final embedLocal = OpenAiClient.isLocalBaseUrl(s.embedBaseUrl);
    final hasChat = s.chatBaseUrl.trim().isNotEmpty && s.chatModel.trim().isNotEmpty && (chatLocal || chatKey.trim().isNotEmpty);
    final hasEmbed = s.embedBaseUrl.trim().isNotEmpty && s.embedModel.trim().isNotEmpty && (embedLocal || embedKey.trim().isNotEmpty);
    if (!hasChat && !hasEmbed) return AiConfigStatus.bothMissing;
    if (!hasChat) return AiConfigStatus.chatMissing;
    if (!hasEmbed) return AiConfigStatus.embedMissing;
    return AiConfigStatus.ok;
  }

  /// Fetches remote chat models and persists them to `ai.chat.models`.
  Future<List<String>> refreshChatModels() async {
    final s = ref.read(settingsProvider);
    if (s.chatBaseUrl.trim().isEmpty) {
      throw const AiException(AiErrorKind.invalidResponse, '请先在设置中填写对话模型 Base URL');
    }
    final key = ref.read(credentialStoreProvider).read(CredentialStore.chatTarget) ?? '';
    final fetched = await _client.listModels(baseUrl: s.chatBaseUrl, apiKey: key);
    final seen = <String>{};
    final merged = <String>[];
    for (final raw in [
      if (s.chatModel.trim().isNotEmpty) s.chatModel.trim(),
      ...fetched,
      ...s.chatModels,
    ]) {
      final m = raw.trim();
      if (m.isNotEmpty && seen.add(m)) merged.add(m);
    }
    ref.read(settingsProvider.notifier).set('ai.chat.models', merged);
    return merged;
  }

  void togglePanel() => setVisible(!state.visible);

  void setVisible(bool v) {
    ref.read(uiStateProvider).aiPanelVisible = v;
    state = state.copyWith(visible: v);
  }

  void setScope(SearchScope scope) => state = state.copyWith(scope: scope);

  void newChat({DocLocation? focusPage}) {
    stop();
    state = state.copyWith(
      clearSession: true,
      messages: const [],
      streamingContent: '',
      streamingReasoning: '',
      streamingCitations: const [],
      clearVectorNotice: true,
      clearError: true,
      focusPage: focusPage,
      clearFocusPage: focusPage == null,
    );
  }

  void loadSession(ChatSessionModel session) {
    stop();
    final repo = ref.read(chatHistoryRepoProvider);
    final msgs = repo.loadMessages(session.id);
    state = state.copyWith(
      visible: true,
      session: session,
      messages: msgs,
      scope: session.scope.all ? SearchScope.allLibraries : SearchScope.currentLibrary,
      streamingContent: '',
      streamingReasoning: '',
      streamingCitations: const [],
      clearVectorNotice: true,
      clearError: true,
      clearFocusPage: true,
    );
    ref.read(uiStateProvider).aiPanelVisible = true;
  }

  void deleteCurrentSession() {
    final sess = state.session;
    if (sess != null) {
      ref.read(chatHistoryRepoProvider).deleteSession(sess.id);
    }
    newChat();
  }

  void deleteSessionById(String sessionId) {
    ref.read(chatHistoryRepoProvider).deleteSession(sessionId);
    if (state.session?.id == sessionId) {
      newChat();
    }
  }

  void stop() {
    _cancel?.cancel();
    _cancel = null;
    if (state.streaming) {
      _finalizeStreaming(stopped: true);
    }
  }

  /// Performs hybrid AI search (used by `search.ai` command palette submode).
  Future<HybridSearchResult> hybridSearch(
    String query, {
    required SearchScope scope,
    RgCancelToken? cancelToken,
  }) async {
    final s = ref.read(settingsProvider);
    final creds = ref.read(credentialStoreProvider);
    final libs = ref.read(libraryProvider).libraries;
    final nav = ref.read(navigationProvider);
    final curLib = nav.page?.lib ?? (libs.isNotEmpty ? libs.first : null);
    final curVer = nav.page?.version ?? curLib?.defaultVersion;

    final retriever = HybridRetriever(
      rgService: ref.read(rgServiceProvider),
      symbolIndex: ref.read(symbolIndexProvider),
      client: _client,
    );

    return retriever.retrieve(
      query: query,
      libraries: libs,
      scope: scope,
      currentLibrary: curLib,
      currentVersion: curVer,
      currentLang: s.language,
      rewriteEnabled: s.rewriteQuery,
      chatBaseUrl: s.chatBaseUrl,
      chatApiKey: creds.read(CredentialStore.chatTarget) ?? '',
      chatModel: s.chatModel,
      vectorSearcher: (q) => ref.read(embedIndexerProvider.notifier).searchVectors(
            query: q,
            libraries: libs,
            currentLibrary: curLib,
            currentVersion: curVer,
            allLibraries: scope == SearchScope.allLibraries || curLib == null,
          ),
      cancelToken: cancelToken,
    );
  }

  /// Sends a RAG question in the AI panel (or from `ai.ask` / `ai.askAboutPage`).
  Future<void> ask(String question, {DocLocation? focusPage, List<RetrievedChunk>? preRetrieved}) async {
    final q = question.trim();
    if (q.isEmpty) return;
    if (state.streaming) stop();

    setVisible(true);
    final s = ref.read(settingsProvider);
    final creds = ref.read(credentialStoreProvider);
    final chatKey = creds.read(CredentialStore.chatTarget) ?? '';
    final chatLocal = OpenAiClient.isLocalBaseUrl(s.chatBaseUrl);
    if (s.chatBaseUrl.trim().isEmpty || s.chatModel.trim().isEmpty || (!chatLocal && chatKey.trim().isEmpty)) {
      state = state.copyWith(
        error: '尚未配置对话模型，请先在设置中填写 Base URL、API Key 与模型',
        errorKind: AiErrorKind.unauthorized,
        lastQuestion: q,
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final libs = ref.read(libraryProvider).libraries;
    final nav = ref.read(navigationProvider);
    final curLib = nav.page?.lib ?? (libs.isNotEmpty ? libs.first : null);
    final curVer = nav.page?.version ?? curLib?.defaultVersion;

    var session = state.session;
    final effectiveFocus = focusPage ?? state.focusPage;
    if (session == null) {
      final title = q.length > 28 ? '${q.substring(0, 28)}…' : q;
      session = ChatSessionModel(
        id: 'chat_$now',
        title: title,
        scope: ChatScope(
          libId: state.scope == SearchScope.currentLibrary ? curLib?.key : null,
          versionId: state.scope == SearchScope.currentLibrary ? curVer?.id : null,
          all: state.scope == SearchScope.allLibraries,
        ),
        createdAt: now,
        updatedAt: now,
      );
      if (s.saveHistory) {
        ref.read(chatHistoryRepoProvider).upsertSession(session);
      }
    }

    final userMsg = ChatMessageModel(sessionId: session.id, role: 'user', content: q, createdAt: now);
    final priorMessages = List<ChatMessageModel>.of(state.messages);
    final updatedMessages = [...priorMessages, userMsg];
    if (s.saveHistory) {
      ref.read(chatHistoryRepoProvider).addMessage(userMsg);
    }

    final cancel = AiCancelToken();
    _cancel = cancel;

    state = state.copyWith(
      session: session,
      messages: updatedMessages,
      streaming: true,
      streamingContent: '',
      streamingReasoning: '',
      streamingCitations: const [],
      clearError: true,
      clearVectorNotice: true,
      lastQuestion: q,
      focusPage: effectiveFocus,
    );

    try {
      // 1. Multi-turn standalone query rewrite (last 3 turns, temperature 0).
      var retrievalQuery = q;
      if (preRetrieved == null && priorMessages.isNotEmpty) {
        final recent = priorMessages.length > 6 ? priorMessages.sublist(priorMessages.length - 6) : priorMessages;
        try {
          final historyText = recent.map((m) => '${m.role == 'user' ? '用户' : '助手'}：${m.content}').join('\n');
          final rewritten = await _client.chatComplete(
            baseUrl: s.chatBaseUrl,
            apiKey: chatKey,
            model: s.chatModel,
            messages: [
              {
                'role': 'system',
                'content': '根据对话历史把用户的最新追问改写为一个独立、完整的检索问题。只输出改写后的问题本身，不要解释。',
              },
              {'role': 'user', 'content': '历史：\n$historyText\n\n最新问题：$q'},
            ],
            temperature: 0.0,
            maxTokens: 160,
            timeout: const Duration(seconds: 15),
          );
          if (rewritten.trim().isNotEmpty) retrievalQuery = rewritten.trim();
        } catch (e) {
          Log.warn('multi-turn rewrite skipped: $e');
        }
      }

      if (cancel.isCancelled) return;

      // 2. Hybrid retrieval (unless pre-retrieved chunks were handed over from AI search).
      List<RetrievedChunk> retrieved;
      String? vectorNotice;
      if (preRetrieved != null) {
        retrieved = preRetrieved;
      } else {
        final retriever = HybridRetriever(
          rgService: ref.read(rgServiceProvider),
          symbolIndex: ref.read(symbolIndexProvider),
          client: _client,
        );
        final res = await retriever.retrieve(
          query: retrievalQuery,
          libraries: libs,
          scope: state.scope,
          currentLibrary: curLib,
          currentVersion: curVer,
          currentLang: s.language,
          rewriteEnabled: s.rewriteQuery,
          chatBaseUrl: s.chatBaseUrl,
          chatApiKey: chatKey,
          chatModel: s.chatModel,
          focusPage: effectiveFocus,
          vectorSearcher: (rq) => ref.read(embedIndexerProvider.notifier).searchVectors(
                query: rq,
                libraries: libs,
                currentLibrary: curLib,
                currentVersion: curVer,
                allLibraries: state.scope == SearchScope.allLibraries || curLib == null,
              ),
          limit: s.ragTopK.clamp(1, 20),
        );
        retrieved = res.chunks;
        vectorNotice = res.vectorNotice;
      }

      if (cancel.isCancelled) return;

      // 3. Assemble numbered context [1]..[n] respecting contextWindow tier (274k / 500k).
      final is500k = s.chatContextWindow == 500000;
      final citations = <ChatCitation>[];
      final ctxBuf = StringBuffer();
      var chars = 0;
      final maxChars = is500k
          ? math.max(s.ragMaxContextChars, 48000).clamp(1000, 160000)
          : math.max(s.ragMaxContextChars, 24000).clamp(1000, 80000);
      final topChunks = retrieved.take(s.ragTopK.clamp(1, 20)).toList();

      for (final ch in topChunks) {
        final idx = citations.length + 1;
        var snippet = ch.text.trim();
        if (chars + snippet.length > maxChars) {
          final remain = maxChars - chars;
          if (remain < 120) break;
          snippet = '${snippet.substring(0, remain)}…';
        }
        chars += snippet.length;
        ctxBuf.writeln('[$idx] ${ch.libName} / ${ch.pageTitle} / ${ch.breadcrumb}');
        ctxBuf.writeln(snippet);
        ctxBuf.writeln();
        citations.add(ChatCitation(
          index: idx,
          libKey: ch.libKey,
          libName: ch.libName,
          versionId: ch.versionId,
          page: ch.page,
          anchor: ch.anchor,
          title: ch.pageTitle,
          breadcrumb: ch.breadcrumb,
          snippet: snippet.length > 260 ? '${snippet.substring(0, 260)}…' : snippet,
        ));
      }

      state = state.copyWith(
        streamingCitations: citations,
        vectorNotice: vectorNotice,
      );

      // 4. Build system + bounded prior history messages + current user question.
      final systemPrompt = '''你是 flDoc 文档助手。只依据下面提供的文档片段回答用户问题，使用简体中文。
规则：
1. 每个事实陈述后用 [编号] 标注出处，编号对应片段编号；可以标多个，如 [1][3]。
2. 片段不足以回答时，明确说明「文档中未找到相关内容」，并给出可能相关的片段编号；不要编造 API 或参数。
3. 代码示例优先使用片段中的原始代码，使用围栏代码块并标注语言。
4. 回答简洁，先给结论再给步骤。

文档片段：
${ctxBuf.isEmpty ? '（未检索到相关文档片段）' : ctxBuf.toString()}''';

      final apiMessages = <Map<String, String>>[
        {'role': 'system', 'content': systemPrompt},
      ];
      final maxHistoryMsgs = is500k ? 32 : 16;
      final maxHistoryChars = is500k ? 120000 : 60000;
      final selectedHistory = <ChatMessageModel>[];
      var historyChars = 0;
      for (var i = priorMessages.length - 1; i >= 0 && selectedHistory.length < maxHistoryMsgs; i--) {
        final hm = priorMessages[i];
        if (historyChars + hm.content.length > maxHistoryChars && selectedHistory.isNotEmpty) break;
        historyChars += hm.content.length;
        selectedHistory.add(hm);
      }
      for (final hm in selectedHistory.reversed) {
        apiMessages.add({'role': hm.role, 'content': hm.content});
      }
      apiMessages.add({'role': 'user', 'content': q});

      // 5. Stream SSE completion.
      final contentBuf = StringBuffer();
      final reasoningBuf = StringBuffer();
      await for (final delta in _client.streamChat(
        baseUrl: s.chatBaseUrl,
        apiKey: chatKey,
        model: s.chatModel,
        messages: apiMessages,
        temperature: s.chatTemperature,
        maxTokens: s.chatMaxTokens,
        reasoningEffort: s.chatReasoningEffort,
        cancelToken: cancel,
      )) {
        if (cancel.isCancelled) break;
        if (delta.content.isNotEmpty) contentBuf.write(delta.content);
        if (delta.reasoning.isNotEmpty) reasoningBuf.write(delta.reasoning);
        state = state.copyWith(
          streamingContent: contentBuf.toString(),
          streamingReasoning: reasoningBuf.toString(),
        );
      }

      if (!cancel.isCancelled) {
        _finalizeStreaming(stopped: false);
      }
    } on AiException catch (e) {
      if (e.kind == AiErrorKind.cancelled) {
        _finalizeStreaming(stopped: true);
      } else {
        state = state.copyWith(
          streaming: false,
          error: e.message,
          errorKind: e.kind,
        );
      }
    } catch (e, st) {
      Log.error('RAG ask failed', e, st);
      state = state.copyWith(
        streaming: false,
        error: '回答生成失败：$e',
        errorKind: AiErrorKind.network,
      );
    } finally {
      if (_cancel == cancel) _cancel = null;
    }
  }

  void _finalizeStreaming({required bool stopped}) {
    final sess = state.session;
    final content = state.streamingContent.trim();
    final reasoning = state.streamingReasoning.trim();
    if (sess == null || (content.isEmpty && reasoning.isEmpty)) {
      state = state.copyWith(streaming: false, streamingContent: '', streamingReasoning: '');
      return;
    }
    final finalText = stopped ? '$content\n\n*（已停止生成）*' : content;
    final assistantMsg = ChatMessageModel(
      sessionId: sess.id,
      role: 'assistant',
      content: finalText,
      reasoning: reasoning,
      citations: state.streamingCitations,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (ref.read(settingsProvider).saveHistory) {
      ref.read(chatHistoryRepoProvider).addMessage(assistantMsg);
    }
    state = state.copyWith(
      messages: [...state.messages, assistantMsg],
      streaming: false,
      streamingContent: '',
      streamingReasoning: '',
      streamingCitations: const [],
    );
  }

  Future<void> retryLast() async {
    final q = state.lastQuestion;
    if (q == null || q.isEmpty) return;
    // Remove trailing user message if it has no assistant reply yet.
    if (state.messages.isNotEmpty && state.messages.last.role == 'user') {
      state = state.copyWith(messages: state.messages.sublist(0, state.messages.length - 1), clearError: true);
    }
    await ask(q);
  }
}
