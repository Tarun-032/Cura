// Unit tests for groundingFor, the pure decision of which document to hand the
// model: never explain an unrelated doc when the asked-for type is missing, and
// still find a doc despite plural wording.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/ai/retrieval.dart';
import 'package:cura/features/ai/remote/cloud_privacy_gate.dart';
import 'package:cura/features/library/document.dart';

CuraDocument _doc(
  String id,
  DocumentType type,
  DateTime date, {
  String title = 'Doc',
  String text = '',
  List<DocumentResult> results = const [],
}) => CuraDocument(
  id: id,
  title: title,
  type: type,
  date: date,
  extractedText: text,
  results: results,
);

void main() {
  test('prescription Ask context names Summary and Medicines', () {
    final prescription = CuraDocument(
      id: 'rx-context',
      title: 'Old Follow up',
      type: DocumentType.prescription,
      date: DateTime(2026, 1, 20),
      extractedText: 'Rx',
      resultsNote: 'Follow-up for seborrheic dermatitis.',
      results: const [
        DocumentResult(
          'BALBACK PRO SERUM',
          '1 ml locally on scalp, twice daily',
        ),
      ],
    );

    final context = buildContext([prescription]);
    expect(context, contains('Summary: Follow-up for seborrheic dermatitis.'));
    expect(
      context,
      contains(
        'Medicines: BALBACK PRO SERUM: 1 ml locally on scalp, twice daily',
      ),
    );
    expect(context, isNot(contains('Results:')));
    expect(context, isNot(contains('Notes:')));
  });

  final ultrasound = _doc(
    'us',
    DocumentType.imaging,
    DateTime(2025, 5, 1),
    title: 'Ultrasound of neck',
    text:
        'Real time USG. Necrotic lymph node 8 x 7.8 mm at level II right side.',
  );
  final cbc = _doc(
    'cbc',
    DocumentType.lab,
    DateTime(2025, 4, 12),
    title: 'Complete blood count',
    results: const [DocumentResult('Hemoglobin', '14.2 g/dL')],
  );
  final prescription = _doc(
    'rx',
    DocumentType.prescription,
    DateTime(2025, 4, 2),
    title: 'Amoxicillin 500 mg',
  );

  group('detectDocumentType (plural-tolerant)', () {
    test('singular and plural imaging words', () {
      expect(detectDocumentType('explain my ultrasound'), DocumentType.imaging);
      expect(
        detectDocumentType('explain my ultrasounds latest'),
        DocumentType.imaging,
      );
      expect(detectDocumentType('show my x-rays'), DocumentType.imaging);
    });
    test('discharge / prescription / receipt / lab', () {
      expect(
        detectDocumentType('my discharge summary'),
        DocumentType.discharge,
      );
      expect(detectDocumentType('my prescriptions'), DocumentType.prescription);
      expect(detectDocumentType('the receipts'), DocumentType.receipt);
      expect(detectDocumentType('my lab report'), DocumentType.lab);
      expect(
        detectDocumentType('how many blood reports do I have'),
        DocumentType.lab,
      );
    });
    test('no type named', () {
      expect(detectDocumentType('what is my hemoglobin'), isNull);
      expect(detectDocumentType('summarize my records'), isNull);
    });
  });

  group('groundingFor', () {
    test('asked-for type present → attach & cite it (bug 2, plural)', () {
      final g = groundingFor('explain my ultrasounds latest', [
        cbc,
        ultrasound,
      ]);
      expect(g.contextDocs.single.id, 'us');
      expect(g.source?.id, 'us');
      expect(g.missingLabel, isNull);
    });

    test('asked-for type absent → missingType, no doc attached (bug 1)', () {
      // Only an ultrasound + labs on file; no discharge summary exists.
      final g = groundingFor('explain my discharge summary', [cbc, ultrasound]);
      expect(g.kind, GroundingKind.missingType);
      expect(g.missingLabel, 'Discharge summary');
      expect(g.contextDocs, isEmpty);
      expect(g.source, isNull);
    });

    test('MRI asked but only an ultrasound on file → missing, no attach', () {
      // Both are DocumentType.imaging, but an ultrasound is not an MRI.
      final g = groundingFor('can you explain my mri scan', [cbc, ultrasound]);
      expect(g.kind, GroundingKind.missingType);
      expect(g.missingLabel, 'MRI scan');
      expect(g.contextDocs, isEmpty);
      expect(g.source, isNull);
    });

    test('ultrasound asked and present → attach it', () {
      final g = groundingFor('can you explain my ultrasound', [
        cbc,
        ultrasound,
      ]);
      expect(g.source?.id, 'us');
      expect(g.missingLabel, isNull);
    });

    test('asked-for type present when it IS on file → attach', () {
      final discharge = _doc(
        'dc',
        DocumentType.discharge,
        DateTime(2025, 3, 15),
        title: 'Discharge summary',
        text: 'Discharged in stable condition.',
      );
      final g = groundingFor('explain my discharge summary', [
        ultrasound,
        discharge,
      ]);
      expect(g.source?.id, 'dc');
      expect(g.missingLabel, isNull);
    });

    test('generic records question → most recent doc, no card', () {
      final g = groundingFor('summarize my records', [
        prescription,
        cbc,
        ultrasound,
      ]);
      expect(g.kind, GroundingKind.recent);
      expect(g.contextDocs.single.id, 'us'); // newest by date
      expect(g.source, isNull);
      expect(g.missingLabel, isNull);
    });

    test('definition question → no document', () {
      final g = groundingFor('what is diabetes?', [cbc, ultrasound]);
      expect(g.kind, GroundingKind.none);
      expect(g.contextDocs, isEmpty);
    });

    test('specific test name → grounded + cited', () {
      final g = groundingFor('explain my hemoglobin result', [cbc, ultrasound]);
      expect(g.kind, GroundingKind.grounded);
      expect(g.source?.id, 'cbc');
    });

    test('no documents → none', () {
      final g = groundingFor('explain my ultrasound', const []);
      expect(g.kind, GroundingKind.none);
    });
  });

  group('multiple documents of the same kind', () {
    final usApr = _doc(
      'us-apr',
      DocumentType.imaging,
      DateTime(2025, 4, 2),
      title: 'Ultrasound of neck',
      text: 'Ultrasound. Necrotic lymph node.',
    );
    final usJan = _doc(
      'us-jan',
      DocumentType.imaging,
      DateTime(2025, 1, 23),
      title: 'Ultrasound of jaw',
      text: 'Ultrasound. Hypoechoic collection.',
    );
    final twoUltrasounds = [usApr, usJan];

    test('date picks the right report (April 2nd)', () {
      final g = groundingFor(
        'what does the april 2nd ultrasound say',
        twoUltrasounds,
      );
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-apr');
    });

    test(
      '"the other ultrasound" excludes the one already shown (via shown)',
      () {
        final g = groundingFor(
          'explain my other ultrasound',
          twoUltrasounds,
          shownSourceIds: {'us-apr'},
        );
        expect(g.kind, GroundingKind.typeMatch);
        expect(g.source?.id, 'us-jan');
        expect(g.otherReports.map((d) => d.id), [
          'us-apr',
        ]); // the other still named
      },
    );

    test('"the other ultrasound" resolves via focus alone (no placeholder)', () {
      // The "other" exclusion uses focusDocIds as well as shownSourceIds, so
      // "the other ultrasound" resolves instead of asking which one.
      final g = groundingFor(
        'explain the other ultrasound in more detail',
        twoUltrasounds,
        focusDocIds: {'us-apr'},
      );
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-jan');
    });

    test(
      'fresh ambiguous → newest by default, the other named (no placeholder)',
      () {
        final g = groundingFor('can you explain my ultrasound', twoUltrasounds);
        expect(g.kind, GroundingKind.typeMatch);
        expect(g.source?.id, 'us-apr'); // newest by default
        expect(g.otherReports.map((d) => d.id), ['us-jan']);
      },
    );

    test('date with no report on that date → missing, date-scoped label', () {
      final g = groundingFor(
        'explain my august 2024 ultrasound',
        twoUltrasounds,
      );
      expect(g.kind, GroundingKind.missingType);
      expect(g.missingLabel, contains('August 2024'));
      expect(g.contextDocs, isEmpty);
    });

    test('single of a kind still attaches directly', () {
      final g = groundingFor('explain my ultrasound', [usApr, cbc]);
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-apr');
    });

    test('superlative "latest" picks the newest, no clarify', () {
      final g = groundingFor('explain my latest ultrasound', twoUltrasounds);
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-apr'); // Apr 2 is newer than Jan 23
    });

    test('superlative "oldest" picks the oldest, no clarify', () {
      final g = groundingFor('explain my oldest ultrasound', twoUltrasounds);
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-jan');
    });
  });

  group('follow-up resolution against the focus pool', () {
    final usApr = _doc(
      'us-apr',
      DocumentType.imaging,
      DateTime(2025, 4, 2),
      title: 'Ultrasound of neck',
      text: 'Ultrasound. Necrotic lymph node.',
    );
    final usJan = _doc(
      'us-jan',
      DocumentType.imaging,
      DateTime(2025, 1, 23),
      title: 'Ultrasound of jaw',
      text: 'Ultrasound. Hypoechoic collection.',
    );
    final all = [usApr, usJan, cbc];
    final bothIds = {'us-apr', 'us-jan'};

    test('"latest one" after a clarify picks the newest candidate', () {
      final g = groundingFor('latest one', all, focusDocIds: bothIds);
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-apr');
    });

    test('"the older one" after a clarify picks the oldest candidate', () {
      final g = groundingFor('the older one', all, focusDocIds: bothIds);
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-jan');
    });

    test('"explain this" with a single focused report re-attaches it', () {
      final g = groundingFor('explain this', all, focusDocIds: {'us-apr'});
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-apr');
    });

    test('"the other one" after one ultrasound shown finds its sibling', () {
      // Only the Apr report was in focus + shown; "the other one" must reach the
      // Jan sibling (which was never itself focused), not an unrelated document.
      final g = groundingFor(
        'can you explain the other one too',
        all,
        focusDocIds: {'us-apr'},
        shownSourceIds: {'us-apr'},
      );
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-jan');
    });

    test('an unpinnable follow-up hands the sibling reports to the model', () {
      // No date / superlative / "other" to pin it deterministically → attach both
      // real reports and let the model resolve the reference (never fabricate).
      final g = groundingFor(
        'tell me about the previous scan',
        all,
        focusDocIds: {'us-apr'},
      );
      expect(g.kind, GroundingKind.focusResolve);
      expect(g.contextDocs.map((d) => d.id), containsAll(['us-apr', 'us-jan']));
      expect(g.source, isNull);
    });

    test('a broad "all my reports" ask is not forced onto the focus', () {
      final g = groundingFor(
        'summarize all my reports',
        all,
        focusDocIds: {'us-apr'},
      );
      expect(g.kind, isNot(GroundingKind.focusResolve));
    });

    test('"the latest one" resolves to the newest focused report, never a lab', () {
      // Mid-ultrasound chat, an unrelated (older) lab is also on file. "the latest
      // one" must be the newest *ultrasound* (Apr 2), not the lab or a global pick.
      final lft = _doc(
        'lft',
        DocumentType.lab,
        DateTime(2025, 1, 9),
        title: 'Liver function test',
        results: const [DocumentResult('S.G.P.T', '55.6 IU/L', range: '0–45')],
      );
      final g = groundingFor(
        'explain the latest one',
        [usApr, usJan, lft],
        focusDocIds: {'us-jan'},
      );
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'us-apr');
    });

    test('a title keyword in the reply picks that candidate', () {
      final g = groundingFor('the jaw one', all, focusDocIds: bothIds);
      expect(g.source?.id, 'us-jan');
    });

    test('a new subject mid-focus is NOT hijacked — grounds on its own doc', () {
      // Mid-clarify about ultrasounds, but asking about hemoglobin must cite the
      // CBC (keyword grounding wins before focus resolution).
      final g = groundingFor(
        'explain my hemoglobin result',
        all,
        focusDocIds: bothIds,
      );
      expect(g.kind, GroundingKind.grounded);
      expect(g.source?.id, 'cbc');
    });

    test('no focus set → a bare pick word stays none (no false attach)', () {
      final g = groundingFor('latest one', all);
      expect(g.kind, GroundingKind.none);
    });
    test('ordinal follow-up uses the previous answer list order', () {
      final afb = _doc(
        'afb',
        DocumentType.lab,
        DateTime(2024, 9, 3),
        title: 'AFB CULTURE[OTHERS]',
      );
      final xpert = _doc(
        'xpert',
        DocumentType.lab,
        DateTime(2024, 9, 4),
        title: 'Xpert MTB/RIF ULTRA',
      );
      final pyro = _doc(
        'pyro',
        DocumentType.lab,
        DateTime(2024, 9, 5),
        title: 'TB Pyrosequencing XDR',
      );
      final unrelatedNewest = _doc(
        'new-lab',
        DocumentType.lab,
        DateTime(2026, 7, 18),
        title: 'Complete blood count',
      );
      final docs = [unrelatedNewest, afb, xpert, pyro];
      final previousAnswer =
          '1. TB Pyrosequencing XDR - Sep 5\n'
          '2. Xpert MTB/RIF ULTRA - Sep 4\n'
          '3. AFB CULTURE[OTHERS] - Sep 3';
      final ordered = mentionedDocumentsInOrder(previousAnswer, docs);

      expect(ordered.map((d) => d.id), ['pyro', 'xpert', 'afb']);

      final g = groundingFor(
        'explain the first one!',
        docs,
        focusDocIds: ordered.map((d) => d.id).toSet(),
        orderedFocusDocIds: ordered.map((d) => d.id).toList(),
      );
      expect(g.kind, GroundingKind.typeMatch);
      expect(g.source?.id, 'pyro');
      expect(g.contextDocs.single.id, 'pyro');
    });

    test('maps every exact TB report title in answer order', () {
      final docs = [
        _doc(
          'infectious',
          DocumentType.lab,
          DateTime(2024, 9, 27),
          title: 'INFECTIOUS DISEASE',
        ),
        _doc(
          'pyro',
          DocumentType.lab,
          DateTime(2024, 9, 4),
          title: 'TB Pyrosequencing XDR',
        ),
        _doc(
          'xpert',
          DocumentType.lab,
          DateTime(2024, 9, 4),
          title: 'Xpert MTB/RIF ULTRA',
        ),
        _doc(
          'afb',
          DocumentType.lab,
          DateTime(2024, 9, 3),
          title: 'AFB CULTURE[OTHERS]',
        ),
        _doc(
          'pet',
          DocumentType.imaging,
          DateTime(2024, 8, 29),
          title: 'Contrast Enhanced 18F-FDG Whole Body PET-CT Scan',
        ),
        _doc(
          'unrelated',
          DocumentType.receipt,
          DateTime(2026, 1, 1),
          title: 'Meadowlark bill',
        ),
      ];
      const answer = '''
You have 5 TB-related records:
- **INFECTIOUS DISEASE** — Sep 27, 2024
- **TB Pyrosequencing XDR** — Sep 4, 2024
- **Xpert MTB/RIF ULTRA** — Sep 4, 2024
- **AFB CULTURE[OTHERS]** — Sep 3, 2024
- **Contrast Enhanced 18F-FDG Whole Body PET-CT Scan** — Aug 29, 2024
''';

      final sources = explicitlyNamedDocumentsInOrder(answer, docs);
      expect(sources.map((d) => d.id), [
        'infectious',
        'pyro',
        'xpert',
        'afb',
        'pet',
      ]);
    });

    test('uses dates to distinguish duplicate titles', () {
      final july = _doc(
        'july',
        DocumentType.receipt,
        DateTime(2026, 7, 17),
        title: 'Medical Stores invoice',
      );
      final january = _doc(
        'january',
        DocumentType.receipt,
        DateTime(2026, 1, 21),
        title: 'Medical Stores invoice',
      );
      const answer = '''
- Medical Stores invoice — Jan 21, 2026
- Medical Stores invoice — Jul 17, 2026
''';

      final sources = explicitlyNamedDocumentsInOrder(answer, [july, january]);
      expect(sources.map((d) => d.id), ['january', 'july']);
      expect(
        explicitlyNamedDocumentsInOrder('- Medical Stores invoice', [
          july,
          january,
        ]),
        isEmpty,
      );
    });

    test('does not guess from partial or ambiguous identities', () {
      final first = _doc(
        'first',
        DocumentType.lab,
        DateTime(2024, 9, 4),
        title: 'TB Pyrosequencing XDR',
      );
      final duplicate = _doc(
        'duplicate',
        DocumentType.lab,
        DateTime(2024, 9, 4),
        title: 'TB Pyrosequencing XDR',
      );

      expect(
        explicitlyNamedDocumentsInOrder('- Pyrosequencing — Sep 4, 2024', [
          first,
        ]),
        isEmpty,
      );
      expect(
        explicitlyNamedDocumentsInOrder(
          '- TB Pyrosequencing XDR — Sep 4, 2024',
          [first, duplicate],
        ),
        isEmpty,
      );
    });
  });

  group('collection requests and greetings', () {
    final julyBill = _doc(
      'bill-jul',
      DocumentType.receipt,
      DateTime(2026, 7, 18),
      title: 'July pharmacy receipt',
      results: const [
        DocumentResult('FLUCOS DT-50MG', '₹440.70'),
        DocumentResult('Final amount', '₹1,250.00'),
      ],
    );
    final januaryBill = _doc(
      'bill-jan',
      DocumentType.receipt,
      DateTime(2026, 1, 21),
      title: 'January pharmacy receipt',
      results: const [
        DocumentResult('BALBACK PRO 60ML', '₹1,440.00'),
        DocumentResult('Final amount', '₹1,956.00'),
      ],
    );
    final shownBill = _doc(
      'bill-old',
      DocumentType.receipt,
      DateTime(2025, 4, 2),
      title: 'Earlier pharmacy receipt',
      results: const [DocumentResult('Final amount', '₹500.00')],
    );
    final bills = [julyBill, januaryBill, shownBill];

    test('"explain the rest" attaches every unshown receipt with details', () {
      final g = groundingFor(
        'explain the rest too',
        bills,
        focusDocIds: {'bill-old'},
        shownSourceIds: {'bill-old'},
      );

      expect(g.kind, GroundingKind.collection);
      expect(g.source, isNull);
      expect(g.contextDocs.map((d) => d.id), ['bill-jul', 'bill-jan']);
      final context = buildContext(g.contextDocs);
      expect(context, contains('FLUCOS DT-50MG'));
      expect(context, contains('BALBACK PRO 60ML'));
      final cloudContext = const CloudPrivacyGate()
          .buildContext(g.contextDocs)
          .text;
      expect(cloudContext, contains('FLUCOS DT-50MG'));
      expect(cloudContext, contains('BALBACK PRO 60ML'));
    });

    test('plural receipt summary attaches the complete receipt collection', () {
      final g = groundingFor('summarize my receipts', bills);

      expect(g.kind, GroundingKind.collection);
      expect(g.contextDocs.map((d) => d.id), [
        'bill-jul',
        'bill-jan',
        'bill-old',
      ]);
    });

    test('pure hello never reattaches the previously focused PET scan', () {
      expect(isPureGreeting('hello'), isTrue);
      expect(isPureGreeting('hello, explain my PET scan'), isFalse);

      final g = groundingFor(
        'hello',
        [ultrasound],
        focusDocIds: {'us'},
        shownSourceIds: {'us'},
      );
      expect(g.kind, GroundingKind.none);
      expect(g.contextDocs, isEmpty);
      expect(g.source, isNull);
    });
  });
}
