import 'package:cura/features/ask/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Model notices are stored in the thread.
void main() {
  StoredMessage message(ChatRole role, String text) => StoredMessage(
    id: 'msg-${text.hashCode}',
    role: role,
    text: text,
    createdAt: DateTime(2026, 8, 7),
  );

  group('modelNoticeFor', () {
    test('a fresh session records the model it starts on', () {
      expect(
        modelNoticeFor(recorded: null, current: 'LFM2.5 (1.2B)'),
        'LFM2.5 (1.2B)',
      );
    });

    test('the model it already recorded says nothing', () {
      expect(
        modelNoticeFor(recorded: 'LFM2.5 (1.2B)', current: 'LFM2.5 (1.2B)'),
        isNull,
      );
    });

    test('a switch records the new model', () {
      expect(
        modelNoticeFor(
          recorded: 'LFM2.5 (1.2B)',
          current: 'openai/gpt-oss-120b',
        ),
        'openai/gpt-oss-120b',
      );
    });

    test('an engine with no name is not worth a line', () {
      expect(modelNoticeFor(recorded: null, current: '   '), isNull);
    });
  });

  group('lastRecordedModel', () {
    test('the newest notice wins, so switching back and forth settles', () {
      expect(
        lastRecordedModel([
          message(ChatRole.notice, 'LFM2.5 (1.2B)'),
          message(ChatRole.user, 'What is my haemoglobin?'),
          message(ChatRole.assistant, 'It is 14.2 g/dL.'),
          message(ChatRole.notice, 'openai/gpt-oss-120b'),
          message(ChatRole.user, 'Explain that'),
        ]),
        'openai/gpt-oss-120b',
      );
    });

    test('a thread saved before this existed records nothing', () {
      expect(
        lastRecordedModel([
          message(ChatRole.user, 'What is my haemoglobin?'),
          message(ChatRole.assistant, 'It is 14.2 g/dL.'),
        ]),
        isNull,
      );
    });
  });
}
