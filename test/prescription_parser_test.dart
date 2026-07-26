// Tests for the deterministic prescription extractor (no model): the medicine
// parser plus the verbatim clinical Summary via ScanService.parsePrescription.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/scan/prescription_parser.dart';
import 'package:cura/features/scan/scan_extraction.dart';
import 'package:cura/features/scan/scan_service.dart';

void main() {
  group('parsePrescriptionMedicines', () {
    test('splits name+strength from directions at the first schedule token', () {
      final meds = parsePrescriptionMedicines(
        'Tab. Amoxicillin 500mg 1-0-1 x 5 days',
      );
      expect(meds, hasLength(1));
      expect(meds.single.label, 'Tab. Amoxicillin 500mg');
      expect(meds.single.value, '1-0-1 x 5 days');
    });

    test('splits at a worded frequency phrase', () {
      final meds = parsePrescriptionMedicines(
        'Cap Paracetamol 650mg twice daily for 3 days',
      );
      expect(meds.single.label, 'Cap Paracetamol 650mg');
      expect(meds.single.value, 'twice daily for 3 days');
    });

    test('handles a leading index and an abbreviated frequency', () {
      final meds = parsePrescriptionMedicines(
        '1) Tab Azithromycin 500 mg OD x 3 days',
      );
      expect(meds.single.label, 'Tab Azithromycin 500 mg');
      expect(meds.single.value, 'OD x 3 days');
    });

    test('a form-only line keeps the whole line as the name', () {
      final meds = parsePrescriptionMedicines('Tab Vitamin D3');
      expect(meds.single.label, 'Tab Vitamin D3');
      expect(meds.single.value, '');
    });

    test('rejects lab values and vitals (number without medicine signal)', () {
      final meds = parsePrescriptionMedicines(
        'Hemoglobin 13.5 g/dl\nBP 120/80 mmHg\nPulse 72 /min',
      );
      expect(meds, isEmpty);
    });

    test('parses each medicine of a multi-line prescription once', () {
      const rx = '''
Rx
Tab Paracetamol 650mg 1-0-1 x 3 days
Syrup Ambroxol 5ml TDS
Tab Paracetamol 650mg 1-0-1 x 3 days
''';
      final meds = parsePrescriptionMedicines(rx);
      // The duplicate line collapses; the two distinct medicines remain.
      expect(meds.map((m) => m.label), ['Tab Paracetamol 650mg', 'Syrup Ambroxol 5ml']);
    });
  });

  group('ScanService.parsePrescription', () {
    final svc = ScanService();

    test('captures the clinical narrative as Summary, medicines separately', () {
      const rx = '''
Dr. Grace Quinn, MD
Chief Complaints: Fever and cough for 3 days
Diagnosis: Viral fever
Rx
Tab Paracetamol 650mg 1-0-1 x 3 days
Advice: Take rest and plenty of fluids
Follow up: after 5 days
''';
      final result = svc.parsePrescription(rx);

      // Summary is the verbatim clinical sections — not the medicine line.
      expect(result.summary, contains('Viral fever'));
      expect(result.summary, contains('Follow Up'));
      expect(result.summary, isNot(contains('Paracetamol')));

      // Medicines are the separate structured rows.
      expect(result.medicines, hasLength(1));
      expect(result.medicines.single.label, 'Tab Paracetamol 650mg');
      expect(result.medicines.single.value, '1-0-1 x 3 days');
    });
  });

  // firstCompleteJsonObject is the streaming-JSON extractor parseScanExtraction
  // uses for every document type.
  group('firstCompleteJsonObject', () {
    test('returns a complete object and ignores trailing output', () {
      const raw =
          '```json\n'
          '{"type":"prescription","results":[],"note":"Follow-up"}'
          '\n```\nextra text';

      expect(
        firstCompleteJsonObject(raw),
        '{"type":"prescription","results":[],"note":"Follow-up"}',
      );
    });

    test('handles escaped quotes and braces inside strings', () {
      const raw =
          '{"type":"prescription","note":"Printed \\"brace { text }\\"",'
          '"results":[{"label":"SERUM (6)","value":"Use daily"}]}';

      expect(firstCompleteJsonObject(raw), raw);
    });

    test('waits when a streamed object is truncated', () {
      const partial = '{"type":"prescription","results":[{"label":"SERUM"}';

      expect(firstCompleteJsonObject(partial), isNull);
      expect(firstCompleteJsonObject('$partial]}'), '$partial]}');
    });

    test('rejects a balanced but malformed object', () {
      expect(firstCompleteJsonObject('{type: prescription}'), isNull);
    });
  });
}
