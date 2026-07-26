// Tests for the qualitative results reader — the fallback for pages the numeric
// table reader deliberately skips (verdict-style and narrative reports).

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/scan/qualitative_parser.dart';
import 'package:cura/features/scan/table_parser.dart';

// Helper: a line at (x, y) with a fixed height so row grouping has geometry.
OcrLine line(String text, double x, double y) =>
    OcrLine(text, x, y, x + text.length * 10, y + 24);

void main() {
  group('parseQualitativeResults', () {
    test('pairs a label cell with a verdict cell across the row (Xpert)', () {
      // "MTB COMPLEX" on the left, "Not Detected" in the RESULT column.
      final lines = [
        line('TEST NAME', 40, 100),
        line('RESULT', 500, 100),
        line('XPERT MTB/RIF ULTRA', 40, 140),
        line('MTB COMPLEX', 40, 180),
        line('Not Detected', 500, 182),
      ];
      final results = parseQualitativeResults(lines);
      expect(results, hasLength(1));
      expect(results.single.label, 'MTB COMPLEX');
      expect(results.single.value, 'Not Detected');
    });

    test('accepts a verdict merged onto one line', () {
      final lines = [line('HIV I & II : Non-Reactive', 40, 100)];
      final results = parseQualitativeResults(lines);
      expect(results, hasLength(1));
      expect(results.single.label, 'HIV I & II');
      expect(results.single.value, 'Non-Reactive');
    });

    test('never treats prose containing a verdict word as a result', () {
      final lines = [
        line('Test performed using the Xpert assay. This is a', 40, 100),
        line('semi-quantitative test for the detection of TB.', 40, 140),
      ];
      expect(parseQualitativeResults(lines), isEmpty);
    });

    test('skips patient/letterhead noise as labels', () {
      final lines = [
        line("Patient's Name", 40, 100),
        line('Present', 500, 100),
      ];
      expect(parseQualitativeResults(lines), isEmpty);
    });

    test('pairs label + verdict from reading-order text lines', () {
      // The real Xpert scan: OCR boxes are columnar, but the reading-order text
      // puts label and verdict on one line — where we reliably pair them.
      final results = parseQualitativeResults(
        const [],
        textLines: const [
          'EST NAME  RESULT',
          'CPERT MTB/RIF ULTRA',
          'Right supraclavicular LN',
          'TB COMPLEX  Not Detected',
          'omments :  Xpert MTB/RIF Ultra',
        ],
      );
      expect(results, hasLength(1));
      expect(results.single.label, 'TB COMPLEX');
      expect(results.single.value, 'Not Detected');
    });

    test('does not invent numeric rows from narrative prose', () {
      // A PET-CT protocol line mentions a fasting blood sugar; it must NOT become
      // a result row (those numbers belong in the findings summary, not Results).
      final lines = [
        line('The fasting blood sugar level at the time of tracer', 40, 100),
        line('injection was 89 mg/dl.', 40, 140),
      ];
      expect(parseQualitativeResults(lines), isEmpty);
    });

    test('agrees with the table reader: numeric pages defer, not double-count',
        () {
      // A numeric table page: parseResultsTable handles it, so recognize() never
      // calls the qualitative reader — but even if it did, no verdict words here.
      final lines = [
        line('Hemoglobin', 40, 100),
        line('14.2', 400, 100),
        line('13 - 17', 700, 100),
      ];
      expect(parseResultsTable(lines), isNotEmpty);
      expect(parseQualitativeResults(lines), isEmpty);
    });
  });
}
