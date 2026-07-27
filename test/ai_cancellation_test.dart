import 'dart:async';

import 'package:cura/features/ai/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the stop button rides on.
void main() {
  test('cancel fires the attached stop once', () {
    var stops = 0;
    final cancellation = GenerationCancellation()..attach(() => stops++);

    cancellation.cancel();
    cancellation.cancel();

    expect(cancellation.cancelled, isTrue);
    expect(stops, 1);
  });

  test('attaching after a cancel stops immediately', () {
    // Stop pressed while the model is still loading.
    var stopped = false;
    final cancellation = GenerationCancellation()..cancel();

    cancellation.attach(() => stopped = true);

    expect(stopped, isTrue);
  });

  test('a detached bridge no longer stops anything', () {
    var stopped = false;
    final cancellation = GenerationCancellation()
      ..attach(() => stopped = true)
      ..detach();

    cancellation.cancel();

    expect(stopped, isFalse);
    expect(cancellation.cancelled, isTrue);
  });

  test('an untouched bridge reports nothing cancelled', () {
    expect(GenerationCancellation().cancelled, isFalse);
  });

  test('done completes on cancel', () async {
    final cancellation = GenerationCancellation();
    var done = false;
    unawaited(cancellation.done.then((_) => done = true));

    cancellation.cancel();
    await pumpEventQueue();

    expect(done, isTrue);
  });

  group('untilCancelled', () {
    test('ends a stream the backend never closes', () async {
      // The on-device stop leaves its token stream open forever.
      final source = StreamController<String>();
      addTearDown(source.close);
      final cancellation = GenerationCancellation();
      final seen = <String>[];

      final drained = untilCancelled(
        source.stream,
        cancellation,
      ).forEach(seen.add).timeout(const Duration(seconds: 2));

      source.add('Diabetes is');
      await pumpEventQueue();
      cancellation.cancel();

      await drained;
      expect(seen, ['Diabetes is']);
    });

    test('passes values and normal completion through', () async {
      final cancellation = GenerationCancellation();

      final seen = await untilCancelled(
        Stream.fromIterable(['a', 'b', 'c']),
        cancellation,
      ).toList();

      expect(seen, ['a', 'b', 'c']);
      expect(cancellation.cancelled, isFalse);
    });

    test('passes errors through', () async {
      expect(
        untilCancelled(
          Stream<String>.error(StateError('boom')),
          GenerationCancellation(),
        ).toList(),
        throwsStateError,
      );
    });

    test('returns the source untouched without a bridge', () {
      final source = Stream.value('a');
      expect(identical(untilCancelled(source, null), source), isTrue);
    });

    test('a stream cancelled before it starts ends straight away', () async {
      final source = StreamController<String>();
      addTearDown(source.close);
      final cancellation = GenerationCancellation()..cancel();

      await untilCancelled(
        source.stream,
        cancellation,
      ).drain<void>().timeout(const Duration(seconds: 2));
    });
  });
}
