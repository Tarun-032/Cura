// Unit tests for the geometry-based results-table reader. The key scenario is
// the hard one: a 3-column lab report whose NORMAL RANGE column
// is printed vertically staggered from the test rows.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/library/document.dart';
import 'package:cura/features/scan/table_parser.dart';

/// A Liver Function Test with a vertically staggered range column.
const _rows = [
  ['Serum Bilirubin (Total)', '0.5', '0 - 1.5 mg/dl'],
  ['Bilirubin (Direct)', '0.2', '0 - 0.5 mg/dl'],
  ['Bilirubin (Indirect)', '0.3', '0 - 0.8 mg/dl'],
  ['S.G.P.T.', '31.7', '0 - 45 IU/L'],
  ['S.G.O.T', '20.5', '0 - 45 IU/L'],
  ['S. Alkaline Phosphatase', '91.60', '< 390 IU/L'],
  ['Total Proteins', '8.5', '6.0 - 8.3 gm%'],
  ['Serum Albumin', '4.4', '3.5 - 5.5 gm%'],
  ['Globulin', '4.1', '2.3 - 3.5 gm%'],
  ['A/G Ratio', '1.07', '0.9 - 2.0'],
];

const _cbcRows = <(String, String, String, String)>[
  ('Erythrocyte (RBC) Count', '5.04', 'mill/cu.mm', '4.4-6.0'),
  ('Haemoglobin (Hb)', '13.0', 'g/dL', '14-18'),
  ('PCV (Packed Cell Volume)', '40.5', '%', '42-52'),
  ('MCV (Mean Corpuscular Volume)', '80.3', 'fL', '82-101'),
  ('MCH (Mean Corpuscular Hb)', '25.7', 'pg', '27-34'),
  ('MCHC (Mean Corpuscular Hb Concn.)', '32.0', 'g/dL', '31.5-36'),
  ('RDW (Red Cell Distribution Width)', '14.2', '%', '11.5-14.0'),
  ('Total Leucocytes (WBC) Count', '6,100', 'cells/cu.mm', '4300-10300'),
  ('Absolute Neutrophils Count', '3721', '/c.mm', '2000-7000'),
  ('Absolute Lymphocyte Count', '1342', '/c.mm', '1000-3000'),
  ('Absolute Monocyte Count', '671', '/c.mm', '200-1000'),
  ('Absolute Eosinophil Count', '366', '/c.mm', '20-500'),
  ('Absolute Basophil Count', '0', '/c.mm', '20-100'),
  ('Neutrophils', '61', '%', '40-80'),
  ('Lymphocytes', '22', '%', '20-40'),
  ('Monocytes', '11', '%', '2.0-10'),
  ('Eosinophils', '6', '%', '1-6'),
  ('Basophils', '0', '%', '0-2'),
  ('Platelet count', '180', '10^3/µL', '140-440'),
  ('MPV (Mean Platelet Volume)', '10.4', 'fL', '7.8-11'),
  ('PCT (Platelet Haematocrit)', '0.188', '%', '0.2-0.5'),
  ('PDW (Platelet Distribution Width)', '17.8', '%', '9-17'),
];

OcrLine _line(String text, double left, double cy) =>
    OcrLine(text, left, cy - 12, left + 120, cy + 12);

OcrElementBox _element(
  String text,
  double left,
  double right,
  double cy, {
  required int parent,
  List<OcrSymbolBox> symbols = const [],
}) => OcrElementBox(
  text,
  left,
  cy - 10,
  right,
  cy + 10,
  parentLine: parent,
  confidence: 0.95,
  symbols: symbols,
);

/// Header + patient/footer noise wrapped around the table. [rangeDy] shifts the
/// whole range column to simulate the printed vertical drift; [valueText] /
/// [rangeText] override a row's recognised text to simulate OCR misreads.
List<OcrLine> _page({
  double rangeDy = 0,
  int? dropRange,
  Map<int, String>? valueText,
  Map<int, String>? rangeText,
}) {
  final lines = <OcrLine>[
    _line('PATIENTS NAME MR. PETER DOE', 50, 40),
    _line('PATIENT ID 1000001', 50, 70),
    _line('LIVER FUNCTION TEST', 300, 100),
    _line('TEST DONE OBSERVED VALUE NORMAL RANGE', 50, 140),
  ];
  for (var i = 0; i < _rows.length; i++) {
    final cy = 220.0 + i * 40;
    lines.add(_line(_rows[i][0], 50, cy)); // label
    lines.add(_line(valueText?[i] ?? _rows[i][1], 400, cy)); // value
    if (i != dropRange) {
      lines.add(
        _line(rangeText?[i] ?? _rows[i][2], 650, cy + rangeDy),
      ); // range
    }
  }
  lines.add(
    _line('Done on FUJI dry chemistry / A25 BioSystem analyser.', 50, 680),
  );
  return lines;
}

