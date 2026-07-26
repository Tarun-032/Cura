import 'package:cura/features/ai/query_router.dart';
import 'package:cura/features/ai/retrieval.dart';
import 'package:cura/features/ask/ask_prompt_rotation.dart';
import 'package:cura/features/library/document.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Home examples advance in order and wrap', () async {
    final rotation = AskPromptRotation();
    final actual = <String>[];
    for (var i = 0; i <= kHomeAskExamples.length; i++) {
      actual.add(await rotation.takeNextHomeExample());
    }

    expect(actual.take(kHomeAskExamples.length), kHomeAskExamples);
    expect(actual.last, kHomeAskExamples.first);
  });

  test('Ask sets persist across route-owner instances and wrap', () async {
    final actual = <AskPromptSet>[];
    for (var i = 0; i < kAskPromptSets.length; i++) {
      // A new owner models leaving Ask and later constructing another route.
      actual.add(await AskPromptRotation().takeNextAskSet());
    }
    expect(actual, kAskPromptSets);

    final wrapped = await AskPromptRotation().takeNextAskSet();
    expect(wrapped, same(kAskPromptSets.first));
  });

  test('every suggestion has a valid router or grounding path', () {
    final docs = <CuraDocument>[
      CuraDocument(
        id: 'cbc',
        title: 'Complete blood count',
        type: DocumentType.lab,
        date: DateTime(2026, 7, 18),
        results: const [DocumentResult('Hemoglobin', '14.2 g/dL')],
      ),
      CuraDocument(
        id: 'receipt',
        title: 'Pharmacy receipt',
        type: DocumentType.receipt,
        date: DateTime(2026, 1, 21),
        results: const [DocumentResult('Final amount', '₹1,956.00')],
      ),
    ];

    for (final set in kAskPromptSets) {
      expect(set.suggestions, hasLength(2));
      for (final prompt in set.suggestions) {
        final routed = routeQuestion(prompt, docs);
        final grounding = groundingFor(prompt, docs);
        expect(
          routed != null || grounding.kind != GroundingKind.none,
          isTrue,
          reason: 'No valid Ask path for "$prompt".',
        );
      }
    }
  });
}
