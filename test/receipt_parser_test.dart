// Unit tests for the geometry-based bill reader, modeled on two real documents:
// an OP cash bill (one service row, the same total printed under five names) and
// a pharmacy GST invoice (only the rightmost money column is the amount).

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/scan/receipt_parser.dart';
import 'package:cura/features/scan/table_parser.dart';

OcrLine _l(String text, double left, double y, double right) =>
    OcrLine(text, left, y - 10, right, y + 10);

OcrElementBox _e(
  String text,
  double left,
  double y,
  double right, {
  int parent = 0,
}) => OcrElementBox(text, left, y - 10, right, y + 10, parentLine: parent);

void main() {
  group('looksLikeBill', () {
    test('hospital cash bill without the word "receipt"', () {
      expect(
        looksLikeBill(
          'Day Care/OP Cash Bill - Bill of Supply\n'
          'GSTIN : 27AAAAA0000A1Z5\n'
          'Amount in words: Three Thousand Only',
        ),
        isTrue,
      );
    });

    test('GST invoice', () {
      expect(
        looksLikeBill('GST INVOICE\nFENWICK MEDICAL STORES\nNET : 1956.00'),
        isTrue,
      );
    });

    test('a lab report with a stray Bill No line does not flip', () {
      expect(
        looksLikeBill(
          'Pathology Laboratory\nBill No: 1234\n'
          'Haemoglobin 13.0 g/dL 14-18',
        ),
        isFalse,
      );
    });

    test('plain lab report is not a bill', () {
      expect(looksLikeBill('COMPLETE BLOOD COUNT\nHaemoglobin 13.0'), isFalse);
    });
  });

  group('parseReceiptBreakdown — Meadowlark OP cash bill', () {
    final lines = <OcrLine>[
      _l('GSTIN : 27AAAAA0000A1Z5', 40, 100, 300),
      _l('Day Care/OP Cash Bill - Bill of Supply', 340, 100, 700),
      _l('CellNo:91-9000000000', 60, 150, 260),
      _l('Bill Amount: `. 3,360.00', 60, 200, 320),
      _l(
        'Amount in words: ` Three Thousand Three Hundred Sixty Only',
        60,
        240,
        560,
      ),
      _l('S.No', 40, 300, 80),
      _l('Service Type/Service Name', 120, 300, 340),
      _l('Amount (INR)', 800, 300, 920),
      _l('1', 40, 360, 60),
      _l('Investigations (999311 )', 120, 360, 320),
      _l('1', 46, 400, 60),
      _l('USG Small Part', 90, 400, 260),
      _l('Ultrasound Radiology', 300, 400, 480),
      _l('1', 520, 400, 534),
      _l('3,360.00', 600, 400, 680),
      _l('0.00', 720, 400, 760),
      _l('3,360.00', 820, 400, 900),
      _l('Sub Total', 690, 440, 770),
      _l('3,360.00', 820, 440, 900),
      _l('Service Amount :', 60, 520, 200),
      _l('3,360.00', 820, 520, 900),
      _l('Total Bill Amount', 60, 560, 220),
      _l('3,360.00', 820, 560, 900),
      _l('Final Payment', 60, 600, 180),
      _l('(Cash:0.00, NonCash:3,360.00)', 300, 600, 560),
      _l('3,360.00', 820, 600, 900),
      _l(
        'Receipt Details: Received with thanks sum of `. 3,360.00 (CARD)',
        60,
        650,
        620,
      ),
      _l('Home Collection: 74000 63150', 60, 700, 300),
    ];
    const pageText = 'Day Care/OP Cash Bill GSTIN Amount (INR)';

    test('one item, one deduped total, currency prefixed', () {
      final rows = parseReceiptBreakdown(lines, pageText: pageText);
      expect(rows.map((r) => r.label).toList(), [
        'USG Small Part',
        'Final amount',
      ]);
      expect(rows[0].value, '₹3,360.00');
      expect(rows[1].value, '₹3,360.00');
    });

    test('no row carries a range or a lab unit', () {
      for (final r in parseReceiptBreakdown(lines, pageText: pageText)) {
        expect(r.range, isNull);
        expect(r.unit, isNull);
      }
    });
  });

  group('parseReceiptBreakdown — pharmacy GST invoice', () {
    final lines = <OcrLine>[
      _l('GST INVOICE', 40, 100, 160),
      _l('FENWICK MEDICAL STORES', 300, 100, 520),
      _l('GST NO:27ABDFA0179N1Z8', 40, 140, 280),
      _l('MOB. NO 8000000000', 400, 140, 580),
      _l('Qty', 40, 200, 70),
      _l('Product Name', 100, 200, 220),
      _l('MRP', 300, 200, 340),
      _l('Amount', 870, 200, 940),
      _l('1', 46, 260, 60),
      _l('BALBACK PRO 60ML', 100, 260, 260),
      _l('1440.00', 300, 260, 360),
      _l('AAKAAR M', 400, 260, 470),
      _l('BCC4754', 500, 260, 570),
      _l('10/26', 600, 260, 650),
      _l('18', 680, 260, 700),
      _l('109.83', 720, 260, 770),
      _l('109.83', 790, 260, 840),
      _l('1440.00', 870, 260, 940),
      _l('20', 40, 300, 62),
      _l('CERATINA CAP', 100, 300, 230),
      _l('258.05', 300, 300, 355),
      _l('BIOPHARM', 400, 300, 470),
      _l('CER5C02A', 500, 300, 570),
      _l('02/27', 600, 300, 650),
      _l('5', 684, 300, 694),
      _l('12.29', 720, 300, 765),
      _l('12.29', 790, 300, 835),
      _l('516.10', 870, 300, 935),
      _l('Gross :', 600, 380, 660),
      _l('1956.10', 870, 380, 935),
      _l('Less :', 600, 420, 650),
      _l('0.00', 870, 420, 910),
      _l('GST Tax:', 600, 460, 675),
      _l('244.24', 870, 460, 930),
      _l('NET :', 600, 500, 650),
      _l('1956.00', 870, 500, 935),
      _l('Get Well Soon', 300, 560, 430),
    ];
    const pageText = 'GST INVOICE GST NO:27ABDFA0179N1Z8';

    test('rightmost money column wins; summary rows classified', () {
      final rows = parseReceiptBreakdown(lines, pageText: pageText);
      expect(rows.map((r) => r.label).toList(), [
        'BALBACK PRO 60ML',
        'CERATINA CAP',
        'Gross',
        'GST Tax',
        'Final amount',
      ]);
      // Amount column, not MRP/SGST/CGST.
      expect(rows[0].value, '₹1440.00');
      expect(rows[1].value, '₹516.10');
      // Gross ≠ NET, so it is kept; zero "Less" is dropped.
      expect(rows[2].value, '₹1956.10');
      expect(rows[3].value, '₹244.24');
      expect(rows[4].value, '₹1956.00');
    });

    test('ids, phones, batch codes and expiry dates never become rows', () {
      final rows = parseReceiptBreakdown(lines, pageText: pageText);
      final labels = rows.map((r) => r.label.toLowerCase()).join(' ');
      expect(labels.contains('gst no'), isFalse);
      expect(labels.contains('mob'), isFalse);
      expect(labels.contains('bcc4754'), isFalse);
    });
  });

  group('parseReceiptBreakdown — layout noise (real pharmacy failures)', () {
    // Footer and registration lines share visual rows with the summary amounts,
    // and comp/batch cells sit beside the MRP column. Amount-column locking,
    // keyword-owned summary labels and the id filter must exclude all of it.
    final lines = <OcrLine>[
      _l('BALBACK PRO 60ML', 100, 100, 260),
      _l('1440.00', 300, 100, 360), // MRP column
      _l('1440.00', 870, 100, 940), // Amount column
      _l('AAKAAR M', 100, 140, 180), // comp/batch row, MRP-column money only
      _l('BCC4754', 200, 140, 270),
      _l('258.05', 300, 140, 355),
      _l('GST NO:27ABDFA0179N1Z8', 40, 380, 280),
      _l('Gross :', 600, 380, 660),
      _l('1956.10', 870, 380, 935),
      _l('SHOP NO. 1 SEC-1-S', 40, 420, 240),
      _l('Less :', 600, 420, 650),
      _l('0.00', 870, 420, 910),
      _l('PLOT NO 46 NEW FAIRVIEW', 40, 460, 260),
      _l('GST Tax:', 600, 460, 675),
      _l('244.24', 870, 460, 930),
      _l('Get Well Soon', 40, 500, 170),
      _l('NET :', 600, 500, 650),
      _l('1956.00', 870, 500, 935),
      _l('D.L.No:20/111111,21/111112,', 40, 540, 300),
    ];
    const pageText = 'GST INVOICE';

    test('summary labels win over footer text sharing the row', () {
      final rows = parseReceiptBreakdown(lines, pageText: pageText);
      expect(rows.map((r) => r.label).toList(), [
        'BALBACK PRO 60ML',
        'Gross',
        'GST Tax',
        'Final amount',
      ]);
      expect(rows.last.value, '₹1956.00');
    });

    test('no footer/id/greeting text ever becomes a label', () {
      final labels = parseReceiptBreakdown(
        lines,
        pageText: pageText,
      ).map((r) => r.label.toLowerCase()).join(' ');
      expect(labels.contains('gst no'), isFalse);
      expect(labels.contains('shop'), isFalse);
      expect(labels.contains('plot'), isFalse);
      expect(labels.contains('get well'), isFalse);
      expect(labels.contains('d.l'), isFalse);
      expect(labels.contains('aakaar'), isFalse); // MRP-only row: not a line
    });

    test('a bill with only a subtotal still ends in a final amount row', () {
      final rows = parseReceiptBreakdown([
        _l('Dressing', 60, 100, 150),
        _l('500.00', 400, 100, 460),
        _l('Sub Total', 60, 140, 140),
        _l('500.00', 400, 140, 460),
      ], pageText: 'cash memo');
      expect(rows.map((r) => r.label).toList(), ['Dressing', 'Final amount']);
    });
  });

  group('parseReceiptBreakdown — fallthrough', () {
    test('a page without money rows yields nothing', () {
      final lines = [
        _l('COMPLETE BLOOD COUNT', 100, 100, 300),
        _l('Haemoglobin', 60, 160, 170),
        _l('13.0', 300, 160, 340),
        _l('g/dL', 380, 160, 420),
      ];
      expect(parseReceiptBreakdown(lines, pageText: 'CBC'), isEmpty);
    });

    test('no currency context leaves amounts unprefixed', () {
      final lines = [
        _l('Consultation', 60, 100, 180),
        _l('Total', 60, 140, 110),
        _l('20.00', 300, 100, 350),
        _l('20.00', 300, 140, 350),
      ];
      final rows = parseReceiptBreakdown(lines, pageText: 'clinic slip total');
      expect(rows.first.value, '20.00');
    });
  });

  group('word-level geometry used on the phone', () {
    test('merged OCR lines still use the product and amount columns', () {
      final lines = [
        _l('Qty Product Name MRP Comp Batch Expiry GST Amount', 40, 200, 940),
        _l(
          '1 BALBACK PRO 60ML 1440.00 AAKAAR M BCC4754 10/26 18 1440.00',
          40,
          260,
          940,
        ),
        _l('Get Well Soon NET 1956.00', 40, 500, 935),
      ];
      final geometry = OcrGeometryPage(
        lines: lines,
        elements: [
          _e('Qty', 40, 200, 70),
          _e('Product', 100, 200, 160),
          _e('Name', 165, 200, 220),
          _e('MRP', 300, 200, 340),
          _e('Comp', 400, 200, 450),
          _e('Batch', 500, 200, 550),
          _e('Expiry', 600, 200, 650),
          _e('GST', 700, 200, 735),
          _e('Amount', 870, 200, 940),
          _e('1', 46, 260, 60, parent: 1),
          _e('BALBACK', 100, 260, 165, parent: 1),
          _e('PRO', 170, 260, 200, parent: 1),
          _e('60ML', 205, 260, 250, parent: 1),
          _e('1440.00', 300, 260, 360, parent: 1),
          _e('AAKAAR', 400, 260, 455, parent: 1),
          _e('M', 460, 260, 470, parent: 1),
          _e('BCC4754', 500, 260, 570, parent: 1),
          _e('10/26', 600, 260, 650, parent: 1),
          _e('18', 700, 260, 720, parent: 1),
          _e('1440.00', 870, 260, 940, parent: 1),
          _e('Get', 40, 500, 70, parent: 2),
          _e('Well', 75, 500, 110, parent: 2),
          _e('Soon', 115, 500, 155, parent: 2),
          _e('NET', 600, 500, 640, parent: 2),
          _e('1956.00', 870, 500, 935, parent: 2),
        ],
      );

      final rows = parseReceiptBreakdown(
        lines,
        geometry: geometry,
        pageText: 'GST INVOICE',
      );

      expect(rows.map((row) => row.label).toList(), [
        'BALBACK PRO 60ML',
        'Final amount',
      ]);
      expect(rows.map((row) => row.value).toList(), ['₹1440.00', '₹1956.00']);
    });
  });

  group('isReceiptSummaryLabel', () {
    test('classifies summary vs item labels', () {
      expect(isReceiptSummaryLabel('Total'), isTrue);
      expect(isReceiptSummaryLabel('Final amount'), isTrue);
      expect(isReceiptSummaryLabel('Sub Total'), isTrue);
      expect(isReceiptSummaryLabel('GST Tax'), isTrue);
      expect(isReceiptSummaryLabel('USG Small Part'), isFalse);
      expect(isReceiptSummaryLabel('BALBACK PRO 60ML'), isFalse);
    });
  });

  group('item label hygiene', () {
    test('administrative and greeting labels are never plausible items', () {
      for (final label in [
        'GST NO:27ABDFA0179N1Z8',
        'D.L.No:20/111111',
        'SHOP O',
        'PLOT N',
        'Get Well Soon',
        'Patient Name',
      ]) {
        expect(isPlausibleReceiptItemLabel(label), isFalse, reason: label);
      }
    });

    test('genuine charges with administrative-sounding words stay items', () {
      for (final label in [
        'Registration Fee',
        'USG Small Part',
        'Dental consultation',
        'Nursing Charges',
        'BALBACK PRO 60ML',
      ]) {
        expect(isPlausibleReceiptItemLabel(label), isTrue, reason: label);
        expect(isReceiptSummaryLabel(label), isFalse, reason: label);
      }
    });
  });

  group('OCR-mangled summary labels (real OCR failures)', () {
    // Scans of one printed "Total Bill Amount" produce all of these. The clipped
    // prefixes defeat ^-anchored matching, so fuzzy per-word matching classifies
    // them as summary rows rather than purchased items.
    test('fuzzy word matching catches arbitrary OCR letter damage', () {
      for (final mangled in [
        'jual Bill Amount',
        'loal Bil Amount',
        'Bil Amount',
        'Total Amout',
        'lotal Bill Amounl',
      ]) {
        expect(isReceiptSummaryLabel(mangled), isTrue, reason: mangled);
        expect(isPlausibleReceiptItemLabel(mangled), isFalse, reason: mangled);
        expect(isFinalReceiptAmountLabel(mangled), isTrue, reason: mangled);
      }
    });

    test('two mangled totals collapse into one Final amount row', () {
      final rows = parseReceiptBreakdown([
        _l('Service Type/Service Name', 120, 100, 340),
        _l('Amount (INR)', 800, 100, 920),
        _l('USG Small Part', 90, 160, 260),
        _l('3,360.00', 820, 160, 900),
        _l('loal Bil Amount', 60, 240, 220),
        _l('3,360.00', 820, 240, 900),
        _l('Bil Amount', 60, 300, 160),
        _l('3,360.00', 820, 300, 900),
      ], pageText: 'Day Care/OP Cash Bill Amount (INR)');
      expect(rows.map((r) => r.label).toList(), [
        'USG Small Part',
        'Final amount',
      ]);
      expect(rows.last.value, '₹3,360.00');
    });
  });

  group('camera-resolution geometry', () {
    // Fixtures are ~900 px wide and camera pages ~3500 px, so every threshold
    // must scale with text height or multi-word labels split on device.
    OcrLine scale(OcrLine l, double s) =>
        OcrLine(l.text, l.left * s, l.top * s, l.right * s, l.bottom * s);

    test('pharmacy invoice parses identically at 3.7x resolution', () {
      final base = <OcrLine>[
        _l('Qty', 40, 200, 70),
        _l('Product Name', 100, 200, 220),
        _l('MRP', 300, 200, 340),
        _l('Amount', 870, 200, 940),
        _l('1', 46, 260, 60),
        _l('BALBACK PRO 60ML', 100, 260, 260),
        _l('1440.00', 300, 260, 360),
        _l('1440.00', 870, 260, 940),
        _l('NET :', 600, 500, 650),
        _l('1956.00', 870, 500, 935),
      ];
      final labels = parseReceiptBreakdown(
        [for (final l in base) scale(l, 3.7)],
        pageText: 'GST INVOICE',
      ).map((r) => r.label).toList();
      expect(labels, ['BALBACK PRO 60ML', 'Final amount']);
    });

    test('split words of one item cell regroup at camera scale', () {
      // "USG" / "Small" / "Part" as separate word boxes with realistic ~40 px
      // word gaps at 3.7x. The gap threshold scales with text height, so these
      // stay one cell instead of splitting the label.
      final rows = parseReceiptBreakdown([
        OcrLine('Service Type/Service Name', 444, 333, 1258, 407),
        OcrLine('Amount (INR)', 2960, 333, 3404, 407),
        OcrLine('USG', 333, 1443, 481, 1517),
        OcrLine('Small', 521, 1443, 706, 1517),
        OcrLine('Part', 746, 1443, 894, 1517),
        OcrLine('3,360.00', 3034, 1443, 3330, 1517),
        OcrLine('Final Payment', 222, 2220, 703, 2294),
        OcrLine('3,360.00', 3034, 2220, 3330, 2294),
      ], pageText: 'Day Care/OP Cash Bill Amount (INR)');
      expect(rows.map((r) => r.label).toList(), [
        'USG Small Part',
        'Final amount',
      ]);
      expect(rows.first.value, '₹3,360.00');
    });
  });
}
