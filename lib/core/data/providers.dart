import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ask/chat_models.dart';
import '../../features/ask/chat_repository.dart';
import '../../features/library/document.dart';
import '../../features/reminders/reminder.dart';
import 'app_database.dart';
import 'document_repository.dart';
import 'reminder_repository.dart';

/// App DB singleton.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Document CRUD for the UI.
final documentRepositoryProvider = Provider<DocumentRepository>((ref) {
  return DocumentRepository(ref.watch(databaseProvider));
});

/// Live documents (newest first).
final documentsProvider = StreamProvider<List<CuraDocument>>((ref) {
  return ref.watch(documentRepositoryProvider).watchDocuments();
});

/// Ask chat persistence.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(ref.watch(databaseProvider));
});

/// Live chat sessions.
final chatSessionsProvider = StreamProvider<List<ChatSession>>((ref) {
  return ref.watch(chatRepositoryProvider).watchSessions();
});

/// Reminder CRUD.
final reminderRepositoryProvider = Provider<ReminderRepository>((ref) {
  return ReminderRepository(ref.watch(databaseProvider));
});

/// Live reminders stream.
final remindersProvider = StreamProvider<List<MedicineReminder>>((ref) {
  return ref.watch(reminderRepositoryProvider).watchAll();
});
