import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ask/chat_models.dart';
import '../../features/ask/chat_repository.dart';
import '../../features/library/document.dart';
import 'app_database.dart';
import 'document_repository.dart';

/// The single on-device database instance for the app's lifetime.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Maps the database to/from [CuraDocument]; the only data entry point the UI
/// touches for reads and writes.
final documentRepositoryProvider = Provider<DocumentRepository>((ref) {
  return DocumentRepository(ref.watch(databaseProvider));
});

/// Live list of saved documents (newest first). The UI watches this; the stream
/// re-emits automatically on every add / edit / delete.
final documentsProvider = StreamProvider<List<CuraDocument>>((ref) {
  return ref.watch(documentRepositoryProvider).watchDocuments();
});

/// Persists Ask conversations.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(ref.watch(databaseProvider));
});

/// Live list of saved chat sessions (most recent first) — drives the history.
final chatSessionsProvider = StreamProvider<List<ChatSession>>((ref) {
  return ref.watch(chatRepositoryProvider).watchSessions();
});
