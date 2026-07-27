import 'package:cura/core/data/app_database.dart';
import 'package:cura/core/data/document_repository.dart';
import 'package:cura/features/ai/ai_service.dart';
import 'package:cura/features/library/document.dart';
import 'package:cura/features/scan/summary_rewriter.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _scraped =
    'Indication: Persistent cough for six weeks.\n'
    'Findings: Right lower lobe consolidation measuring 3.2 cm. No pleural '
    'effusion. Mediastinum unremarkable.\n'
    'Impression: Findings consistent with pneumonia.';

CuraDocument _doc({
  DocumentType type = DocumentType.imaging,
  String? note = _scraped,
  String? state,
  String id = 'scan-1',
}) => CuraDocument(
  id: id,
  title: 'Chest CT',
  type: type,
  date: DateTime(2026, 7, 20),
  resultsNote: note,
  summaryState: state,
);

void main() {
  group('needsSummaryRewrite', () {
    test('queues the narrative types', () {
      for (final type in [
        DocumentType.imaging,
        DocumentType.discharge,
        DocumentType.visit,
        DocumentType.prescription,
      ]) {
        expect(
          needsSummaryRewrite(type: type, note: _scraped),
          isTrue,
          reason: type.name,
        );
      }
    });

    test('leaves computed and bill summaries alone', () {
      for (final type in [DocumentType.lab, DocumentType.receipt]) {
        expect(
          needsSummaryRewrite(type: type, note: _scraped),
          isFalse,
          reason: type.name,
        );
      }
    });

    test('skips an empty or one-line summary', () {
      expect(needsSummaryRewrite(type: DocumentType.imaging, note: null), isFalse);
      expect(needsSummaryRewrite(type: DocumentType.imaging, note: '  '), isFalse);
      expect(
        needsSummaryRewrite(
          type: DocumentType.imaging,
          note: 'Impression: normal study.',
        ),
        isFalse,
      );
    });

    test('a summary the user rewrote is theirs', () {
      expect(
        needsSummaryRewrite(
          type: DocumentType.imaging,
          note: '$_scraped Checked with Dr Quinn.',
          deterministicNote: _scraped,
        ),
        isFalse,
      );
      expect(
        needsSummaryRewrite(
          type: DocumentType.imaging,
          note: '  $_scraped  ',
          deterministicNote: _scraped,
        ),
        isTrue,
      );
    });
  });

  group('acceptSummaryRewrite', () {
    test('keeps prose that stays on the numbers', () {
      const out =
          'You had a cough for six weeks. The scan shows a 3.2 cm area of '
          'consolidation in the right lower lobe, with no fluid around the '
          'lung and a normal mediastinum. This is consistent with pneumonia.';
      expect(acceptSummaryRewrite(_scraped, out), out);
    });

    test('trims before it judges', () {
      expect(acceptSummaryRewrite(_scraped, '  Short but fine.  '), 'Short but fine.');
    });

    test('rejects a number that was never on the page', () {
      expect(
        acceptSummaryRewrite(
          _scraped,
          'The consolidation measures 5.8 cm in the right lower lobe.',
        ),
        isNull,
      );
    });

    test('rejects empty output', () {
      expect(acceptSummaryRewrite(_scraped, null), isNull);
      expect(acceptSummaryRewrite(_scraped, '   '), isNull);
    });

    test('rejects a refusal', () {
      expect(
        acceptSummaryRewrite(_scraped, 'I cannot rewrite medical records.'),
        isNull,
      );
    });

    test('rejects output that grew far past its source', () {
      final padded = List.filled(60, 'The scan was reviewed carefully.').join(' ');
      expect(acceptSummaryRewrite(_scraped, padded), isNull);
    });
  });

  group('the queue', () {
    late AppDatabase database;
    late DocumentRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = DocumentRepository(database);
    });

    tearDown(() => database.close());

    SummaryRewriteRequest replying(SummaryRewrite reply, {List<String>? seen}) {
      return (summary, {required type, title}) async {
        seen?.add(summary);
        return reply;
      };
    }

    test('an accepted rewrite is stored and the row settles', () async {
      await repository.add(_doc(state: kSummaryPending));
      const prose = 'A 3.2 cm consolidation sits in the right lower lobe.';

      await SummaryRewriter(repository, replying(const SummaryRewrite(prose)))
          .sweep();

      final stored = (await repository.watchDocuments().first).single;
      expect(stored.summaryRewrite, prose);
      expect(stored.summaryState, isNull);
      // The verbatim text Ask quotes is untouched.
      expect(stored.resultsNote, _scraped);
    });

    test('a first rejection buys one retry, a second gives up', () async {
      await repository.add(_doc(state: kSummaryPending));
      final rewriter = SummaryRewriter(
        repository,
        replying(const SummaryRewrite('I cannot help with that.')),
      );

      await rewriter.sweep();
      expect(
        (await repository.watchDocuments().first).single.summaryState,
        kSummaryRetry,
      );

      await rewriter.sweep();
      final stored = (await repository.watchDocuments().first).single;
      expect(stored.summaryState, isNull);
      expect(stored.summaryRewrite, isNull);
      expect(stored.resultsNote, _scraped);
    });

    test('a preempted rewrite stays pending for the next sweep', () async {
      await repository.add(_doc(state: kSummaryPending));

      await SummaryRewriter(
        repository,
        replying(const SummaryRewrite(null, preempted: true)),
      ).sweep();

      expect(
        (await repository.watchDocuments().first).single.summaryState,
        kSummaryPending,
      );
    });

    test('works through every pending document', () async {
      await repository.add(_doc(id: 'scan-1', state: kSummaryPending));
      await repository.add(_doc(id: 'scan-2', state: kSummaryRetry));
      await repository.add(_doc(id: 'scan-3'));
      final seen = <String>[];

      await SummaryRewriter(
        repository,
        replying(const SummaryRewrite('Clear prose.'), seen: seen),
      ).sweep();

      expect(seen, hasLength(2));
      final stored = await repository.watchDocuments().first;
      expect(
        {for (final d in stored) d.id: d.summaryRewrite},
        {'scan-1': 'Clear prose.', 'scan-2': 'Clear prose.', 'scan-3': null},
      );
    });

    test('a preempted document does not block the ones behind it', () async {
      await repository.add(_doc(id: 'scan-1', state: kSummaryPending));
      await repository.add(_doc(id: 'scan-2', state: kSummaryPending));

      // Ask took the model back on the first document.
      await SummaryRewriter(
        repository,
        replying(const SummaryRewrite(null, preempted: true)),
      ).sweep();
      await SummaryRewriter(
        repository,
        replying(const SummaryRewrite('Clear prose.')),
      ).sweep();

      final stored = await repository.watchDocuments().first;
      expect(stored.every((d) => d.summaryRewrite == 'Clear prose.'), isTrue);
    });

    test('nothing pending is a no-op', () async {
      await repository.add(_doc());
      var called = false;

      await SummaryRewriter(repository, (summary, {required type, title}) async {
        called = true;
        return const SummaryRewrite(null);
      }).sweep();

      expect(called, isFalse);
    });
  });

  group('the pending queue', () {
    late AppDatabase database;
    late DocumentRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = DocumentRepository(database);
    });

    tearDown(() => database.close());

    test('returns pending and retry rows, oldest first', () async {
      await repository.add(_doc(id: 'scan-2', state: kSummaryRetry));
      await repository.add(_doc(id: 'scan-1', state: kSummaryPending));
      await repository.add(_doc(id: 'scan-3'));

      expect((await repository.nextPendingSummary())?.id, 'scan-1');
      expect(
        (await repository.nextPendingSummary(excluding: {'scan-1'}))?.id,
        'scan-2',
      );
      expect(
        await repository.nextPendingSummary(excluding: {'scan-1', 'scan-2'}),
        isNull,
      );
    });

    test('setSummaryRewrite touches only its two columns', () async {
      await repository.add(_doc(state: kSummaryPending));

      await repository.setSummaryRewrite('scan-1', text: 'Clear prose.');

      final stored = (await repository.watchDocuments().first).single;
      expect(stored.summaryRewrite, 'Clear prose.');
      expect(stored.summaryState, isNull);
      expect(stored.title, 'Chest CT');
      expect(stored.resultsNote, _scraped);
    });
  });
}
