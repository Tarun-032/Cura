// Tests cloud answer card selection.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/ai/ai_service.dart';
import 'package:cura/features/ai/query_router.dart';
import 'package:cura/features/ai/remote/cloud_privacy_gate.dart';
import 'package:cura/features/library/document.dart';

CuraDocument _doc(
  String id,
  String title,
  DateTime date, {
  DocumentType type = DocumentType.lab,
}) => CuraDocument(id: id, title: title, type: type, date: date);

void main() {
  final thyroid = _doc(
    'thyroid',
    'Thyroid Function Panel',
    DateTime(2023, 5, 18),
  );
  final lipid = _doc('lipid', 'Lipid Profile', DateTime(2023, 3, 6));
  final ferritin = _doc(
    'ferritin',
    'Serum Ferritin Assay',
    DateTime(2022, 11, 4),
  );
  final vitd = _doc('vitd', 'Vitamin D Total', DateTime(2022, 8, 12));
  final docs = [thyroid, lipid, ferritin, vitd];

  group('cloudAnswerCards', () {
    test('an exact route set wins over inference', () {
      // Route.
      final picked = AiService.cloudAnswerCards(
        'You have 4 records: **Thyroid Function Panel** — May 18, 2023 …',
        cardSources: docs,
        cardTotal: 4,
        candidates: docs,
      );

      expect(picked.cards, docs);
      expect(picked.total, 4);
      expect(picked.cited?.id, 'thyroid');
    });

    test('cards every report the answer names, in the order it named them', () {
      const answer = '''
Both of your recent panels:
- **Lipid Profile** — Mar 6, 2023 — LDL 96 mg/dL.
- **Thyroid Function Panel** — May 18, 2023 — TSH 2.1 mIU/L.
''';

      final picked = AiService.cloudAnswerCards(answer, candidates: docs);

      expect(picked.cards.map((d) => d.id), ['lipid', 'thyroid']);
      expect(picked.total, 2);
      expect(picked.cited?.id, 'lipid');
    });

    test('a latest answer that names one report cites it', () {
      final picked = AiService.cloudAnswerCards(
        'Your latest report is **Thyroid Function Panel** — Lab report — May 18, 2023.',
        candidates: docs,
      );

      expect(picked.cards.map((d) => d.id), ['thyroid']);
      expect(picked.cited?.id, 'thyroid');
    });

    test('a shortened title still cards up via its date', () {
      // Match by date.
      final picked = AiService.cloudAnswerCards(
        '**Ferritin Assay** — Nov 4, 2022 — Ferritin 18 ng/mL.',
        candidates: docs,
      );

      expect(picked.cards.map((d) => d.id), ['ferritin']);
      expect(picked.cited?.id, 'ferritin');
    });

    test('falls back to the router pick when nothing is identifiable', () {
      // Fallback to router.
      final picked = AiService.cloudAnswerCards(
        'Your latest report is the ferritin assay.',
        candidates: docs,
        source: ferritin,
      );

      expect(picked.cards, isEmpty);
      expect(picked.cited?.id, 'ferritin');
    });

    test('a greeting names nothing, so it shows nothing', () {
      final picked = AiService.cloudAnswerCards(
        "I'm Cura, your medical assistant. Ask me anything about your reports.",
        candidates: docs,
      );

      expect(picked.cards, isEmpty);
      expect(picked.total, 0);
      expect(picked.cited, isNull);
    });

    test('recognises the privacy-safe title the model was given', () {
      const gate = CloudPrivacyGate();
      final unsafe = _doc(
        'unsafe',
        'Meadowlark Clinic liver panel',
        DateTime(2023, 1, 9),
      );

      final picked = AiService.cloudAnswerCards(
        'Your latest report is **Laboratory report** — Jan 9, 2023.',
        candidates: [unsafe],
        aliasTitle: gate.safeTitle,
      );

      expect(picked.cards.map((d) => d.id), ['unsafe']);
    });

    test('no candidates means no inference', () {
      final picked = AiService.cloudAnswerCards(
        'Your **Lipid Profile** from Mar 6, 2023 looks fine.',
      );

      expect(picked.cards, isEmpty);
      expect(picked.cited, isNull);
    });
  });

  group('collectionPrompt', () {
    // Keyword scope matches only Xpert.
    final tb = [
      _doc('xpert', 'Xpert MTB/RIF', DateTime(2024, 9, 4)),
      _doc('afb', 'AFB Culture', DateTime(2024, 9, 3)),
      _doc('histo', 'Histopathology', DateTime(2025, 2, 15)),
    ];

    test('a type count is proved on the device and sent as verified', () {
      final route = routeQuestion('how many lab reports do i have', tb)!;

      expect(route.kind, RoutedAnswerKind.count);
      expect(route.sourcesAreAuthoritative, isTrue);
      final prompt = AiService.collectionPrompt(route);
      expect(prompt.verifiedCount, route.text);
      expect(prompt.listNote, contains('the user asked for a list'));
      // Proved set: supplies details and cards.
      expect(prompt.topical, isFalse);
    });

    test('a topical count claims no number and asks for the judgement', () {
      final route = routeQuestion('how many TB related reports do i have', tb)!;

      // Keyword scope -> not authoritative.
      expect(route.kind, RoutedAnswerKind.count);
      expect(route.sourcesAreAuthoritative, isFalse);
      expect(route.text, contains('1'));

      final prompt = AiService.collectionPrompt(route);
      expect(prompt.verifiedCount, isNull);
      expect(prompt.listNote, contains('relate to a medical topic'));
      expect(prompt.listNote, contains('one entry at a time'));
      expect(prompt.listNote, contains('why it relates'));
      // Keyword pick withheld: no fixed cards.
      expect(prompt.topical, isTrue);
    });

    test('a list route never carries a count', () {
      final route = routeQuestion('list my lab reports', tb)!;

      expect(route.kind, RoutedAnswerKind.list);
      final prompt = AiService.collectionPrompt(route);
      expect(prompt.verifiedCount, isNull);
      expect(prompt.listNote, isNotNull);
    });

    test('a non-collection route gets neither', () {
      final route = routeQuestion('what is my latest lab report', tb)!;

      expect(route.kind, isNot(RoutedAnswerKind.count));
      expect(route.kind, isNot(RoutedAnswerKind.list));
      final prompt = AiService.collectionPrompt(route);
      expect(prompt.verifiedCount, isNull);
      expect(prompt.listNote, isNull);
    });

    test('an unrouted question gets neither', () {
      final prompt = AiService.collectionPrompt(null);

      expect(prompt.verifiedCount, isNull);
      expect(prompt.listNote, isNull);
    });
  });
}
