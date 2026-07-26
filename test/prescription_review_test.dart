import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/library/document.dart';
import 'package:cura/features/library/document_detail_screen.dart';
import 'package:cura/features/scan/review_document_screen.dart';

void main() {
  CuraDocument prescription({
    List<DocumentResult> results = const [],
    String? summary,
  }) => CuraDocument(
    id: 'rx-test',
    title: 'Old Follow up',
    type: DocumentType.prescription,
    date: DateTime(2026, 1, 20),
    extractedText: 'Rx\nBALBACK PRO SERUM\n1 ml locally twice daily',
    results: results,
    resultsNote: summary,
  );

  void useTallTestView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'offline prescription shows editable summary and medicine empty state',
    (tester) async {
      useTallTestView(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: ReviewDocumentScreen(draft: prescription())),
        ),
      );

      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Medicines'), findsOneWidget);
      expect(find.text('Checking prescription…'), findsNothing);
      expect(
        find.text('No clear medicines found. Add one if needed.'),
        findsOneWidget,
      );
      expect(find.text('Add medicine'), findsOneWidget);
      expect(find.text('Unit'), findsNothing);
      expect(find.text('Normal range'), findsNothing);
    },
  );

  testWidgets('detail shows prescription summary and medicines separately', (
    tester,
  ) async {
    useTallTestView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentDetailScreen(
          document: prescription(
            summary: 'Follow-up for seborrheic dermatitis.',
            results: const [
              DocumentResult(
                'BALBACK PRO SERUM',
                '1 ml locally on scalp, twice daily',
              ),
            ],
          ),
          onUpdate: (_) {},
          onDelete: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Medicines'), findsOneWidget);
    expect(find.text('Follow-up for seborrheic dermatitis.'), findsOneWidget);
    expect(find.text('BALBACK PRO SERUM'), findsOneWidget);
    expect(find.text('1 ml locally on scalp, twice daily'), findsOneWidget);
    expect(find.text('Results'), findsNothing);
  });
}
