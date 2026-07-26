import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/ai/ai_service.dart';
import 'package:cura/features/library/document.dart';
import 'package:cura/features/scan/scan_extraction.dart';
import 'package:cura/features/scan/table_parser.dart';

void main() {
  test('prescriptions and local narrative reports have no model job', () {
    expect(
      AiService.scanRefinementFields(
        draftType: DocumentType.prescription,
        useRemote: true,
      ),
      isEmpty,
    );
    expect(
      AiService.scanRefinementFields(
        draftType: DocumentType.discharge,
        useRemote: false,
      ),
      isEmpty,
    );
  });

  test('narrative reports target metadata only', () {
    final fields = AiService.scanRefinementFields(
      draftType: DocumentType.imaging,
      useRemote: true,
      title: 'PET-CT Scan',
    );

    expect(
      fields,
      equals({
        ScanRefinementField.title,
        ScanRefinementField.type,
        ScanRefinementField.date,
      }),
    );
  });

  test('receipt targets only its semantic title and purpose note', () {
    final generic = AiService.scanRefinementFields(
      draftType: DocumentType.receipt,
      useRemote: true,
      title: 'Receipt',
    );
    final specific = AiService.scanRefinementFields(
      draftType: DocumentType.receipt,
      useRemote: true,
      title: 'Meadowlark invoice',
    );

    const expected = {
      ScanRefinementField.title,
      ScanRefinementField.receiptNote,
    };
    expect(generic, equals(expected));
    expect(specific, equals(expected));
  });

  test('lab results are targeted only when OCR-cell repair is required', () {
    const evidence = TableRepairEvidence(
      [],
      requiresReconciliation: true,
      cells: [
        TableGridCell(
          id: 'value_1',
          text: '12.4',
          column: TableCellColumn.value,
          rowHint: 1,
        ),
      ],
    );
    final repair = AiService.scanRefinementFields(
      draftType: DocumentType.lab,
      useRemote: true,
      tableEvidence: evidence,
    );
    final complete = AiService.scanRefinementFields(
      draftType: DocumentType.lab,
      useRemote: true,
    );

    expect(repair, contains(ScanRefinementField.results));
    expect(complete, isNot(contains(ScanRefinementField.results)));
  });

  test('compact contracts do not request discarded narrative summaries', () {
    final metadata = AiService.scanExtractionSystemPrompt(
      ScanExtractionMode.metadata,
    );
    final receipt = AiService.scanExtractionSystemPrompt(
      ScanExtractionMode.receipt,
    );

    expect(metadata.length, lessThan(1000));
    expect(metadata, isNot(contains('"note"')));
    expect(metadata, isNot(contains('prescription')));
    expect(metadata, isNot(contains('FULL clinical')));
    expect(receipt.length, lessThan(1000));
    expect(receipt, contains('"note"'));
    expect(receipt, contains('"title"'));
    expect(receipt, contains('Do not return type, date'));
    expect(receipt, isNot(contains('FULL clinical')));
  });

  test('field allowlist drops an unexpected provider summary', () {
    const extraction = ScanExtraction(
      title: 'CT Scan',
      type: DocumentType.imaging,
      note: 'Unexpected cloud summary',
    );
    final allowed = extraction.only({
      ScanRefinementField.title,
      ScanRefinementField.type,
      ScanRefinementField.date,
    });

    expect(allowed.title, 'CT Scan');
    expect(allowed.note, isNull);
  });
}
