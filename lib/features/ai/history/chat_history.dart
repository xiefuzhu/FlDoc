import 'dart:convert';

import '../../../core/database.dart';

class ChatCitation {
  const ChatCitation({
    required this.index,
    required this.libKey,
    required this.libName,
    required this.versionId,
    required this.page,
    required this.anchor,
    required this.title,
    required this.breadcrumb,
    required this.snippet,
  });

  final int index; // 1-based [1]..[n]
  final String libKey;
  final String libName;
  final String versionId;
  final String page;
  final String anchor;
  final String title;
  final String breadcrumb;
  final String snippet;

  Map<String, dynamic> toJson() => {
        'index': index,
        'libId': libKey,
        'libName': libName,
        'versionId': versionId,
        'page': page,
        'anchor': anchor,
        'title': title,
        'breadcrumb': breadcrumb,
        'snippet': snippet,
      };

  static ChatCitation fromJson(Map<String, dynamic> j) => ChatCitation(
        index: (j['index'] as num?)?.toInt() ?? 1,
        libKey: j['libId'] as String? ?? '',
        libName: j['libName'] as String? ?? '',
        versionId: j['versionId'] as String? ?? '',
        page: j['page'] as String? ?? '',
        anchor: j['anchor'] as String? ?? '',
        title: j['title'] as String? ?? '',
        breadcrumb: j['breadcrumb'] as String? ?? '',
        snippet: j['snippet'] as String? ?? '',
      );
}

class ChatMessageModel {
  const ChatMessageModel({
    this.id,
    required this.sessionId,
    required this.role, // 'user' | 'assistant'
    required this.content,
    this.reasoning = '',
    this.citations = const [],
    required this.createdAt,
  });

  final int? id;
  final String sessionId;
  final String role;
  final String content;
  final String reasoning;
  final List<ChatCitation> citations;
  final int createdAt;

  ChatMessageModel copyWith({String? content, String? reasoning, List<ChatCitation>? citations}) => ChatMessageModel(
        id: id,
        sessionId: sessionId,
        role: role,
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        citations: citations ?? this.citations,
        createdAt: createdAt,
      );
}

class ChatScope {
  const ChatScope({this.libId, this.versionId, this.all = false});

  final String? libId;
  final String? versionId;
  final bool all;

  Map<String, dynamic> toJson() => {'libId': libId, 'versionId': versionId, 'all': all};

  static ChatScope fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const ChatScope(all: false);
    try {
      final j = jsonDecode(raw);
      if (j is Map) {
        return ChatScope(
          libId: j['libId'] as String?,
          versionId: j['versionId'] as String?,
          all: j['all'] == true,
        );
      }
    } catch (_) {}
    return const ChatScope(all: false);
  }
}

class ChatSessionModel {
  const ChatSessionModel({
    required this.id,
    required this.title,
    required this.scope,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final ChatScope scope;
  final int createdAt;
  final int updatedAt;
}

/// SQLite persistence for AI chat sessions and messages (doc 02 §4.1 & 06 §5.3).
class ChatHistoryRepo {
  ChatHistoryRepo(this.db);

  final AppDatabase db;

  void upsertSession(ChatSessionModel s) {
    db.db.execute(
      'INSERT OR REPLACE INTO chat_session (id, title, scope, created_at, updated_at) VALUES (?,?,?,?,?)',
      [s.id, s.title, jsonEncode(s.scope.toJson()), s.createdAt, s.updatedAt],
    );
  }

  void addMessage(ChatMessageModel m) {
    final cits = jsonEncode([for (final c in m.citations) c.toJson()]);
    db.db.execute(
      'INSERT INTO chat_message (session_id, role, content, citations, created_at) VALUES (?,?,?,?,?)',
      [m.sessionId, m.role, m.content, cits, m.createdAt],
    );
    db.db.execute('UPDATE chat_session SET updated_at=? WHERE id=?', [m.createdAt, m.sessionId]);
  }

  List<ChatSessionModel> listSessions({String? query}) {
    final q = query?.trim().toLowerCase() ?? '';
    final rs = db.db.select('SELECT id, title, scope, created_at, updated_at FROM chat_session ORDER BY updated_at DESC');
    final all = <ChatSessionModel>[
      for (final r in rs)
        ChatSessionModel(
          id: r['id'] as String,
          title: r['title'] as String? ?? '新对话',
          scope: ChatScope.fromJson(r['scope'] as String?),
          createdAt: (r['created_at'] as num?)?.toInt() ?? 0,
          updatedAt: (r['updated_at'] as num?)?.toInt() ?? 0,
        ),
    ];
    if (q.isEmpty) return all;
    // Match title or message contents.
    final matchingIds = <String>{};
    for (final s in all) {
      if (s.title.toLowerCase().contains(q)) matchingIds.add(s.id);
    }
    final mrs = db.db.select(
      'SELECT DISTINCT session_id FROM chat_message WHERE LOWER(content) LIKE ?',
      ['%$q%'],
    );
    for (final r in mrs) {
      final sid = r['session_id'] as String?;
      if (sid != null) matchingIds.add(sid);
    }
    return all.where((s) => matchingIds.contains(s.id)).toList();
  }

  List<ChatMessageModel> loadMessages(String sessionId) {
    final rs = db.db.select(
      'SELECT id, session_id, role, content, citations, created_at FROM chat_message WHERE session_id=? ORDER BY id ASC',
      [sessionId],
    );
    return [
      for (final r in rs)
        ChatMessageModel(
          id: (r['id'] as num?)?.toInt(),
          sessionId: r['session_id'] as String,
          role: r['role'] as String,
          content: r['content'] as String? ?? '',
          citations: _parseCitations(r['citations'] as String?),
          createdAt: (r['created_at'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  void deleteSession(String sessionId) {
    db.db.execute('DELETE FROM chat_message WHERE session_id=?', [sessionId]);
    db.db.execute('DELETE FROM chat_session WHERE id=?', [sessionId]);
  }

  List<ChatCitation> _parseCitations(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return [for (final item in list.whereType<Map<String, dynamic>>()) ChatCitation.fromJson(item)];
      }
    } catch (_) {}
    return const [];
  }
}
