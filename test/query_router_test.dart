// Unit tests for the local query router — proves the fast path is exact and,
// just as importantly, that anything needing reasoning falls through to the LLM.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/ai/query_router.dart';
import 'package:cura/features/library/document.dart';

/// Fixtures with reference ranges (the real `sampleDocuments` carry none), and
/// two hemoglobin/LDL readings on different dates to exercise enumeration and
/// date filtering.
final _cbc = CuraDocument(
  id: 'cbc',
  title: 'Complete blood count',
  type: DocumentType.lab,
  date: DateTime(2024, 9, 3),
  results: const [
    DocumentResult('Hemoglobin', '14.2 g/dL', range: '13–17 g/dL'),
    DocumentResult('LDL', '160 mg/dL', range: '<100'),
    DocumentResult('Glucose', '80 mg/dL', range: '70–110'),
  ],
);
final _lipid = CuraDocument(
  id: 'lipid',
  title: 'Lipid panel',
  type: DocumentType.lab,
  date: DateTime(2024, 8, 11),
  results: const [
    DocumentResult('Hemoglobin', '11.0 g/dL', range: '13–17 g/dL'),
    DocumentResult('LDL', '90 mg/dL', range: '<100'),
  ],
);
final _rx = CuraDocument(
  id: 'rx',
  title: 'Amoxicillin 500 mg',
  type: DocumentType.prescription,
  date: DateTime(2024, 7, 1),
  results: const [DocumentResult('Dose', '500 mg')],
);
final _receipt = CuraDocument(
  id: 'receipt',
  title: 'Pharmacy receipt',
  type: DocumentType.receipt,
  date: DateTime(2024, 6, 15),
  results: const [DocumentResult('Total', r'$24.50')],
);

final _docs = [_cbc, _lipid, _rx, _receipt];

/// Three imaging documents of two modalities (two ultrasounds + one X-ray), to
/// prove count / latest / list answer by the named *modality*, not the imaging
/// type as a whole.
final _usApr = CuraDocument(
  id: 'us-apr',
  title: 'Ultrasound of neck',
  type: DocumentType.imaging,
  date: DateTime(2025, 4, 2),
  extractedText: 'Ultrasound examination. Necrotic lymph node at level II.',
);
final _usJan = CuraDocument(
  id: 'us-jan',
  title: 'Ultrasound of jaw',
  type: DocumentType.imaging,
  date: DateTime(2025, 1, 23),
  extractedText: 'Ultrasound examination. Hypoechoic collection.',
);
final _xray = CuraDocument(
  id: 'xray',
  title: 'Chest X-ray',
  type: DocumentType.imaging,
  date: DateTime(2025, 2, 10),
  extractedText: 'X-ray of the chest. Clear lung fields.',
);
final _imaging = [_usApr, _usJan, _xray];

