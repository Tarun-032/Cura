import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/library/document.dart';
import 'package:cura/features/scan/review_document_screen.dart';
import 'package:cura/features/scan/scan_extraction.dart';

void main() {
  CuraDocument document({
    DocumentType type = DocumentType.lab,
    String title = 'Lab report',
    String text = 'CBC Haemogram\nReport date 20-01-2026',
    String? note,
    List<DocumentResult> results = const [],
  }) => CuraDocument(
    id: 'refinement-test',
    title: title,
    type: type,
    date: DateTime(2026, 1, 20),
    extractedText: text,
    results: results,
    resultsNote: note,
  );

  ScanRefinementJob job(
    Completer<ScanExtraction?> completer,
    Set<ScanRefinementField> fields, {
    void Function()? onCancel,
  }) => ScanRefinementJob(
    fields: fields,
    result: completer.future,
    onCancel: onCancel ?? () {},
  );

  ElevatedButton saveButton(WidgetTester tester) =>
      tester.widget(find.widgetWithText(ElevatedButton, 'Save to device'));

  void useTallTestView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'shows only targeted field work and gates Save until completion',
    (tester) async {
      useTallTestView(tester);
      final completer = Completer<ScanExtraction?>();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ReviewDocumentScreen(
              draft: document(),
              refinement: job(completer, const {
                ScanRefinementField.title,
                ScanRefinementField.type,
                ScanRefinementField.date,
              }),
            ),
          ),
        ),
      );

      expect(find.text('Writing title…'), findsOneWidget);
      expect(find.text('Checking type…'), findsOneWidget);
      expect(find.text('Checking date…'), findsOneWidget);
      expect(find.text('Checking results…'), findsNothing);
      expect(find.text('Writing bill note…'), findsNothing);
      expect(saveButton(tester).onPressed, isNull);

      completer.complete(
        ScanExtraction(
          title: 'CBC Haemogram',
          type: DocumentType.lab,
          date: DateTime(2026, 1, 20),
          note: 'This unexpected summary must be ignored.',
        ),
      );
      await tester.pump();

      expect(find.text('Writing title…'), findsNothing);
      expect(find.text('Checking type…'), findsNothing);
      expect(find.text('Checking date…'), findsNothing);
      expect(
        find.text('This unexpected summary must be ignored.'),
        findsNothing,
      );
      expect(find.text('CBC Haemogram'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNotNull);
    },
  );

  testWidgets(
    'a user-filled receipt note cancels its job and unlocks Save',
    (tester) async {
      useTallTestView(tester);
      final completer = Completer<ScanExtraction?>();
      var cancelled = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ReviewDocumentScreen(
              draft: document(
                type: DocumentType.receipt,
                title: 'Meadowlark bill',
                text: 'Meadowlark bill\nConsultation\n20-01-2026\nTotal 500',
              ),
              refinement: job(completer, const {
                ScanRefinementField.receiptNote,
              }, onCancel: () => cancelled = true),
            ),
          ),
        ),
      );

      expect(find.text('Writing bill note…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('receipt-note-refinement-status')),
        findsOneWidget,
      );
      expect(saveButton(tester).onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('receipt-note')),
        'My corrected purpose',
      );
      await tester.pump();

      expect(find.text('Writing bill note…'), findsNothing);
      expect(cancelled, isTrue);
      expect(saveButton(tester).onPressed, isNotNull);

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('receipt-note')),
      );
      expect(field.controller!.text, 'My corrected purpose');
      expect(saveButton(tester).onPressed, isNotNull);
    },
  );

  testWidgets(
    'bill title and note show independent work and both accept refinement',
    (tester) async {
      useTallTestView(tester);
      final completer = Completer<ScanExtraction?>();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ReviewDocumentScreen(
              draft: document(
                type: DocumentType.receipt,
                title: 'Medical Stores invoice',
                text: 'Medical Stores invoice\nHair medicines\nTotal 1250',
              ),
              refinement: job(completer, const {
                ScanRefinementField.title,
                ScanRefinementField.receiptNote,
              }),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('title-refinement-status')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('receipt-note-refinement-status')),
        findsOneWidget,
      );
      expect(saveButton(tester).onPressed, isNull);

      completer.complete(
        const ScanExtraction(
          title: 'Hair medicines invoice',
          note: 'This bill was for hair medicines.',
        ),
      );
      await tester.pump();

      expect(find.text('Hair medicines invoice'), findsOneWidget);
      final note = tester.widget<TextField>(
        find.byKey(const ValueKey('receipt-note')),
      );
      expect(note.controller!.text, 'This bill was for hair medicines.');
      expect(
        find.byKey(const ValueKey('title-refinement-status')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('receipt-note-refinement-status')),
        findsNothing,
      );
      expect(saveButton(tester).onPressed, isNotNull);
    },
  );

  testWidgets(
    'Save unlocks when the user fills both pending bill fields',
    (tester) async {
      useTallTestView(tester);
      final completer = Completer<ScanExtraction?>();
      var cancelled = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ReviewDocumentScreen(
              draft: document(
                type: DocumentType.receipt,
                title: 'Receipt',
                text: 'Receipt\nConsultation\nTotal 500',
              ),
              refinement: job(
                completer,
                const {
                  ScanRefinementField.title,
                  ScanRefinementField.receiptNote,
                },
                onCancel: () => cancelled = true,
              ),
            ),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('receipt-note')),
        'Consultation',
      );
      await tester.pump();
      expect(saveButton(tester).onPressed, isNull);
      expect(cancelled, isFalse);

      await tester.enterText(
        find.byKey(const ValueKey('document-title')),
        'Consultation bill',
      );
      await tester.pump();

      expect(cancelled, isTrue);
      expect(saveButton(tester).onPressed, isNotNull);
      expect(find.text('Writing title…'), findsNothing);
      expect(find.text('Writing bill note…'), findsNothing);
    },
  );

  testWidgets('times out silently, cancels the job, and enables Save', (
    tester,
  ) async {
    useTallTestView(tester);
    final completer = Completer<ScanExtraction?>();
    var cancelled = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ReviewDocumentScreen(
            draft: document(),
            refinement: job(completer, const {
              ScanRefinementField.title,
            }, onCancel: () => cancelled = true),
          ),
        ),
      ),
    );

    expect(saveButton(tester).onPressed, isNull);
    await tester.pump(const Duration(seconds: 15));

    expect(cancelled, isTrue);
    expect(find.text('Writing title…'), findsNothing);
    expect(find.textContaining('Couldn'), findsNothing);
    expect(saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('keeps deterministic narrative summary during metadata work', (
    tester,
  ) async {
    useTallTestView(tester);
    final completer = Completer<ScanExtraction?>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ReviewDocumentScreen(
            draft: document(
              type: DocumentType.discharge,
              title: 'Discharge summary',
              text: 'DISCHARGE SUMMARY\nDiagnosis: recovered',
              note: 'Diagnosis: recovered.',
            ),
            refinement: job(completer, const {
              ScanRefinementField.title,
              ScanRefinementField.type,
              ScanRefinementField.date,
            }),
          ),
        ),
      ),
    );

    expect(find.text('Diagnosis: recovered.'), findsOneWidget);
    expect(find.textContaining('Writing summary'), findsNothing);

    completer.complete(
      const ScanExtraction(note: 'Cloud-generated narrative summary.'),
    );
    await tester.pump();

    expect(find.text('Diagnosis: recovered.'), findsOneWidget);
    expect(find.text('Cloud-generated narrative summary.'), findsNothing);
  });

  group('the background rewrite hint', () {
    // Long enough to clear the one-sentence floor in needsSummaryRewrite.
    const scraped =
        'Indication: Persistent cough for six weeks. Findings: Right lower '
        'lobe consolidation measuring 3.2 cm. Impression: pneumonia.';

    Future<void> pumpReview(
      WidgetTester tester, {
      required CuraDocument draft,
      bool isEditing = false,
    }) async {
      useTallTestView(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ReviewDocumentScreen(draft: draft, isEditing: isEditing),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('sits on the Summary row and explains itself on tap', (
      tester,
    ) async {
      await pumpReview(
        tester,
        draft: document(
          type: DocumentType.imaging,
          title: 'Chest CT',
          text: 'CHEST CT\n$scraped',
          note: scraped,
        ),
      );

      expect(find.text('Cura will tidy this up'), findsOneWidget);
      // The old full-width paragraph is gone from the page itself.
      expect(find.textContaining('Cura will rewrite'), findsNothing);

      await tester.tap(find.text('Cura will tidy this up'));
      await tester.pumpAndSettle();

      // A popup hanging off the icon, not a full-screen dialog.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('Cura will rewrite'), findsOneWidget);

      // Tapping away closes it.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.textContaining('Cura will rewrite'), findsNothing);
    });

    testWidgets('is absent when editing a saved record', (tester) async {
      await pumpReview(
        tester,
        isEditing: true,
        draft: document(
          type: DocumentType.imaging,
          title: 'Chest CT',
          text: 'CHEST CT\n$scraped',
          note: scraped,
        ),
      );

      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Cura will tidy this up'), findsNothing);
    });

    testWidgets('is absent on a summary that never gets rewritten', (
      tester,
    ) async {
      // A lab report's note is a computed counts line, not a scraped dump.
      await pumpReview(
        tester,
        draft: document(note: '4 results · all within the normal range'),
      );

      expect(find.text('Cura will tidy this up'), findsNothing);
    });
  });
}
