import 'package:cura/core/data/app_database.dart';
import 'package:cura/features/ask/chat_models.dart';
import 'package:cura/features/ask/chat_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Re-asking a question drops its old turn; everything before must survive.
void main() {
  late AppDatabase database;
  late ChatRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = ChatRepository(database);
  });

  tearDown(() => database.close());

  Future<ChatSession> seed() async {
    final session = await repository.createSession('Blood work');
    for (final turn in [
      (ChatRole.user, 'What is my haemoglobin?'),
      (ChatRole.assistant, 'It is 14.2 g/dL.'),
      (ChatRole.user, 'What is my hemglobin trend?'),
      (ChatRole.assistant, 'It has been stable.'),
    ]) {
      await repository.addMessage(session.id, turn.$1, turn.$2);
    }
    return session;
  }

  test('deleting the trailing turn leaves the earlier thread intact', () async {
    final session = await seed();

    await repository.deleteTrailingMessages(session.id, 2);

    final left = await repository.loadMessages(session.id);
    expect(left.map((m) => m.text), [
      'What is my haemoglobin?',
      'It is 14.2 g/dL.',
    ]);
  });

  test('the session header survives a truncation', () async {
    final session = await seed();

    await repository.deleteTrailingMessages(session.id, 2);

    final sessions = await repository.watchSessions().first;
    expect(sessions.single.id, session.id);
    expect(sessions.single.title, 'Blood work');
  });

  test('a count of zero or less changes nothing', () async {
    final session = await seed();

    await repository.deleteTrailingMessages(session.id, 0);
    await repository.deleteTrailingMessages(session.id, -3);

    expect(await repository.loadMessages(session.id), hasLength(4));
  });

  test('a count past the start empties the thread without error', () async {
    final session = await seed();

    await repository.deleteTrailingMessages(session.id, 99);

    expect(await repository.loadMessages(session.id), isEmpty);
  });

  test('another conversation is untouched', () async {
    final session = await seed();
    final other = await repository.createSession('Ultrasound');
    await repository.addMessage(other.id, ChatRole.user, 'Explain the scan');

    await repository.deleteTrailingMessages(session.id, 4);

    expect(await repository.loadMessages(other.id), hasLength(1));
  });
}