void main() {
  group('receipt amounts', () {
    final meadowlark = CuraDocument(
      id: 'meadowlark',
      title: 'Meadowlark Hospitals bill',
      type: DocumentType.receipt,
      date: DateTime(2025, 4, 2),
      results: const [
        DocumentResult('USG Small Part', '₹3,360.00'),
        DocumentResult('Total', '₹3,360.00'),
      ],
    );
    final pharmacy = CuraDocument(
      id: 'pharmacy',
      title: 'Fenwick Medical Stores invoice',
      type: DocumentType.receipt,
      date: DateTime(2026, 1, 21),
      results: const [
        DocumentResult('CERATINA CAP', '₹516.10'),
        DocumentResult('Total', '₹1956.00'),
      ],
    );
    final bills = [_cbc, meadowlark, pharmacy];

    test('"how much did I pay at meadowlark" answers with the total', () {
      final a = routeQuestion('how much did I pay at meadowlark?', bills)!;
      expect(a.kind, RoutedAnswerKind.value);
      expect(a.text, contains('₹3,360.00'));
      expect(a.source?.id, 'meadowlark');
    });

    test('latest wording picks the newest bill', () {
      final a = routeQuestion('how much was my last bill?', bills)!;
      expect(a.text, contains('₹1956.00'));
      expect(a.source?.id, 'pharmacy');
    });

    test('aggregate question lists every bill and sums', () {
      final a = routeQuestion('how much did I spend in total?', bills)!;
      expect(a.kind, RoutedAnswerKind.list);
      expect(a.text, contains('₹3,360.00'));
      expect(a.text, contains('₹1956.00'));
      expect(a.text, contains('₹5,316.00'));
    });

    test('clinical value questions never become money answers', () {
      final a = routeQuestion('what is my hemoglobin?', [_cbc, meadowlark])!;
      expect(a.text.toLowerCase(), contains('hemoglobin'));
      expect(a.text, isNot(contains('₹')));
    });

    test('"how many receipts" still counts instead of pricing', () {
      final a = routeQuestion('how many receipts do I have?', bills)!;
      expect(a.kind, RoutedAnswerKind.count);
    });

    test('receipts without parsed amounts fall through to the LLM', () {
      final bare = CuraDocument(
        id: 'bare',
        title: 'Clinic bill',
        type: DocumentType.receipt,
        date: DateTime(2025, 5, 1),
      );
      expect(routeQuestion('how much did I pay?', [_cbc, bare]), isNull);
    });
  });

  group('engine policy', () {
    test('cloud always reaches the LLM instead of canned router answers', () {
      expect(shouldUseQueryRouter(cloudActive: true), isFalse);
      expect(shouldUseQueryRouter(cloudActive: false), isTrue);
    });
  });

  group('verified local rewrite', () {
    test('accepts natural wording only when every exact fact survives', () {
      final answer = routeQuestion('how many lab reports do i have', _docs)!;
      expect(
        isValidVerifiedRewrite(
          'I found 2 lab reports in your records.',
          answer,
        ),
        isTrue,
      );
      expect(
        isValidVerifiedRewrite(
          'I found 3 lab reports in your records.',
          answer,
        ),
        isFalse,
      );
      expect(
        verifiedRewriteOrFallback(
          'I found 3 lab reports in your records.',
          answer,
        ),
        answer.text,
      );
      expect(
        isValidVerifiedRewrite('I found two reports in your records.', answer),
        isFalse,
      );
    });

    test('rejects dropped units, dates, ranges, status, and new numbers', () {
      final answer = routeQuestion(
        'what was my hemoglobin on September 3 2024',
        _docs,
      )!;
      expect(
        isValidVerifiedRewrite(
          'On Sep 3, 2024, your hemoglobin was 14.2 g/dL, within the normal '
          'range of 13–17 g/dL.',
          answer,
        ),
        isTrue,
      );
      expect(
        isValidVerifiedRewrite(
          'On Sep 3, 2024, your hemoglobin was 14.2 and looked normal.',
          answer,
        ),
        isFalse,
      );
      expect(
        isValidVerifiedRewrite(
          'On Sep 3, 2024, your hemoglobin was 14.2 g/dL, within the normal '
          'range of 13–17 g/dL; score 99.',
          answer,
        ),
        isFalse,
      );
    });

    test('not-found rewrite must remain negative', () {
      final answer = routeQuestion('what was my creatinine', _docs)!;
      expect(
        isValidVerifiedRewrite(
          "I don't see a creatinine reading in your records.",
          answer,
        ),
        isTrue,
      );
      expect(
        isValidVerifiedRewrite(
          'Your creatinine reading is available in your records.',
          answer,
        ),
        isFalse,
      );
    });

    test(
      'rewrite prompt is compact and contains no document inventory or OCR',
      () {
        final answer = routeQuestion(
          'how many ultrasounds do i have',
          _imaging,
        )!;
        final prompt = buildVerifiedRewritePrompt(
          'how many ultrasounds do i have',
          answer,
        );
        expect(prompt.length, lessThan(700));
        expect(prompt, contains('Verified answer: You have 2 ultrasounds.'));
        expect(prompt, isNot(contains('Complete record inventory')));
        expect(prompt, isNot(contains('Necrotic lymph node')));
        expect(answer.rewriteMaxTokens, 96);
      },
    );

    test('list rewrite must retain every report and gets a larger cap', () {
      final answer = routeQuestion('list my ultrasounds', _imaging)!;
      expect(answer.rewriteMaxTokens, 192);
      expect(
        isValidVerifiedRewrite(
          'You have 2 ultrasounds: Ultrasound of neck â€” Apr 2, 2025, and '
          'Ultrasound of jaw â€” Jan 23, 2025.',
          answer,
        ),
        isTrue,
      );
      expect(
        isValidVerifiedRewrite(
          'You have 2 ultrasounds: Ultrasound of neck â€” Apr 2, 2025.',
          answer,
        ),
        isFalse,
      );
    });
  });

  group('value lookup', () {
    test('multiple readings enumerate, newest first, cited to newest', () {
      final a = routeQuestion('what was my hemoglobin?', _docs)!;
      expect(a.text, contains('14.2 g/dL (Sep 3, 2024)'));
      expect(a.text, contains('11.0 g/dL (Aug 11, 2024)'));
      // Newest comes first in the sentence.
      expect(a.text.indexOf('14.2'), lessThan(a.text.indexOf('11.0')));
      expect(a.source?.id, _cbc.id);
    });

    test('date-scoped value is a single sentence, in range', () {
      final a = routeQuestion(
        'what was my hemoglobin on September 3 2024',
        _docs,
      )!;
      expect(
        a.text,
        'Your hemoglobin on Sep 3, 2024 was 14.2 g/dL, within the normal range (13–17 g/dL).',
      );
      expect(a.source?.id, _cbc.id);
    });

    test('below-range is reported as below', () {
      final a = routeQuestion('my hemoglobin on August 11 2024', _docs)!;
      expect(a.text, contains('below the normal range (13–17 g/dL)'));
      expect(a.source?.id, _lipid.id);
    });

    test('latest value picks newest and reads above-range for <100', () {
      final a = routeQuestion('what was my latest LDL', _docs)!;
      expect(a.text, contains('160 mg/dL'));
      expect(a.text, contains('above the normal range (<100)'));
      expect(a.source?.id, _cbc.id);
    });

    test('in-range for a <100 bound', () {
      final a = routeQuestion('what was my LDL on August 11 2024', _docs)!;
      expect(a.text, contains('within the normal range (<100)'));
      expect(a.source?.id, _lipid.id);
    });

    test('a test we do not have on that date is reported precisely', () {
      final a = routeQuestion('what was my hemoglobin in June 2024', _docs)!;
      expect(a.text, contains("don't see a hemoglobin reading from June 2024"));
      expect(a.source, isNull);
    });

    test('dotted acronym label matches a plain-acronym question (SGPT)', () {
      final lft = CuraDocument(
        id: 'lft',
        title: 'Liver function test',
        type: DocumentType.lab,
        date: DateTime(2024, 5, 2),
        results: const [DocumentResult('S.G.P.T', '55 U/L', range: '7–56')],
      );
      final a = routeQuestion('what is my sgpt', [lft])!;
      expect(a.text, contains('55 U/L'));
      expect(a.source?.id, 'lft');
    });

    test('plain-acronym label matches a dotted-acronym question', () {
      final lft = CuraDocument(
        id: 'lft2',
        title: 'Liver function test',
        type: DocumentType.lab,
        date: DateTime(2024, 5, 2),
        results: const [DocumentResult('SGPT', '55 U/L', range: '7–56')],
      );
      final a = routeQuestion('what is my s.g.p.t level', [lft])!;
      expect(a.text, contains('55 U/L'));
      expect(a.source?.id, 'lft2');
    });
  });

  group('latest report', () {
    test('most recent document with its contents', () {
      final a = routeQuestion('what is my most recent report', _docs)!;
      expect(a.text, contains('most recent'));
      expect(a.text, contains('Complete blood count'));
      expect(a.source?.id, _cbc.id);
    });

    test('latest of a type', () {
      final a = routeQuestion('my latest prescription', _docs)!;
      expect(a.text, contains('Amoxicillin 500 mg'));
      expect(a.source?.id, _rx.id);
    });
  });

  group('count', () {
    test('counts by type', () {
      expect(
        routeQuestion('how many lab reports do i have', _docs)!.text,
        'You have 2 lab reports.',
      );
      expect(
        routeQuestion('how many prescriptions', _docs)!.text,
        'You have 1 prescription.',
      );
    });

    test('carries the matching reports as cards, newest first', () {
      final a = routeQuestion('how many lab reports do i have', _docs)!;
      expect(a.kind, RoutedAnswerKind.count);
      expect(a.text, 'You have 2 lab reports.'); // text unchanged
      expect(a.sourceTotal, 2);
      expect(a.sources.map((d) => d.id), [
        'cbc',
        'lipid',
      ]); // Sep 3 before Aug 11
      expect(a.source?.id, 'cbc'); // primary = newest
    });

    test('a zero-match count carries no cards', () {
      final a = routeQuestion('how many cardiac enzyme reports do i have', [
        ..._docs,
      ])!;
      expect(a.sources, isEmpty);
      expect(a.source, isNull);
      expect(a.sourceTotal, 0);
    });

    test('carries every matching card while keeping newest-first order', () {
      final many = [
        for (var i = 0; i < 9; i++)
          CuraDocument(
            id: 'lab$i',
            title: 'Panel $i',
            type: DocumentType.lab,
            date: DateTime(2024, 1, i + 1),
          ),
      ];
      final a = routeQuestion('how many lab reports do i have', many)!;
      expect(a.sourceTotal, 9);
      expect(a.sources.length, 9);
      expect(a.sources.first.id, 'lab8'); // Jan 9 — newest
      expect(a.sources.last.id, 'lab0');
      expect(a.sourcesAreAuthoritative, isTrue);
    });

    test('free-form collection matches titles instead of every document', () {
      final lft = CuraDocument(
        id: 'lft',
        title: 'Liver function test',
        type: DocumentType.lab,
        date: DateTime(2025, 1, 2),
      );
      final docs = [..._docs, lft];
      expect(
        routeQuestion('how many liver function tests do i have', docs)!.text,
        'You have 1 matching record.',
      );
      expect(
        routeQuestion('how many cardiac enzyme reports do i have', docs)!.text,
        'You have 0 matching records.',
      );
      final latest = routeQuestion('my latest liver function test', docs)!;
      expect(latest.text, contains('Liver function test'));
      expect(latest.source?.id, 'lft');
      expect(
        routeQuestion(
          'how many liver function tests do i have',
          docs,
        )!.sourcesAreAuthoritative,
        isFalse,
      );
    });
  });

  group('modality-aware imaging (count / latest / list)', () {
    test('counts ultrasounds, not all imaging', () {
      expect(
        routeQuestion('how many ultrasounds do i have', _imaging)!.text,
        'You have 2 ultrasounds.',
      );
    });

    test('a bare imaging word still counts every imaging report', () {
      expect(
        routeQuestion('how many imaging reports do i have', _imaging)!.text,
        'You have 3 imaging reports.',
      );
    });

    test('latest ultrasound picks the newest ultrasound (not the X-ray)', () {
      final a = routeQuestion('what is my latest ultrasound', _imaging)!;
      expect(a.source?.id, 'us-apr'); // Apr 2 ultrasound, newer than the X-ray
      expect(a.text, contains('ultrasound'));
    });

    test('lists only the ultrasounds', () {
      final a = routeQuestion('list my ultrasounds', _imaging)!;
      expect(a.text, contains('2 ultrasounds'));
      expect(a.text, contains('Ultrasound of neck'));
      expect(a.text, isNot(contains('Chest X-ray')));
    });
  });

  group('list / date-doc', () {
    test('lists all documents from a year', () {
      final a = routeQuestion('documents from 2024', _docs)!;
      expect(a.text, contains('You have 4 documents from 2024:'));
      expect(a.text, contains('• Complete blood count, Sep 3, 2024'));
      expect(a.sources.length, 4);
      expect(a.sourceTotal, 4);
      expect(a.sourcesAreAuthoritative, isTrue);
    });

    test('lists a typed collection', () {
      final a = routeQuestion('list my lab reports', _docs)!;
      expect(a.text, contains('2 lab reports'));
      expect(a.text, contains('• Lipid panel, Aug 11, 2024'));
      expect(a.sources.map((d) => d.id), ['cbc', 'lipid']);
      expect(a.sourceTotal, 2);
    });

    test('a single document on a specific day shows its contents', () {
      final a = routeQuestion(
        "what's in my report from September 3 2024",
        _docs,
      )!;
      expect(a.text, contains('Complete blood count'));
      expect(a.text, contains('Hemoglobin 14.2 g/dL'));
      expect(a.source?.id, _cbc.id);
    });
  });

  group('falls through to the LLM (returns null)', () {
    test('reasoning / interpretation / advice', () {
      expect(routeQuestion('explain my latest results', _docs), isNull);
      expect(routeQuestion('summarize my blood count', _docs), isNull);
      expect(routeQuestion('why is my hemoglobin low', _docs), isNull);
      expect(routeQuestion('what does my LDL mean', _docs), isNull);
      expect(routeQuestion('is my hemoglobin normal', _docs), isNull);
      expect(routeQuestion('should I worry about my LDL', _docs), isNull);
    });

    test('general-knowledge definition (not personal)', () {
      expect(routeQuestion('what is cholesterol', _docs), isNull);
      expect(routeQuestion('what is a normal hemoglobin', _docs), isNull);
    });

    test('vague or unknown (no recognised test) stays null', () {
      expect(routeQuestion('my results', _docs), isNull);
    });
  });

  group('named test we do not have → says so, never fabricates', () {
    test('recognised test absent from records', () {
      // We have hemoglobin/LDL/glucose fixtures but no creatinine reading.
      final a = routeQuestion('what was my creatinine', _docs)!;
      expect(a.text, contains("don't see a reading for creatinine"));
      expect(a.source, isNull);
    });

    test(
      'says not-found regardless of phrasing for a named-but-absent test',
      () {
        expect(
          routeQuestion('my latest creatinine', _docs)!.text,
          contains("don't see"),
        );
        expect(
          routeQuestion('list my creatinine reports', _docs)!.text,
          contains("don't see"),
        );
      },
    );

    test('no documents', () {
      expect(routeQuestion('what was my hemoglobin', const []), isNull);
    });
  });
}
