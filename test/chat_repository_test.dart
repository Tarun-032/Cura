import 'package:cura/core/data/app_database.dart';
import 'package:cura/features/ask/chat_models.dart';
import 'package:cura/features/ask/chat_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Re-asking drops the old turn.
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

  test('a model notice survives the round trip on the same schema', () async {
    final session = await repository.createSession('Blood work');
    await repository.addMessage(session.id, ChatRole.notice, 'LFM2.5 (1.2B)');
    await repository.addMessage(session.id, ChatRole.user, 'Anything odd?');

    final saved = await repository.loadMessages(session.id);
    expect(saved.first.role, ChatRole.notice);
    expect(saved.first.text, 'LFM2.5 (1.2B)');
    expect(lastRecordedModel(saved), 'LFM2.5 (1.2B)');
  });

  test('a notice counts as one row when a question is re-asked', () async {
    final session = await repository.createSession('Blood work');
    for (final turn in [
      (ChatRole.notice, 'LFM2.5 (1.2B)'),
      (ChatRole.user, 'What is my haemoglobin?'),
      (ChatRole.assistant, 'It is 14.2 g/dL.'),
      (ChatRole.notice, 'openai/gpt-oss-120b'),
      (ChatRole.user, 'Say that again'),
      (ChatRole.assistant, 'It is 14.2 g/dL.'),
    ]) {
      await repository.addMessage(session.id, turn.$1, turn.$2);
    }

    // Re-asking the second question drops it and its answer, and nothing else.
    await repository.deleteTrailingMessages(session.id, 2);

    final left = await repository.loadMessages(session.id);
    expect(left.map((m) => m.text), [
      'LFM2.5 (1.2B)',
      'What is my haemoglobin?',
      'It is 14.2 g/dL.',
      'openai/gpt-oss-120b',
    ]);
  });

  test('another conversation is untouched', () async {
    final session = await seed();
    final other = await repository.createSession('Ultrasound');
    await repository.addMessage(other.id, ChatRole.user, 'Explain the scan');

    await repository.deleteTrailingMessages(session.id, 4);

    expect(await repository.loadMessages(other.id), hasLength(1));
  });
}
