// Tests for the pure JSON-parse + validation layer of LLM scan refinement.
// This is the anti-hallucination guard: numbers the model invents must be
// dropped, so these run without any model.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/library/document.dart';
import 'package:cura/features/scan/scan_extraction.dart';
import 'package:cura/features/scan/scan_service.dart';

void main() {
  final svc = ScanService();
  DateTime? parseDate(String s) => svc.extractDate(s);

  test('LLM fallback keeps serology rows and drops bibliography noise', () {
    const text = '''
GREENFIELD
Name: Example Person
INVESTIGATION OBSERVED VALUE UNIT BIOLOGICAL REFERENCE INTERVAL
Rubella Virus - IgG antibody
Reactive,45.90 IU/mL
Non-reactive: < 10
Reactive: >= 10.0
Interpretation:
A long explanation about prior exposure and vaccination.
Reference:
Journal of Diagnostics, May 13, 2016.
Measles (Rubeola) Virus - IgG antibody, Serum
Posltive,161.00 AU/mL
Negative: < 13.5
Borderline: 13.5-16.49
Positive: >= 16.5
Clinical Utility:
More explanatory prose that is not a result row.
Mumps virus IgG antibody, Serum
Positive,96.30 AU/mL
Negative: < 9.0
Equivocal: 9.0-11.0
Positive: >= 11.0
MEDICAL LABORATORY REPORT
Reprinted On: 01/07/2025 4:44 PM
''';

    final selected = selectScanOcrForExtraction(
      text,
      type: DocumentType.lab,
      maxChars: 1200,
    );
    expect(selected, contains('Rubella Virus - IgG antibody'));
    expect(selected, contains('Reactive,45.90'));
    expect(selected, contains('Measles (Rubeola) Virus'));
    expect(selected, contains('Posltive,161.00'));
    expect(selected, contains('Mumps virus IgG antibody'));
    expect(selected, contains('Positive,96.30'));
    expect(selected, contains('Reprinted On: 01/07/2025'));
    expect(selected, isNot(contains('Journal of Diagnostics')));
  });

  const ocr =
      'DEPARTMENT OF NUCLEAR MEDICINE\n'
      'Contrast Enhanced 18F-FDG Whole Body PET-CT Scan\n'
      'Reported On : 30-Aug-2024 14:37:37\n'
      'The fasting blood sugar level at the time of injection was 89 mg/dl.\n'
      'MTB COMPLEX  Not Detected\n';

  group('parseScanExtraction', () {
    const prescriptionOcr = '''
Old Follow up
Diagnosis: SEBORRHEIC DERMATITIS, TELOGEN EFFLUVIUM
Rx
BALBACK PRO SERUM (6)
1 ml. locally on scalp, twice daily. Do not apply hair oil.
CERATINA CAP (50+20)
1 Tablet on ALTERNATE DAYS.
Called after: 6 weeks
''';

    test('keeps a grounded prescription summary and medicine list', () {
      const raw = '''
{"title":"Old Follow up","type":"prescription",
 "results":[
  {"label":"BALBACK PRO SERUM","value":"1 ml. locally on scalp, twice daily.","unit":null,"range":null},
  {"label":"CERATINA CAP","value":"1 Tablet on ALTERNATE DAYS.","unit":null,"range":null}],
 "note":"Follow-up prescription for seborrheic dermatitis with review after 6 weeks."}
''';
      final ext = parseScanExtraction(raw, prescriptionOcr)!;
      expect(ext.type, DocumentType.prescription);
      expect(ext.note, contains('6 weeks'));
      expect(ext.results.map((result) => result.label), [
        'BALBACK PRO SERUM',
        'CERATINA CAP',
      ]);
      expect(ext.results.every((result) => result.unit == null), isTrue);
      expect(ext.results.every((result) => result.range == null), isTrue);
    });

    test('drops prescription rows that are not exact OCR-grounded phrases', () {
      const raw = '''
{"type":"prescription",
 "results":[
  {"label":"Minoxidil","value":"1 ml. locally on scalp, twice daily."},
  {"label":"BALBACK PRO SERUM","value":"Apply once daily"},
  {"label":"CERATINA CAP","value":"1 Tablet on ALTERNATE DAYS."}],
 "note":"Prescription for seborrheic dermatitis."}
''';
      final ext = parseScanExtraction(raw, prescriptionOcr)!;
      expect(ext.results, hasLength(1));
      expect(ext.results.single.label, 'CERATINA CAP');
    });

    test('drops a prescription summary containing an invented number', () {
      const raw = '''
{"type":"prescription",
 "results":[{"label":"CERATINA CAP","value":"1 Tablet on ALTERNATE DAYS."}],
 "note":"Follow up after 8 weeks."}
''';
      final ext = parseScanExtraction(raw, prescriptionOcr)!;
      expect(ext.results, hasLength(1));
      expect(ext.note, isNull);
    });

    test('keeps a prescription summary when no medicine is clear', () {
      const ocr = 'Diagnosis: Seborrheic dermatitis\nOld Follow up';
      const raw = '''
{"title":"Old Follow up","type":"prescription","results":[],
 "note":"Follow-up prescription for seborrheic dermatitis."}
''';
      final ext = parseScanExtraction(raw, ocr)!;
      expect(ext.results, isEmpty);
      expect(ext.note, contains('seborrheic dermatitis'));
    });

    test('reads title, type, date, and grounded results', () {
      const raw = '''
{"title": "PET-CT Scan", "type": "lab", "date": "30-Aug-2024",
 "results": [{"label": "Fasting blood sugar", "value": "89 mg/dl", "range": null},
             {"label": "MTB Complex", "value": "Not Detected"}],
 "note": "Whole body PET-CT for PUO evaluation."}''';
      final ext = parseScanExtraction(raw, ocr, parseDate: parseDate)!;
      expect(ext.title, 'PET-CT Scan');
      expect(ext.type, DocumentType.lab);
      expect(ext.date, DateTime(2024, 8, 30));
      expect(ext.results.map((r) => '${r.label}: ${r.value}'), [
        'Fasting blood sugar: 89 mg/dl',
        'MTB Complex: Not Detected',
      ]);
      expect(ext.note, isNotNull);
    });

    test('drops a title whose words are not on the page', () {
      // A redacted pharmacy-invoice payload can starve the cloud model into
      // inventing a lab panel title.
      const raw = '{"title": "COMPREHENSIVE METABOLIC PANEL", "type": "lab"}';
      final ext = parseScanExtraction(raw, ocr, parseDate: parseDate)!;
      expect(ext.title, isNull);
      expect(ext.type, DocumentType.lab);
    });

    test('keeps a printed title despite small OCR typos (60% bar)', () {
      const billOcr =
          'GST INVOICE  FENWICK MEDXCAL STORES\nNET : 1956.00\nGSTIN 27ABD';
      const raw = '{"title": "Fenwick Medical Stores invoice", "type": "bill"}';
      final ext = parseScanExtraction(raw, billOcr, parseDate: parseDate)!;
      // fenwick/stores/invoice ground (3 of 4 ≥ 60%); "medical" is an OCR typo.
      expect(ext.title, 'Fenwick Medical Stores invoice');
      // "bill" and "invoice" alias to receipt.
      expect(ext.type, DocumentType.receipt);
    });

    test('drops a result whose number is not in the OCR text', () {
      const raw =
          '{"results": [{"label": "Cholesterol", "value": "210 mg/dl"}]}';
      final ext = parseScanExtraction(raw, ocr, parseDate: parseDate);
      // 210 never appears in the OCR → hallucinated → dropped → nothing left.
      expect(ext, isNull);
    });

    test(
      'rejects a flipped verdict ("Detected" when page says "Not Detected")',
      () {
        // The dangerous case: the OCR says "Not Detected"; a model must NOT be able
        // to ground a bare "Detected" against it (that would flip a TB result).
        const flip =
            '{"results": [{"label": "MTB Complex", "value": "Detected"}]}';
        expect(parseScanExtraction(flip, ocr, parseDate: parseDate), isNull);

        // The un-negated verdict on the page is accepted.
        const ok =
            '{"results": [{"label": "MTB Complex", "value": "Not Detected"}]}';
        expect(
          parseScanExtraction(
            ok,
            ocr,
            parseDate: parseDate,
          )?.results.single.value,
          'Not Detected',
        );

        const invented = '{"results": [{"label": "HIV", "value": "Reactive"}]}';
        expect(
          parseScanExtraction(invented, ocr, parseDate: parseDate),
          isNull,
        );
      },
    );

    test('tolerates code fences and chatter around the JSON', () {
      const raw =
          'Sure, here you go:\n```json\n'
          '{"title": "PET-CT Scan"}\n```\nHope that helps!';
      final ext = parseScanExtraction(raw, ocr, parseDate: parseDate);
      expect(ext?.title, 'PET-CT Scan');
    });

    test('returns null on truncated / unparseable output', () {
      expect(
        parseScanExtraction('{"title": "PET-CT', ocr, parseDate: parseDate),
        isNull,
      );
      expect(
        parseScanExtraction('no json here', ocr, parseDate: parseDate),
        isNull,
      );
    });

    test('rejects a refusal title and an out-of-enum type', () {
      const raw =
          '{"title": "I cannot determine this", "type": "unknown_kind"}';
      final ext = parseScanExtraction(raw, ocr, parseDate: parseDate);
      // Title is a refusal (dropped), type not in the enum (dropped) → empty.
      expect(ext, isNull);
    });

    test('rejects a date whose year is absent from the OCR', () {
      const raw = '{"date": "01-Jan-2020"}';
      expect(parseScanExtraction(raw, ocr, parseDate: parseDate), isNull);
    });

    test('parses imaging type and clears vitals from results', () {
      const raw = '''
{"title": "PET-CT Scan", "type": "imaging", "date": "30-Aug-2024",
 "results": [{"label": "Pulse", "value": "89"},
             {"label": "Fasting blood sugar", "value": "89 mg/dl"}],
 "note": "No FDG-avid lesion. Impression: negative study."}''';
      final ext = parseScanExtraction(raw, ocr, parseDate: parseDate)!;
      expect(ext.type, DocumentType.imaging);
      expect(ext.results, isEmpty);
      expect(ext.note, contains('Impression'));
    });

    test('discharge clears results; receipt drops model rows, keeps note', () {
      const discharge = '''
{"type": "discharge", "results": [{"label": "Pulse", "value": "89"}],
 "note": "Discharged in stable condition."}''';
      final d = parseScanExtraction(discharge, ocr, parseDate: parseDate)!;
      expect(d.type, DocumentType.discharge);
      expect(d.results, isEmpty);
      expect(d.note, contains('stable'));

      // A bill breakdown is geometry-only. The model may contribute the
      // "what was this for" note plus title/date, never rows.
      const billOcr =
          'City Pharmacy\nInvoice\nAmoxicillin 12.00\nTotal paid 24.50\n';
      const receipt = '''
{"type": "receipt",
 "results": [{"label": "Amoxicillin", "value": "12.00"},
             {"label": "Total paid", "value": "24.50"}],
 "note": "Antibiotics purchase"}''';
      final r = parseScanExtraction(receipt, billOcr, parseDate: parseDate)!;
      expect(r.type, DocumentType.receipt);
      expect(r.results, isEmpty);
      expect(r.note, 'Antibiotics purchase');
    });

    test('receipt model rows never reach the breakdown via the merge', () {
      const deterministic = [
        DocumentResult('BALBACK PRO 60ML', '₹1440.00'),
        DocumentResult('Final amount', '₹1956.00'),
      ];
      const refined = [
        DocumentResult('D.L.No:20/111111', '₹1956.10'),
        DocumentResult('Get Well Soon', '₹1956.00'),
      ];
      final merged = mergeRefinedResults(
        type: DocumentType.receipt,
        deterministic: deterministic,
        refined: refined,
      );
      expect(merged, same(deterministic));
    });

    test('enforceScanShape clears imaging results', () {
      const ext = ScanExtraction(
        type: DocumentType.imaging,
        results: [DocumentResult('BP', '120/80')],
        note: 'Normal study.',
      );
      final shaped = enforceScanShape(ext);
      expect(shaped.results, isEmpty);
      expect(shaped.note, 'Normal study.');
    });

    test(
      'histopathology is always a narrative lab even if model says imaging',
      () {
        const ocr = '''
HISTOPATHOLOGY
Macroscopic Description: Grey brown tissue.
Microscopic Description: Granulomatous inflammation.
IMPRESSION: Necrotizing granulomatous inflammation.
''';
        const raw = '''
{"title":"Histopathology Report","type":"imaging","date":null,
 "results":[{"label":"Case","value":"802","range":null}],
 "note":"Necrotizing granulomatous inflammation."}
''';
        final ext = parseScanExtraction(raw, ocr)!;
        expect(ext.type, DocumentType.lab);
        expect(ext.results, isEmpty);
        expect(ext.note, contains('granulomatous inflammation'));
      },
    );

    test('partial cloud lab rows can never replace deterministic rows', () {
      const deterministic = [
        DocumentResult('Haemoglobin', '13.0', unit: 'g/dL', range: '14-18'),
        DocumentResult('Basophils', '0', unit: '%', range: '0-2'),
        DocumentResult(
          'Platelet count',
          '180',
          unit: '10^3/µL',
          range: '140-440',
        ),
      ];
      const partialCloud = [DocumentResult('Hb', '13.0', range: '14-18')];

      final merged = mergeRefinedResults(
        type: DocumentType.lab,
        deterministic: deterministic,
        refined: partialCloud,
      );
      expect(merged, same(deterministic));
      expect(merged.length, 3);
      expect(merged[1].label, 'Basophils');
      expect(merged[2].unit, '10^3/µL');
    });

    test(
      'metadata-only LLM title leaves deterministic lab values untouched',
      () {
        const cbcOcr = '''
CBC Haemogram
Investigation Observed Value Unit Biological Reference Interval
Haemoglobin 13.0 g/dL 14-18
Basophils 0 % 0-2
''';
        const raw = '''
{"title":"CBC Haemogram","type":"lab","results":[]}
''';
        final metadata = parseScanExtraction(raw, cbcOcr)!;
        const deterministic = [
          DocumentResult('Haemoglobin', '13.0', unit: 'g/dL', range: '14-18'),
          DocumentResult('Basophils', '0', unit: '%', range: '0-2'),
        ];
        final merged = mergeRefinedResults(
          type: DocumentType.lab,
          deterministic: deterministic,
          refined: metadata.results,
        );

        expect(metadata.title, 'CBC Haemogram');
        expect(merged, same(deterministic));
        expect(merged.last.value, '0');
      },
    );

    test('verified full-grid reconciliation replaces the complete draft', () {
      const deterministic = [
        DocumentResult('HbA1c- Glycated Haemoglobin', '', unit: '%'),
        DocumentResult(
          'Estimated Average Glucose (eAG)',
          '99.67',
          unit: 'mg/dL',
        ),
      ];
      const repair = [
        DocumentResult('HbA1c- Glycated Haemoglobin', '5.1', unit: '%'),
        DocumentResult(
          'Estimated Average Glucose (eAG)',
          '100.00',
          unit: 'mg/dL',
        ),
      ];

      final merged = mergeRefinedResults(
        type: DocumentType.lab,
        deterministic: deterministic,
        refined: repair,
        verifiedTableRepair: true,
      );
      expect(merged[0].value, '5.1');
      // Cell-ID reconciliation is allowed to correct a confidently shifted
      // geometry row because its fields were rebuilt from local OCR cells.
      expect(merged[1].value, '100.00');
    });

    test('verified section repair retains rows from untouched sections', () {
      const deterministic = [
        DocumentResult('Haemoglobin', '13.0', unit: 'g/dL'),
        DocumentResult('Absolute Basophil Count', '', unit: '/c.mm'),
        DocumentResult('Platelet count', '180', unit: '10^3/µL'),
      ];
      const repair = [
        DocumentResult('Absolute Basophil Count', '0', unit: '/c.mm'),
      ];

      final merged = mergeRefinedResults(
        type: DocumentType.lab,
        deterministic: deterministic,
        refined: repair,
        verifiedTableRepair: true,
      );
      expect(merged.map((row) => row.label), [
        'Haemoglobin',
        'Absolute Basophil Count',
        'Platelet count',
      ]);
      expect(merged.map((row) => row.value), ['13.0', '0', '180']);
    });

    test('verified acronym row replaces an OCR label containing its value', () {
      const deterministic = [
        DocumentResult('MCHC (Mean Corpuscular Hb Concn.) 32.0', ''),
      ];
      const repair = [DocumentResult('MCHC', '32.0', unit: 'g/dL')];

      final merged = mergeRefinedResults(
        type: DocumentType.lab,
        deterministic: deterministic,
        refined: repair,
        verifiedTableRepair: true,
      );
      expect(merged, hasLength(1));
      expect(merged.single.label, 'MCHC');
      expect(merged.single.value, '32.0');
    });
  });

  group('labRowsUnderCovered', () {
    const cleanCbc = 'Haemoglobin 14.2 gm% 13 - 17\nPlatelet Count 250';

    test('a table with every row read asks for nothing', () {
      expect(
        labRowsUnderCovered(
          rows: const [
            DocumentResult('Haemoglobin', '14.2'),
            DocumentResult('Platelet Count', '250'),
          ],
          ocrText: cleanCbc,
        ),
        isFalse,
      );
    });

    test('no rows at all is the clearest signal', () {
      expect(labRowsUnderCovered(rows: const [], ocrText: cleanCbc), isTrue);
    });

    test('a blank value counts as under-covered', () {
      expect(
        labRowsUnderCovered(
          rows: const [
            DocumentResult('Haemoglobin', ''),
            DocumentResult('Platelet Count', '250'),
          ],
          ocrText: cleanCbc,
        ),
        isTrue,
      );
    });

    test('more observed-value lines than rows means one was missed', () {
      // Two of three antibody rows parsed; only the printed page knows.
      const ocr =
          'Rubella Virus - IgG antibody Reactive,45.90\n'
          'Measles (Rubeola) Virus - IgG antibody Positive,161.00\n'
          'Mumps virus IgG antibody, Serum Positive,96.30';
      expect(
        labRowsUnderCovered(
          rows: const [
            DocumentResult('Rubella Virus - IgG antibody', 'Reactive, 45.90'),
            DocumentResult(
              'Mumps virus IgG antibody, Serum',
              'Positive, 96.30',
            ),
          ],
          ocrText: ocr,
        ),
        isTrue,
      );
    });
  });

  group('labRows extraction', () {
    // The AFB culture page: verdicts written as sentences, no value column.
    const afbOcr = '''
MICROBIOLOGY
Name : Example Person
UHID : ANM1.0001005350
TEST NAME RESULT
ACID FAST STAIN OTHERS
Specimen Type Right supra clavicular lymph node
AFB Smear No AFB seen
AFB CULTURE [OTHERS]
Culture Report: TB:707
14/09/2024: No Mycobacterium species isolated at the end of 10days.
''';

    test('keeps a qualitative row no verdict vocabulary could enumerate', () {
      const raw = '''
{"results":[{"label":"AFB Smear","value":"No AFB seen"}]}''';
      final ext = parseScanExtraction(raw, afbOcr, labRows: true);
      expect(ext, isNotNull);
      expect(ext!.groundedLabRows, isTrue);
      expect(ext.results.single.label, 'AFB Smear');
      expect(ext.results.single.value, 'No AFB seen');
    });

    test('never flips a negative result into a positive one', () {
      const raw = '{"results":[{"label":"AFB Smear","value":"AFB seen"}]}';
      expect(parseScanExtraction(raw, afbOcr, labRows: true), isNull);
    });

    test('drops a test name that is not printed on the page', () {
      const raw =
          '{"results":[{"label":"Mycobacterium Culture","value":"No AFB seen"}]}';
      expect(parseScanExtraction(raw, afbOcr, labRows: true), isNull);
    });

    test('refuses the patient and order block as results', () {
      const raw =
          '{"results":['
          '{"label":"UHID","value":"ANM1.0001005350"},'
          '{"label":"Specimen Type","value":"Right supra clavicular lymph node"},'
          '{"label":"AFB Smear","value":"No AFB seen"}]}';
      final ext = parseScanExtraction(raw, afbOcr, labRows: true);
      expect(ext!.results.map((row) => row.label), ['AFB Smear']);
    });

    test('an invented number is dropped even with a real label', () {
      const raw = '{"results":[{"label":"AFB Smear","value":"12.4"}]}';
      expect(parseScanExtraction(raw, afbOcr, labRows: true), isNull);
    });

    // The serology page: the value column wraps ", Serum" onto the next line.
    const serologyOcr = '''
Investigation Observed Value Unit Biological Reference Interval
Measles (Rubeola) Virus - IgG antibody, Positive,161.00 AU/mL Negative: < 13.5
Serum
(Serum, Chemiluminescence Immunoassay (CLIA))
Mumps virus IgG antibody, Serum Positive,96.30 AU/mL Negative: < 9.0
''';

    test(
      'keeps a test name the value column wrapped, trimmed to what is printed',
      () {
        const raw =
            '{"results":[{"label":"Measles (Rubeola) Virus - IgG antibody, Serum",'
            '"value":"Positive, 161.00","unit":"AU/mL"}]}';
        final ext = parseScanExtraction(raw, serologyOcr, labRows: true);
        expect(
          ext!.results.single.label,
          'Measles (Rubeola) Virus - IgG antibody',
        );
        expect(ext.results.single.value, 'Positive, 161.00');
      },
    );

    test('refuses a name stitched from words scattered over the page', () {
      const raw =
          '{"results":[{"label":"Measles Reference Interval Investigation",'
          '"value":"Positive, 161.00"}]}';
      expect(parseScanExtraction(raw, serologyOcr, labRows: true), isNull);
    });

    test('the method sub-line is never a row of its own', () {
      const raw =
          '{"results":[{"label":"(Serum, Chemiluminescence Immunoassay (CLIA))",'
          '"value":"Positive, 161.00"}]}';
      expect(parseScanExtraction(raw, serologyOcr, labRows: true), isNull);
    });

    test('grounded rows only add; geometry rows survive byte for byte', () {
      const deterministic = [
        DocumentResult(
          'Rubella Virus - IgG antibody',
          'Reactive, 45.90',
          unit: 'IU/mL',
          range: 'Non-reactive: < 10',
        ),
      ];
      const refined = [
        // Same test the geometry already read, plus the one it missed.
        DocumentResult('Rubella Virus - IgG antibody', 'Reactive'),
        DocumentResult(
          'Measles (Rubeola) Virus - IgG antibody',
          'Positive, 161.00',
          unit: 'AU/mL',
        ),
      ];

      final merged = mergeRefinedResults(
        type: DocumentType.lab,
        deterministic: deterministic,
        refined: refined,
        groundedLabRows: true,
      );
      expect(merged, hasLength(2));
      expect(merged.first.value, 'Reactive, 45.90');
      expect(merged.first.range, 'Non-reactive: < 10');
      expect(merged.last.label, 'Measles (Rubeola) Virus - IgG antibody');
    });

    test('without the flag a lab merge still ignores the model entirely', () {
      const deterministic = [DocumentResult('Haemoglobin', '14.2')];
      expect(
        mergeRefinedResults(
          type: DocumentType.lab,
          deterministic: deterministic,
          refined: const [DocumentResult('Platelet Count', '250')],
        ),
        equals(deterministic),
      );
    });
  });
}
