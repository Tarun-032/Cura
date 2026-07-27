import 'package:drift/drift.dart';

import '../../core/data/app_database.dart';
import 'chat_models.dart';

/// Persists Ask conversations in the on-device database. The screen only sees
/// [ChatSession] / [StoredMessage]; Drift never leaks into the feature layer.
class ChatRepository {
  ChatRepository(this._db);

  final AppDatabase _db;

  /// Last id handed out. `createdAt` has second resolution, so the id is what
  /// orders (and keeps apart) two messages written in the same second.
  int _lastStamp = 0;

  String _nextMessageId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _lastStamp = now > _lastStamp ? now : _lastStamp + 1;
    return 'msg-$_lastStamp';
  }

  /// Live list of saved sessions, most recently updated first.
  Stream<List<ChatSession>> watchSessions() {
    final query = _db.select(_db.chatSessions)
      ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]);
    return query.watch().map((rows) => rows.map(_toSession).toList());
  }

  /// The most recently updated session, or null if there are none.
  Future<ChatSession?> mostRecentSession() async {
    final query = _db.select(_db.chatSessions)
      ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _toSession(row);
  }

  /// Creates a new conversation with [title].
  Future<ChatSession> createSession(String title) async {
    final now = DateTime.now();
    final session = ChatSession(
      id: 'chat-${now.microsecondsSinceEpoch}',
      title: title,
      createdAt: now,
      updatedAt: now,
    );
    await _db.into(_db.chatSessions).insert(ChatSessionsCompanion(
          id: Value(session.id),
          title: Value(session.title),
          createdAt: Value(session.createdAt),
          updatedAt: Value(session.updatedAt),
        ));
    return session;
  }

  /// Messages in a session, oldest first.
  Future<List<StoredMessage>> loadMessages(String sessionId) async {
    final query = _db.select(_db.chatMessages)
      ..where((m) => m.sessionId.equals(sessionId))
      ..orderBy([
        (m) => OrderingTerm.asc(m.createdAt),
        (m) => OrderingTerm.asc(m.id),
      ]);
    final rows = await query.get();
    return rows.map(_toMessage).toList();
  }

  /// Appends a message and bumps the session's `updatedAt`.
  Future<void> addMessage(
    String sessionId,
    ChatRole role,
    String text, {
    String? sourceDocId,
  }) async {
    final now = DateTime.now();
    await _db.into(_db.chatMessages).insert(ChatMessagesCompanion(
          id: Value(_nextMessageId()),
          sessionId: Value(sessionId),
          role: Value(role.name),
          content: Value(text),
          sourceDocId: Value(sourceDocId),
          createdAt: Value(now),
        ));
    await (_db.update(_db.chatSessions)
          ..where((s) => s.id.equals(sessionId)))
        .write(ChatSessionsCompanion(updatedAt: Value(now)));
  }

  /// Removes the newest [count] messages, for a question being re-asked.
  Future<void> deleteTrailingMessages(String sessionId, int count) async {
    if (count <= 0) return;
    final doomed = _db.select(_db.chatMessages)
      ..where((m) => m.sessionId.equals(sessionId))
      ..orderBy([
        (m) => OrderingTerm.desc(m.createdAt),
        (m) => OrderingTerm.desc(m.id),
      ])
      ..limit(count);
    final ids = [for (final row in await doomed.get()) row.id];
    if (ids.isEmpty) return;
    await (_db.delete(_db.chatMessages)..where((m) => m.id.isIn(ids))).go();
  }

  /// Deletes a session and all its messages.
  Future<void> deleteSession(String sessionId) async {
    await (_db.delete(_db.chatMessages)
          ..where((m) => m.sessionId.equals(sessionId)))
        .go();
    await (_db.delete(_db.chatSessions)..where((s) => s.id.equals(sessionId)))
        .go();
  }

  ChatSession _toSession(ChatSessionRow row) => ChatSession(
        id: row.id,
        title: row.title,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );

  StoredMessage _toMessage(ChatMessageRow row) => StoredMessage(
        id: row.id,
        role: row.role == 'assistant' ? ChatRole.assistant : ChatRole.user,
        text: row.content,
        sourceDocId: row.sourceDocId,
        createdAt: row.createdAt,
      );
}
