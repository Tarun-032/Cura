// Golden tests for ChatML formatting: the incremental helpers must produce a
// prompt byte-identical to a full rebuild, so KV reuse can never change what the
// model sees.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/ai/chat_format.dart';

void main() {
  group('chatmlFull matches the native ChatMLTemplate', () {
    test('system + single user turn', () {
      final out = chatmlFull([
        (role: 'system', text: 'You are Cura.'),
        (role: 'user', text: 'hello'),
      ]);
      expect(
        out,
        '<|im_start|>system\nYou are Cura.<|im_end|>\n'
        '<|im_start|>user\nhello<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });

    test('multi-turn with assistant history', () {
      final out = chatmlFull([
        (role: 'system', text: 'S'),
        (role: 'user', text: 'U1'),
        (role: 'assistant', text: 'A1'),
        (role: 'user', text: 'U2'),
      ]);
      expect(
        out,
        '<|im_start|>system\nS<|im_end|>\n'
        '<|im_start|>user\nU1<|im_end|>\n'
        '<|im_start|>assistant\nA1<|im_end|>\n'
        '<|im_start|>user\nU2<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });

    test('content is not trimmed (matches native, which does not trim)', () {
      final out = chatmlFull([
        (role: 'system', text: ' spaced '),
        (role: 'user', text: '  q  '),
      ]);
      expect(
        out,
        '<|im_start|>system\n spaced <|im_end|>\n'
        '<|im_start|>user\n  q  <|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });
  });

  group('incremental build == full rebuild (the reuse guarantee)', () {
    // What actually lands in the KV cache: one prefilled system block, then a
    // user suffix per turn, with each generated answer between them and no
    // trailing <|im_end|>. Reconstructing it must equal a from-scratch
    // chatmlFull of the whole conversation.
    String incremental(String system, List<({String user, String answer})> t) {
      final b = StringBuffer(chatmlSystemBlock(system));
      for (var i = 0; i < t.length; i++) {
        // closePrev is true for every turn after the first, because the previous
        // turn's answer is sitting open in the cache.
        b.write(chatmlUserTurn(t[i].user, closePrev: i > 0));
        b.write(t[i].answer); // model output decoded into the cache
      }
      return b.toString();
    }

    test('three turns stitch to the same bytes as chatmlFull', () {
      const system = 'You are Cura.';
      const turns = [
        (user: 'What is my hemoglobin?', answer: 'It is 13.2 g/dL.'),
        (user: 'Is that normal?', answer: 'Yes, within range.'),
        (user: 'Explain that', answer: 'Hemoglobin carries oxygen…'),
      ];

      // The cache after answering turn 3, then appending a 4th user turn's suffix,
      // must equal a full rebuild whose history is [u1,a1,u2,a2,u3,a3,u4].
      const nextUser = 'And my cholesterol?';
      final incrementalCtx =
          incremental(system, turns) + chatmlUserTurn(nextUser, closePrev: true);

      final rebuilt = chatmlFull([
        (role: 'system', text: system),
        for (final t in turns) ...[
          (role: 'user', text: t.user),
          (role: 'assistant', text: t.answer),
        ],
        (role: 'user', text: nextUser),
      ]);

      expect(incrementalCtx, rebuilt);
    });

    test('first turn on a fresh system base equals a one-turn rebuild', () {
      const system = 'S';
      const user = 'hi';
      final incrementalCtx =
          chatmlSystemBlock(system) + chatmlUserTurn(user, closePrev: false);
      final rebuilt = chatmlFull([
        (role: 'system', text: system),
        (role: 'user', text: user),
      ]);
      expect(incrementalCtx, rebuilt);
    });
  });
}