DocumentResult _byLabel(List<DocumentResult> rs, String needle) =>
    rs.firstWhere((r) => r.label.toLowerCase().contains(needle.toLowerCase()));

void main() {
  test('element geometry splits a merged ML Kit row into table columns', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE NORMAL RANGE', 40, 100),
      OcrLine('Haemoglobin 14.1 13-17 gm%', 40, 140, 850, 164),
      OcrLine('Basophils O % 0-1', 40, 180, 850, 204),
    ];
    final geometry = OcrGeometryPage(
      lines: lines,
      elements: [
        _element('Haemoglobin', 40, 180, 152, parent: 1),
        _element('14.1', 420, 465, 152, parent: 1),
        _element('13-17', 700, 765, 152, parent: 1),
        _element('gm%', 775, 820, 152, parent: 1),
        _element('Basophils', 40, 150, 192, parent: 2),
        _element(
          '0',
          420,
          440,
          192,
          parent: 2,
          symbols: const [OcrSymbolBox('O', 420, 182, 440, 202)],
        ),
        _element('%', 560, 580, 192, parent: 2),
        _element('0-1', 700, 745, 192, parent: 2),
      ],
    );

    final parsed = parseResultsTableDetailed(lines, geometry: geometry);
    expect(parsed.results, hasLength(2));
    expect(_byLabel(parsed.results, 'haemoglobin').value, '14.1');
    expect(_byLabel(parsed.results, 'haemoglobin').range, '13-17');
    expect(_byLabel(parsed.results, 'basophils').value, '0');
    expect(_byLabel(parsed.results, 'basophils').unit, '%');
    expect(
      parsed.evidence.cells.every(
        (cell) => cell.granularity == TableCellGranularity.element,
      ),
      isTrue,
    );
    expect(
      parsed.evidence.cells.every((cell) => cell.confidence == 0.95),
      isTrue,
    );
  });

  test('line parser remains authoritative when element coverage is worse', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE NORMAL RANGE', 40, 100),
      _line('Haemoglobin', 40, 150),
      _line('14.1', 420, 150),
      _line('13-17 gm%', 700, 150),
    ];
    final geometry = OcrGeometryPage(
      lines: lines,
      elements: [_element('Haemoglobin', 40, 180, 150, parent: 1)],
    );

    final parsed = parseResultsTableDetailed(lines, geometry: geometry);
    expect(parsed.results, hasLength(1));
    expect(parsed.results.single.value, '14.1');
    expect(
      parsed.evidence.cells.every(
        (cell) => cell.granularity == TableCellGranularity.line,
      ),
      isTrue,
    );
  });

  test('a line/element value conflict never silently replaces the value', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE NORMAL RANGE', 40, 100),
      _line('Haemoglobin', 40, 150),
      _line('14.1', 420, 150),
      _line('13-17 gm%', 700, 150),
    ];
    final geometry = OcrGeometryPage(
      lines: lines,
      elements: [
        _element('Haemoglobin', 40, 180, 150, parent: 1),
        _element('14.7', 420, 465, 150, parent: 2),
        _element('13-17', 700, 765, 150, parent: 3),
        _element('gm%', 775, 820, 150, parent: 3),
      ],
    );

    final parsed = parseResultsTableDetailed(lines, geometry: geometry);
    expect(parsed.results.single.value, '14.1');
    expect(
      parsed.evidence.cells.every(
        (cell) => cell.granularity == TableCellGranularity.line,
      ),
      isTrue,
    );
  });

  test('pairs every row correctly despite a staggered range column', () {
    // Range column drifts up 25px — nearest-y would mis-shift, index pairing
    // (equal counts) must not.
    final results = parseResultsTable(_page(rangeDy: -25));

    expect(results.length, 10);

    final alk = _byLabel(results, 'alkaline');
    expect(alk.value, '91.60');
    expect(alk.range, '< 390');
    expect(alk.unit, 'IU/L');

    final tp = _byLabel(results, 'total proteins');
    expect(tp.value, '8.5'); // not "85"
    expect(tp.range, '6.0 - 8.3');
    expect(tp.unit, 'gm%');

    final sgpt = _byLabel(results, 's.g.p.t');
    expect(sgpt.value, '31.7');
    expect(sgpt.range, '0 - 45');
    expect(sgpt.unit, 'IU/L');

    final alb = _byLabel(results, 'albumin');
    expect(alb.value, '4.4');
    expect(alb.range, '3.5 - 5.5');
    expect(alb.unit, 'gm%');
  });

  test('excludes patient block, header and footer noise', () {
    final results = parseResultsTable(_page());
    expect(
      results.any((r) => r.label.toLowerCase().contains('patient')),
      isFalse,
    );
    expect(results.any((r) => r.value.contains('2429706')), isFalse);
    expect(
      results.any((r) => r.label.toLowerCase().contains('biosystem')),
      isFalse,
    );
  });

  test('handles OCR that merges a whole row onto one line', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE NORMAL RANGE', 50, 162),
    ];
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      lines.add(_line('${r[0]}   ${r[1]}   ${r[2]}', 50, 200.0 + i * 40));
    }
    final parsed = parseResultsTableDetailed(lines);
    final results = parsed.results;
    expect(results.length, 10);
    final alk = _byLabel(results, 'alkaline');
    expect(alk.value, '91.60');
    expect(alk.range, '< 390');
    expect(alk.unit, 'IU/L');
    final tp = _byLabel(results, 'total proteins');
    expect(tp.value, '8.5');
  });

  test('repairs OCR digit-as-letter slips in the range column', () {
    // Row 2 (Bilirubin Indirect) range "0 - 0.8 mg/dl" misread as "Q - Q.8…".
    final results = parseResultsTable(_page(rangeText: {2: 'Q - Q.8 mg/dl'}));
    expect(results.length, 10);
    // No junk row created from the mangled range.
    expect(
      results.any((r) => r.label.contains('Q-0.8') || r.label.contains('Q.8')),
      isFalse,
    );
    final ind = _byLabel(results, 'indirect');
    expect(ind.value, '0.3');
    expect(ind.range, '0 - 0.8'); // Q → 0 repaired
    expect(ind.unit, 'mg/dl');
  });

  test('snaps OCR-mangled units back to canonical spelling', () {
    final results = parseResultsTable(
      _page(
        rangeText: {
          0: '0 - 1.5 mgld!', // mg/dl
          3: '0 - 45 IUIL', // IU/L
          5: '< 390 IUIL', // IU/L
        },
      ),
    );
    expect(_byLabel(results, 'bilirubin (total)').range, '0 - 1.5');
    expect(_byLabel(results, 'bilirubin (total)').unit, 'mg/dl');
    expect(_byLabel(results, 's.g.p.t').range, '0 - 45');
    expect(_byLabel(results, 's.g.p.t').unit, 'IU/L');
    expect(_byLabel(results, 'alkaline').range, '< 390');
    expect(_byLabel(results, 'alkaline').unit, 'IU/L');
    // A clean unit is left exactly as-is.
    expect(_byLabel(results, 'globulin').range, '2.3 - 3.5');
    expect(_byLabel(results, 'globulin').unit, 'gm%');
  });

  test('falls back to the test standard unit when OCR garbles it', () {
    // "IU/L" comes out three different broken ways; proteins (gm%) read cleanly.
    final results = parseResultsTable(
      _page(
        rangeText: {
          3: '0 - 45 1UL', // SGPT
          4: '0 - 45 /µL', // SGOT
          5: '< 390 U/L', // Alkaline Phosphatase
        },
      ),
    );
    expect(_byLabel(results, 's.g.p.t').range, '0 - 45');
    expect(_byLabel(results, 's.g.p.t').unit, 'IU/L');
    expect(_byLabel(results, 's.g.o.t').range, '0 - 45');
    expect(_byLabel(results, 's.g.o.t').unit, 'IU/L');
    expect(_byLabel(results, 'alkaline').range, '< 390');
    expect(_byLabel(results, 'alkaline').unit, 'IU/L');
    // Proteins are not in the standard-unit map → keep the clean gm%.
    expect(_byLabel(results, 'total proteins').range, '6.0 - 8.3');
    expect(_byLabel(results, 'total proteins').unit, 'gm%');
  });

  test('repairs a mangled value and never alters a label', () {
    final results = parseResultsTable(_page(valueText: {0: 'O.5'}));
    expect(_byLabel(results, 'bilirubin (total)').value, '0.5'); // O → 0
    // "S.G.O.T" has a confusable letter but is a label — must be untouched.
    expect(results.any((r) => r.label == 'S.G.O.T'), isTrue);
  });

  test('CBC: excludes section headings, keeps zero values', () {
    final lines = <OcrLine>[
      _line('TEST DONE   OBSERVED VALUE   NORMAL RANGE', 50, 100),
      _line('Haemoglobin', 50, 140),
      _line('12.7', 400, 140),
      _line('13 - 17 gm%', 650, 140),
      _line('DIFFERENTIAL COUNT', 50, 200), // heading — no value on its line
      _line('Neutrophils', 50, 240),
      _line('69', 400, 240),
      _line('40 - 75 %', 650, 240),
      _line('Basophils', 50, 280),
      _line('00', 400, 280),
      _line('0 - 1 %', 650, 280),
      _line('ABSOLUTE DIFFERENTIAL COUNTS', 50, 340), // heading
      _line('Neutrophils', 50, 380),
      _line('5057.7', 400, 380),
      _line('1500 - 7000 per cu.mm', 650, 380),
      _line('Basophils', 50, 420),
      _line('0', 400, 420),
      _line('0 - 100 per cu.mm', 650, 420),
      _line('BLOOD INDICES', 50, 480), // heading
      _line('P.C.V', 50, 520),
      _line('38.8', 400, 520),
      _line('37 - 47 %', 650, 520),
    ];
    final parsed = parseResultsTableDetailed(lines);
    final results = parsed.results;

    for (final heading in [
      'DIFFERENTIAL COUNT',
      'ABSOLUTE DIFFERENTIAL COUNTS',
      'BLOOD INDICES',
    ]) {
      expect(
        results.any((r) => r.label == heading),
        isFalse,
        reason: '$heading should not be a row',
      );
    }
    // Both zero basophil values are kept.
    final baso = results
        .where((r) => r.label.toLowerCase() == 'basophils')
        .toList();
    expect(baso.map((r) => r.value), ['00', '0']);
    expect(_byLabel(results, 'haemoglobin').value, '12.7');
    expect(_byLabel(results, 'p.c.v').value, '38.8');
  });

  test('recovers a lone 0 value OCR merged onto its reference range', () {
    // A zero basophil value ("0") OCR'd glued to the adjacent range ("0 0-2")
    // classifies as a range. The leading value must be split back out.
    final lines = <OcrLine>[
      _line('Neutrophils', 50, 100),
      _line('61', 400, 100),
      _line('40-80 %', 650, 100),
      _line('Eosinophils', 50, 140),
      _line('6', 400, 140),
      _line('1-6 %', 650, 140),
      _line('Basophils', 50, 180),
      _line('0 0-2 %', 400, 180), // value glued to range
      _line('Absolute Basophil Count', 50, 220),
      _line('0 20-100', 400, 220), // value glued to range
    ];
    final results = parseResultsTableDetailed(lines).results;
    expect(_byLabel(results, 'basophils').value, '0');
    expect(_byLabel(results, 'basophils').range, '0-2');
    expect(_byLabel(results, 'absolute basophil count').value, '0');
  });

  test('a spaced range is never mistaken for a value merged onto a range', () {
    // "0 - 2" is one reference range, not a value 0 with a range. It must stay
    // a range and, without an observed value, leave that row incomplete rather
    // than inventing value "0".
    final lines = <OcrLine>[
      _line('Neutrophils', 50, 100),
      _line('61', 400, 100),
      _line('40 - 80 %', 650, 100),
      _line('Basophils', 50, 140),
      _line('0 - 2 %', 650, 140), // range only, no observed value
    ];
    final results = parseResultsTableDetailed(lines).results;
    final baso = results.where((r) => r.label == 'Basophils').toList();
    // Either dropped or incomplete — but never a fabricated value "0".
    if (baso.isNotEmpty) {
      expect(baso.single.value, isNot('0'));
    }
  });

  test('long CBC keeps all 22 rows, zero values, ranges and separate units', () {
    final lines = <OcrLine>[
      _line(
        'INVESTIGATION OBSERVED VALUE UNIT BIOLOGICAL REFERENCE INTERVAL',
        50,
        100,
      ),
    ];
    var cy = 150.0;
    for (var i = 0; i < _cbcRows.length; i++) {
      if (i == 0) lines.add(_line('Erythrocytes', 50, cy - 26));
      if (i == 7) lines.add(_line('Leucocytes', 50, cy - 26));
      if (i == 18) lines.add(_line('Platelets', 50, cy - 26));
      final row = _cbcRows[i];
      lines.add(_line(row.$1, 50, cy));
      // The two underlined zero readings are vertically offset in the real scan.
      final valueCy = (i == 12 || i == 17) ? cy + 14 : cy;
      lines.add(_line(row.$2, 420, valueCy));
      lines.add(_line(row.$3, 610, cy + 3));
      lines.add(_line(row.$4, 780, cy - 4));
      cy += 40;
    }
    lines.add(_line('-- End of Report --', 50, cy + 20));

    final parsed = parseResultsTableDetailed(lines);
    expect(
      parsed.results.length,
      22,
      reason: parsed.results.map((r) => '${r.label}=${r.value}').join(' | '),
    );
    expect(parsed.stats.incomplete, 0);
    expect(_byLabel(parsed.results, 'absolute basophil').value, '0');
    expect(_byLabel(parsed.results, 'absolute basophil').unit, '/c.mm');
    expect(_byLabel(parsed.results, 'basophils').value, '0');
    expect(_byLabel(parsed.results, 'platelet count').unit, '10^3/µL');
    expect(_byLabel(parsed.results, 'haemoglobin').range, '14-18');
  });

  test(
    'unreadable value creates one incomplete row without shifting neighbors',
    () {
      final lines = <OcrLine>[_line('OBSERVED VALUE NORMAL RANGE', 50, 100)];
      for (var i = 0; i < 3; i++) {
        final cy = 150.0 + i * 42;
        lines.add(_line(['Neutrophils', 'Basophils', 'Platelets'][i], 50, cy));
        if (i != 1) lines.add(_line(['61', '', '180'][i], 420, cy));
        lines.add(_line(['40-80', '0-2', '140-440'][i], 780, cy));
        lines.add(_line(['%', '%', '10^3/µL'][i], 610, cy));
      }

      final parsed = parseResultsTableDetailed(lines);
      final results = parsed.results;
      expect(results.length, 3);
      expect(_byLabel(results, 'neutrophils').value, '61');
      expect(_byLabel(results, 'basophils').needsReview, isTrue);
      expect(_byLabel(results, 'basophils').range, '0-2');
      expect(_byLabel(results, 'platelets').value, '180');
      expect(parsed.evidence.needsRepair, isTrue);
      expect(parsed.evidence.unresolvedCount, 1);
      expect(parsed.evidence.tableText, contains('Basophils'));
    },
  );

  test(
    'HbA1c stops before interpretation and keeps only the two real rows',
    () {
      final lines = <OcrLine>[
        _line(
          'INVESTIGATION OBSERVED VALUE UNIT BIOLOGICAL REFERENCE INTERVAL',
          50,
          100,
        ),
        _line('HbA1c- Glycated Haemoglobin', 50, 150),
        _line('(High-Performance Liquid Chromatography (HPLC))', 50, 176),
        _line('5.1', 430, 150),
        _line('%', 610, 150),
        _line('Non-diabetic: <= 5.6', 760, 150),
        _line('Pre-diabetic: 5.7-6.4', 760, 176),
        _line('Diabetic: >= 6.5', 760, 202),
        _line('Estimated Average Glucose (eAG)', 50, 240),
        _line('99.67', 430, 240),
        _line('mg/dL', 610, 240),
        _line('Interpretation & Remark:', 50, 290),
        _line('1. HbA1c is used for monitoring diabetic control.', 50, 330),
        _line('eAG(mg/dl) = 28.7*A1c-46.7', 50, 370),
        _line('Note: Hemoglobin electrophoresis is recommended.', 50, 410),
      ];

      final parsed = parseResultsTableDetailed(lines);
      expect(
        parsed.results,
        hasLength(2),
        reason: parsed.results
            .map((row) => '${row.label}=${row.value} ${row.unit ?? ''}')
            .join(' | '),
      );
      final hba1c = _byLabel(parsed.results, 'hba1c');
      expect(hba1c.value, '5.1');
      expect(hba1c.unit, '%');
      expect(hba1c.range, isNull);
      final eag = _byLabel(parsed.results, 'average glucose');
      expect(eag.value, '99.67');
      expect(eag.unit?.toLowerCase(), 'mg/dl');
      expect(eag.range, isNull);
      expect(
        parsed.results.any((row) => row.label.contains('Interpretation')),
        isFalse,
      );
      expect(
        parsed.results.any((row) => row.label.startsWith('Note')),
        isFalse,
      );
    },
  );

  test('serology rows survive interpretation prose between result blocks', () {
    final lines = <OcrLine>[
      _line(
        'INVESTIGATION OBSERVED VALUE UNIT BIOLOGICAL REFERENCE INTERVAL',
        50,
        100,
      ),
      _line('Rubella Virus - IgG antibody', 50, 150),
      _line('Reactive,45.90', 430, 150),
      _line('IU/mL', 610, 150),
      _line('Non-reactive: < 10', 760, 150),
      _line('Reactive: >= 10.0', 760, 176),
      _line('Interpretation:', 50, 205),
      _line(
        'A positive result indicates prior exposure or vaccination.',
        50,
        235,
      ),
      _line('Reference:', 50, 285),
      _line('Journal of Diagnostics, May 13, 2016.', 50, 315),
      _line('Measles (Rubeola) Virus - IgG antibody, Serum', 50, 370),
      _line('Posltive,161.00', 430, 370),
      _line('AU/mL', 610, 370),
      _line('Negative: < 13.5', 760, 370),
      _line('Borderline: 13.5-16.49', 760, 396),
      _line('Positive: >= 16.5', 760, 422),
      _line('Clinical Utility:', 50, 455),
      _line('Narrative medical explanation.', 50, 485),
      _line('Mumps virus IgG antibody, Serum', 50, 540),
      _line('Positive,96.30', 430, 540),
      _line('AU/mL', 610, 540),
      _line('Negative: < 9.0', 760, 540),
      _line('Equivocal: 9.0-11.0', 760, 566),
      _line('Positive: >= 11.0', 760, 592),
      _line('MEDICAL LABORATORY REPORT', 300, 650),
    ];

    final parsed = parseResultsTableDetailed(lines);
    expect(
      parsed.results,
      hasLength(3),
      reason: parsed.results
          .map((row) => '${row.label}=${row.value}')
          .join(' | '),
    );
    final rubella = _byLabel(parsed.results, 'rubella');
    expect(rubella.value, 'Reactive, 45.90');
    expect(rubella.unit, 'IU/mL');
    expect(rubella.range, 'Non-reactive: < 10; Reactive: >= 10.0');
    final measles = _byLabel(parsed.results, 'measles');
    expect(measles.value, 'Positive, 161.00');
    expect(measles.unit, 'AU/mL');
    expect(measles.range, contains('Borderline: 13.5-16.49'));
    final mumps = _byLabel(parsed.results, 'mumps');
    expect(mumps.value, 'Positive, 96.30');
    expect(mumps.range, contains('Equivocal: 9.0-11.0'));
    expect(
      parsed.results.any((row) => row.label.contains('Interpretation')),
      isFalse,
    );
  });

  test(
    'table repair accepts only a value from the matching bounded OCR row',
    () {
      const evidence = TableRepairEvidence([
        TableEvidenceRow(
          label: 'HbA1c- Glycated Haemoglobin',
          rowText: 'HbA1c- Glycated Haemoglobin | 5.1 | %',
          order: 0,
          incomplete: true,
        ),
        TableEvidenceRow(
          label: 'Estimated Average Glucose (eAG)',
          rowText: 'Estimated Average Glucose (eAG) | 99.67 | mg/dL',
          order: 1,
          incomplete: true,
        ),
      ]);

      final verified = verifyTableRepairProposals(const [
        DocumentResult('HbA1c', '5.1', unit: '%'),
        // Both fields exist on the page, but not together on this row.
        DocumentResult('Estimated Average Glucose', '5.1', unit: '%'),
      ], evidence);
      expect(verified, hasLength(1));
      expect(verified.single.label, 'HbA1c- Glycated Haemoglobin');
      expect(verified.single.value, '5.1');
    },
  );

  test(
    'table repair rejects invented values, units, ranges, and duplicate rows',
    () {
      const evidence = TableRepairEvidence([
        TableEvidenceRow(
          label: 'HbA1c- Glycated Haemoglobin',
          rowText: 'HbA1c- Glycated Haemoglobin | 5.1 | %',
          order: 0,
          incomplete: true,
        ),
      ]);
      final verified = verifyTableRepairProposals(const [
        DocumentResult('HbA1c', '6.1', unit: '%'),
        DocumentResult('HbA1c', '5.1', unit: 'mg/dL'),
        DocumentResult('HbA1c', '5.1', unit: '%', range: '4-6'),
        DocumentResult('HbA1c', '5.1', unit: '%'),
        DocumentResult('HbA1c', '5.1', unit: '%'),
      ], evidence);
      expect(verified, hasLength(1));
      expect(verified.single.value, '5.1');
    },
  );

  test('split range fragments never become a DIFFERENTIAL COUNT result', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE NORMAL RANGE', 50, 100),
      _line('Haemoglobin', 50, 150),
      _line('14.1', 420, 150),
      _line('13-17 gm%', 720, 150),
      _line('R.B.C. Count', 50, 190),
      _line('5.34', 420, 190),
      _line('4.2-6.5 x10^6/ul', 720, 190),
      _line('Total W.B.C. Count', 50, 230),
      _line('5760', 420, 230),
      _line('4000-10000 /cmm', 720, 230),
      _line('DIFFERENTIAL COUNT', 50, 270),
      _line('40', 720, 270),
      _line('-75', 770, 270),
      _line('Neutrophils', 50, 310),
      _line('66', 420, 310),
      _line('40-75 %', 720, 310),
      _line('Eosinophils', 50, 350),
      _line('03', 420, 350),
      _line('1-6 %', 720, 350),
      _line('Basophils', 50, 390),
      _line('00', 420, 390),
      _line('0-1 %', 720, 390),
    ];

    final parsed = parseResultsTableDetailed(lines);
    expect(
      parsed.results.any((row) => row.label == 'DIFFERENTIAL COUNT'),
      isFalse,
    );
    expect(_byLabel(parsed.results, 'neutrophils').value, '66');
    expect(_byLabel(parsed.results, 'eosinophils').value, '03');
    final splitForty = parsed.evidence.cells.singleWhere(
      (cell) => cell.text == '40',
    );
    expect(splitForty.column, TableCellColumn.range);
  });

  test('cell-id reconciliation rejects a range cell used as a value', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE NORMAL RANGE', 50, 100),
      _line('Haemoglobin', 50, 150),
      _line('14.1', 420, 150),
      _line('13-17 gm%', 720, 150),
      _line('DIFFERENTIAL COUNT', 50, 190),
      _line('40', 720, 190),
      _line('-75', 770, 190),
      _line('Neutrophils', 50, 230),
      _line('66', 420, 230),
      _line('40-75 %', 720, 230),
      _line('Eosinophils', 50, 270),
      _line('03', 420, 270),
      _line('1-6 %', 720, 270),
      _line('Basophils', 50, 310),
      _line('00', 420, 310),
      _line('0-1 %', 720, 310),
    ];
    final evidence = parseResultsTableDetailed(lines).evidence.withPass(1);
    TableGridCell cell(String text, TableCellColumn column) => evidence.cells
        .firstWhere((cell) => cell.text == text && cell.column == column);

    final hbLabel = cell('Haemoglobin', TableCellColumn.label);
    final hbValue = cell('14.1', TableCellColumn.value);
    final neutLabel = cell('Neutrophils', TableCellColumn.label);
    final neutValue = cell('66', TableCellColumn.value);
    final eosLabel = cell('Eosinophils', TableCellColumn.label);
    final eosValue = cell('03', TableCellColumn.value);
    final basoLabel = cell('Basophils', TableCellColumn.label);
    final basoValue = cell('00', TableCellColumn.value);
    final heading = cell('DIFFERENTIAL COUNT', TableCellColumn.label);
    final rangeForty = cell('40', TableCellColumn.range);

    final raw =
        '''{"tableRows":[
      {"labelCell":"${hbLabel.id}","valueCell":"${hbValue.id}"},
      {"labelCell":"${heading.id}","valueCell":"${rangeForty.id}"},
      {"labelCell":"${neutLabel.id}","valueCell":"${neutValue.id}"},
      {"labelCell":"${eosLabel.id}","valueCell":"${eosValue.id}"},
      {"labelCell":"${basoLabel.id}","valueCell":"${basoValue.id}"}
    ]}''';
    final reconciled = parseTableCellReconciliation(raw, evidence);
    expect(reconciled.map((row) => row.label), [
      'Haemoglobin',
      'Neutrophils',
      'Eosinophils',
      'Basophils',
    ]);
    expect(reconciled.map((row) => row.value), ['14.1', '66', '03', '00']);
  });

  test('cell reconciliation accepts an OCR O in the observed-value band', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE UNIT NORMAL RANGE', 50, 100),
      _line('Absolute Basophil Count', 50, 150),
      _line('O', 420, 150),
      _line('/c.mm', 610, 150),
      _line('20-100', 780, 150),
    ];
    final evidence = parseResultsTableDetailed(lines).evidence.withPass(1);
    TableGridCell cell(
      String text,
      TableCellColumn column,
    ) => evidence.cells.firstWhere(
      (item) => item.text == text && item.column == column,
      orElse: () => throw StateError(
        '$text/$column absent: ${evidence.cells.map((item) => '${item.text}:${item.column.name}').join(', ')}',
      ),
    );
    final label = cell('Absolute Basophil Count', TableCellColumn.label);
    final value = cell('O', TableCellColumn.value);
    final unit = cell('/c.mm', TableCellColumn.unit);
    final range = cell('20-100', TableCellColumn.range);
    final raw =
        '''{"tableRows":[{"labelCell":"${label.id}","valueCell":"${value.id}","unitCell":"${unit.id}","rangeCells":["${range.id}"]}]}''';

    final reconciled = parseTableCellReconciliation(raw, evidence);
    expect(reconciled, hasLength(1));
    expect(reconciled.single.value, '0');
    expect(reconciled.single.unit, '/c.mm');
    expect(reconciled.single.range, '20-100');
  });

  test('local geometry repairs an OCR O without an LLM or retry', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE UNIT NORMAL RANGE', 50, 100),
      _line('Haemoglobin', 50, 150),
      _line('13.0', 420, 150),
      _line('g/dL', 610, 150),
      _line('14-18', 780, 150),
      _line('Absolute Basophil Count', 50, 190),
      _line('O', 420, 190),
      _line('/c.mm', 610, 190),
      _line('20-100', 780, 190),
    ];
    final parsed = parseResultsTableDetailed(lines);
    final incomplete = [
      const DocumentResult(
        'Absolute Basophil Count',
        '',
        unit: '/c.mm',
        range: '20-100',
      ),
    ];

    final repaired = repairIncompleteResultsFromGeometry(
      incomplete,
      parsed.evidence.withPass(1),
    );
    expect(repaired.single.value, '0');
    expect(repaired.single.unit, '/c.mm');
    expect(repaired.single.range, '20-100');
    expect(repaired.single.needsReview, isFalse);
  });

  test('targeted observed-value crop accepts zero but never invents it', () {
    expect(normalizeObservedValueCandidate('0'), '0');
    expect(normalizeObservedValueCandidate('00'), '00');
    expect(normalizeObservedValueCandidate('O'), '0');
    expect(normalizeObservedValueCandidate('_0_'), '0');
    expect(normalizeObservedValueCandidate('-'), isNull);
    expect(normalizeObservedValueCandidate('_'), isNull);
    expect(normalizeObservedValueCandidate('0 20-100'), isNull);
    expect(normalizeObservedValueCandidate('Basophils'), isNull);
  });

  test('recovers a value merged onto the end of a CBC label', () {
    final lines = <OcrLine>[
      _line('TEST DONE OBSERVED VALUE UNIT NORMAL RANGE', 50, 100),
      _line('Haemoglobin (Hb)', 50, 150),
      _line('13.0', 420, 150),
      _line('g/dL', 610, 150),
      _line('14-18', 780, 150),
      _line('MCHC (Mean Corpuscular Hb Concn.) 32.0', 50, 190),
      _line('g/dL', 610, 190),
      _line('31.5-36', 780, 190),
    ];

    final results = parseResultsTable(lines);
    final mchc = _byLabel(results, 'mchc');
    expect(mchc.label, 'MCHC (Mean Corpuscular Hb Concn.)');
    expect(mchc.value, '32.0');
    expect(mchc.unit, 'g/dl');
    expect(mchc.range, '31.5-36');
    expect(mchc.needsReview, isFalse);
  });

  test('a privacy-removed cell ID cannot be guessed back into a result', () {
    const evidence = TableRepairEvidence(
      [],
      cells: [
        TableGridCell(
          id: 'label_safe',
          text: 'Haemoglobin',
          column: TableCellColumn.label,
          rowHint: 0,
        ),
        TableGridCell(
          id: 'value_removed',
          text: '14.1',
          column: TableCellColumn.value,
          rowHint: 0,
        ),
      ],
    );
    final filtered = evidence.cellsPresentIn('label[label_safe]=Haemoglobin');
    const guessed =
        '{"tableRows":[{"labelCell":"label_safe","valueCell":"value_removed"}]}';

    expect(parseTableCellReconciliation(guessed, filtered), isEmpty);
  });

  test(
    'Meadowlark: 4-column layout merges the units column, drops method lines',
    () {
      final lines = <OcrLine>[
        _line(
          'TEST NAME   RESULT   BIOLOGICAL REFERENCE INTERVALS   UNITS',
          50,
          100,
        ),
        _line(
          'GLUCOSE - SERUM / PLASMA (RANDOM)',
          50,
          140,
        ), // panel header, no value
        _line('GLUCOSE - SERUM / PLASMA (RANDOM)', 50, 180),
        _line('86', 500, 180),
        _line('<140', 800, 180),
        _line('mg/dl', 1100, 180),
        _line('Method: Hexokinase', 50, 220), // no value
        _line('CREATININE - SERUM / PLASMA', 50, 260),
        _line('0.86 *', 500, 260),
        _line('Male: 0.9 - 1.3', 800, 260),
        _line('mg/dL', 1100, 260),
        _line('IDMS Standardized', 50, 300), // no value
      ];
      final results = parseResultsTable(lines);

      expect(results.any((r) => r.label.contains('Method')), isFalse);
      expect(results.any((r) => r.label.contains('IDMS')), isFalse);
      final glucose = _byLabel(results, 'glucose');
      expect(glucose.value, '86');
      expect(glucose.range, '<140');
      expect(glucose.unit, 'mg/dl');
      final creat = _byLabel(results, 'creatinine');
      expect(creat.value, '0.86'); // abnormal-flag stripped
      expect(creat.range, contains('0.9 - 1.3'));
      expect(creat.unit, 'mg/dl');
    },
  );

  test('single-test report yields one row', () {
    final lines = <OcrLine>[
      _line('TEST DONE   OBSERVED VALUE   NORMAL RANGE', 50, 100),
      _line('S. Creatinine', 50, 150),
      _line('0.7', 400, 150),
      _line('0.5 - 1.5 mg/dl', 650, 150),
    ];
    final results = parseResultsTable(lines);
    expect(results.length, 1);
    expect(results.first.label.toLowerCase(), contains('creatinine'));
    expect(results.first.value, '0.7');
  });

  test('narrative report (no value column) yields no rows', () {
    final lines = <OcrLine>[
      _line('TEST NAME   RESULT', 50, 100),
      _line('XPERT MTB/RIF ULTRA', 50, 150),
      _line('MTB COMPLEX', 50, 190),
      _line('Not Detected', 500, 190),
    ];
    expect(parseResultsTable(lines), isEmpty);
  });

  test('a missing range leaves that row blank, never shifts others', () {
    // Aligned ranges (no drift) with Alkaline's range missing.
    final results = parseResultsTable(_page(dropRange: 5));
    expect(results.length, 10);
    final alk = _byLabel(results, 'alkaline');
    expect(alk.value, '91.60');
    expect(alk.range, isNull);
    // Neighbour kept its own range.
    final tp = _byLabel(results, 'total proteins');
    expect(tp.range, '6.0 - 8.3');
    expect(tp.unit, 'gm%');
  });
}
