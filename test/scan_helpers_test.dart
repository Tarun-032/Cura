// Scan helper tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/library/document.dart';
import 'package:cura/features/scan/document_shape.dart';
import 'package:cura/features/scan/scan_service.dart';

void main() {
  final svc = ScanService();

  const lftText = '''
Dr. (Mrs.) Grace Quinn's
COMPUTERISED PATHOLOGY LABORATORY
PATIENTS NAME : MR. PETER DOE
LIVER FUNCTION TEST
TEST DONE   OBSERVED VALUE   NORMAL RANGE
Serum Bilirubin (Total)   0.5   0 - 1.5 mg/dl
''';

  group('detectTitle', () {
    test('matches a known panel name, not the clinic letterhead', () {
      expect(svc.detectTitle(lftText), 'Liver Function Test');
    });

    test('recognizes CBC Haemogram immediately without paraphrasing it', () {
      const text = '''
CBC Haemogram
Investigation Observed Value Unit Biological Reference Interval
Haemoglobin 13.0 g/dL 14-18
''';
      expect(svc.detectTitle(text), 'CBC Haemogram');
    });

    test('names a rubella, measles and mumps IgG bundle from its tests', () {
      const text = '''
GREENFIELD
Rubella Virus - IgG antibody Reactive,45.90
Measles (Rubeola) Virus - IgG antibody Positive,161.00
Mumps virus IgG antibody Positive,96.30
MEDICAL LABORATORY REPORT
''';
      expect(
        svc.detectTitle(text),
        'Rubella, Measles & Mumps IgG Antibody Report',
      );
    });

    test('falls back to a prominent heading for an unknown panel', () {
      const text = 'CITY DIAGNOSTICS\nGAMMA SCREEN PANEL\nSome Test 1.0 2-3';
      expect(svc.detectTitle(text), 'Gamma Screen Panel');
    });

    test('never returns the column-header row or clinic name', () {
      const text =
          "Dr. (Mrs.) Grace Quinn's\n"
          'COMPUTERISED PATHOLOGY LABORATORY\n'
          'TEST DONE   OBSERVED VALUE   NORMAL RANGE\n';
      final title = svc.detectTitle(text);
      // Keep the generic fallback.
      expect(title, 'Lab report');
      expect(title.toLowerCase(), isNot(contains('observed value')));
      expect(title.toLowerCase(), isNot(contains('quinn')));
    });

    test('names an imaging report from its heading (PET-CT)', () {
      const text =
          'DEPARTMENT OF NUCLEAR MEDICINE\n'
          'Contrast Enhanced 18F-FDG Whole Body PET-CT Scan\n'
          'Protocol: F-FDG was injected after overnight fasting.\n';
      expect(svc.detectTitle(text), 'PET-CT Scan');
    });

    test('does not title from a panel name mentioned inside a paragraph', () {
      // Keep prose out of titles.
      const text =
          'Contrast Enhanced 18F-FDG Whole Body PET-CT Scan\n'
          'The fasting blood sugar level at the time of injection was 89 mg/dl.\n';
      expect(svc.detectTitle(text), 'PET-CT Scan');
    });

    test(
      'names a histopathology report (not blocked by the patholog filter)',
      () {
        const text =
            'HISTOPATHOLOGY TEST [LARGE]\n'
            'Ref No:\nSpecimen:\nRight supraclavicular lymph node\n'
            'IMPRESSION:\nNecrotizing Granulomatous Lymphadenitis.\n';
        expect(svc.detectTitle(text), 'Histopathology');
      },
    );

    test('repairs an OCR digit-for-letter slip in the panel name (blo0d)', () {
      // Fix 0 for o.
      const text = '''
Complete Blo0d Count
Investigation Observed Value Unit Biological Reference Interval
Haemoglobin 13.0 g/dL 14-18
''';
      expect(svc.detectTitle(text), 'Complete Blood Count');
    });

    test('rejects "* End Of Report *" as a title', () {
      const text =
          'MOLECULAR BIOLOGY AND CYTOGENETICS\n'
          'XPERT MTB/RIF ULTRA\n'
          '* END OF REPORT *\n';
      expect(svc.detectTitle(text), 'Xpert MTB/RIF');
    });

    test('rejects a report-status line that reads like a heading', () {
      // All caps still needs a fallback.
      const text =
          'MICROBIOLOGY\n'
          'TEST NAME   RESULT\n'
          'AFB CULTURE [OTHERS]   NO AFB GROWN TB:707\n'
          '16/10/2024: No Mycobacterium species isolated at the end of 42 days.\n'
          'THIS IS FINAL REPORT.\n'
          'Report Status:Final\n'
          'Amended Report\n';
      final title = svc.detectTitle(text);
      expect(title, isNot(contains('Final Report')));
      expect(title, 'Microbiology');
    });
  });

  group('extractDate', () {
    test('reads a month-name date (30-Aug-2024)', () {
      expect(
        svc.extractDate('Received on : 30-Aug-2024 12:20:51'),
        DateTime(2024, 8, 30),
      );
    });

    test('prefers the reported date over collected/received', () {
      const text =
          'Collected on  03-SEP-2024 08:37:41 PM\n'
          'Received on : 03-SEP-2024 10:45:33 PM\n'
          'Reported on : 04-SEP-2024 04:16:31 PM\n';
      expect(svc.extractDate(text), DateTime(2024, 9, 4));
    });

    test('never picks a date of birth', () {
      const text = 'DOB: 02-SEP-1990\nReported on : 04-SEP-2024\n';
      expect(svc.extractDate(text), DateTime(2024, 9, 4));
    });

    test('printed report date beats an earlier journal citation', () {
      const text = '''
Reference publication date: 13-05-2016.
Reprinted On: 01/07/2025 4:44 PM
''';
      expect(svc.extractDate(text), DateTime(2025, 7, 1));
    });

    test('still reads a numeric date', () {
      expect(svc.extractDate('Sample date 27/09/2024'), DateTime(2024, 9, 27));
    });

    test('ignores non-date number-word pairs', () {
      expect(
        svc.extractDate('Patient is 34 Years old. 128 slice scanner.'),
        isNull,
      );
    });

    test('a bill-labeled date beats an unlabeled one', () {
      const text =
          'Valid till 31/12/2026\n'
          'Bill No : ANM-OCS-1871772   Date : 2-Apr-25   Time : 9:48:28\n';
      expect(svc.extractDate(text), DateTime(2025, 4, 2));
    });

    test('an invoice-labeled date beats an unlabeled one', () {
      const text =
          'Delivery by 05/02/2026\n'
          'Inv.No: 26646   Date : 21/01/2026 11:50 AM\n';
      expect(svc.extractDate(text), DateTime(2026, 1, 21));
    });
  });

  group('acceptsRefinedType', () {
    const usg = 'Findings: Single live intrauterine gestation.';
    test('refuses a narrative report being demoted to a lab table', () {
      expect(
        acceptsRefinedType(
          current: DocumentType.imaging,
          next: DocumentType.lab,
          extractedText: usg,
          hasSummary: true,
        ),
        isFalse,
      );
    });

    test('allows it when there is no summary to lose', () {
      expect(
        acceptsRefinedType(
          current: DocumentType.imaging,
          next: DocumentType.lab,
          extractedText: usg,
          hasSummary: false,
        ),
        isTrue,
      );
    });

    test('allows narrative → narrative and any non-narrative start', () {
      expect(
        acceptsRefinedType(
          current: DocumentType.imaging,
          next: DocumentType.discharge,
          extractedText: usg,
          hasSummary: true,
        ),
        isTrue,
      );
      expect(
        acceptsRefinedType(
          current: DocumentType.lab,
          next: DocumentType.receipt,
          extractedText: 'HB 13.5 g/dl',
          hasSummary: true,
        ),
        isTrue,
      );
    });
  });

  group('extractFindingsSummary', () {
    test('a heading with nothing under it is dropped', () {
      // Drop empty headings.
      const text =
          'Specimen: Sinus from cold abscess.\n'
          'Microscopic Description:\n'
          "Impression: Necrotizing granulomatous inflammation of likely Koch's "
          'etiology.\n';
      final summary = svc.extractFindingsSummary(text)!;
      expect(summary, isNot(contains('Microscopic Description:')));
      expect(summary, contains('Sinus from cold abscess'));
      expect(summary, contains('granulomatous inflammation'));
    });

    test('a heading that does have a body survives', () {
      const text =
          'Microscopic Description:\n'
          'Inflamed sinus tract with epithelioid granulomas.\n';
      final summary = svc.extractFindingsSummary(text)!;
      expect(summary, contains('Microscopic Description:'));
      expect(summary, contains('epithelioid granulomas'));
    });

    test('a trailing empty heading is dropped', () {
      const text =
          'Impression: Benign.\n'
          'Comments:\n';
      final summary = svc.extractFindingsSummary(text)!;
      expect(summary, 'Impression: Benign.');
    });

    test('captures Indication + Findings, skips Protocol methodology', () {
      const text =
          'Contrast Enhanced 18F-FDG Whole Body PET-CT Scan\n'
          'Protocol: F-FDG was injected after overnight fasting. The fasting '
          'blood sugar level was 89 mg/dl.\n'
          'Indication: Case of PUO under evaluation.\n'
          'Findings:\n'
          'No focal FDG uptake in the oral cavity, larynx or pharynx.\n'
          'Increased FDG uptake in the necrotic right supraclavicular nodes.\n';
      final summary = svc.extractFindingsSummary(text)!;
      expect(summary, contains('Case of PUO under evaluation'));
      expect(summary, contains('supraclavicular nodes'));
      // Keep protocol details out.
      expect(summary, isNot(contains('89')));
      expect(summary, isNot(contains('overnight fasting')));
    });

    test('skips letterhead/footer/demographics between pages', () {
      const text = '''
Findings:
Nuchal translucency measures 1.8mm.
This is a computer generated report. Signature is not required.
Facility Address: Building No F-16, Sector-50, Fairview, Example State -999301
Regd. Office: Springvale Health Limited, E-18 Meadow colony, Riverton, 999024
Tel: +919000000000
Email: info@example.org
CIN: L85110XX2004PLC128319
Printed By THBPP on 03 Jul 2026
Page 1 of 4
Name: Mrs. Asha Example
Encounter ID: 100000000001
UHID: MN00000001
DOB: 01 Jan 1990
Gender: F
Doctor: Dr. Example Consultant
Ductus venosus flow is normal.
Impression: Single live intrauterine gestation.
''';
      final summary = svc.extractFindingsSummary(text)!;
      // Clinical content on both sides of the identity block survives.
      expect(summary, contains('Nuchal translucency'));
      expect(summary, contains('Ductus venosus'));
      expect(summary, contains('Single live intrauterine gestation'));
      for (final leak in [
        'Sector-50',
        'Meadow colony',
        '919000000000',
        'info@example.org',
        'L85110XX2004PLC128319',
        'THBPP',
        'Page 1',
        'Asha Example',
        '100000000001',
        'MN00000001',
        '01 Jan 1990',
        'computer generated',
      ]) {
        expect(summary, isNot(contains(leak)), reason: 'leaked: $leak');
      }
    });

    test('strips identity merged mid-line by column-flattening OCR', () {
      // Real shape: a PDF sidebar (branches, demographics) flattened into the
      // middle of the Comments prose by OCR reading order.
      const text =
          'Comments: First trimester screening for Prenatal disorders '
          '(Trisomy 21, 18 & 13) is essential to identify those women at '
          'sufficient risk for a Springvale Network: Northport | Riverbend | Riverton| '
          'Springfield | Westport | Eastvale | Fairview sprIngVale Gender: Female Authorized: '
          '6 Jul 2026 14:45 General Speciality DOB: 01 Jan 1990 (34 years) '
          'Specimen Type: Serum congenital anomaly in the fetus to warrant '
          'further evaluation.\n';
      final summary = svc.extractFindingsSummary(text)!;
      // The clinical sentence on both sides of the merged block survives.
      expect(summary, contains('First trimester screening'));
      expect(summary, contains('congenital anomaly in the fetus'));
      for (final leak in [
        'Northport',
        'Riverton',
        'Female',
        '01 Jan 1990',
        '34 years',
      ]) {
        expect(summary, isNot(contains(leak)), reason: 'leaked: $leak');
      }
    });

    test('returns null when there are no narrative sections', () {
      const text = 'TEST NAME  RESULT\nMTB COMPLEX  Not Detected\n';
      expect(svc.extractFindingsSummary(text), isNull);
    });

    test('keeps a long Findings/Impression body (cap 2500)', () {
      final findings = List.generate(
        25,
        (i) => 'Segment $i shows no focal FDG uptake in the soft tissues.',
      ).join(' ');
      final text =
          'PET-CT Scan\n'
          'Findings:\n$findings\n'
          'Impression: Negative study for metabolically active disease.\n';
      final summary = svc.extractFindingsSummary(text)!;
      expect(summary.length, greaterThan(900));
      expect(summary.length, lessThanOrEqualTo(2501)); // cap or cap+ellipsis
      expect(summary, contains('Findings'));
      expect(summary, contains('Negative study'));
    });

    test('captures Diagnosis + Procedure on a discharge summary', () {
      const text =
          'DISCHARGE SUMMARY\n'
          'Diagnosis:\n'
          'Acute calculous cholecystitis.\n'
          'Procedure:\n'
          'Laparoscopic cholecystectomy.\n'
          'Hospital course:\n'
          'Uneventful postoperative recovery.\n'
          'Condition on discharge: Stable.\n'
          'Protocol: Internal coding only.\n';
      final summary = svc.extractFindingsSummary(text)!;
      expect(summary, contains('Acute calculous cholecystitis'));
      expect(summary, contains('Laparoscopic cholecystectomy'));
      expect(summary, contains('Uneventful postoperative recovery'));
      expect(summary, contains('Stable'));
      // Protocol methodology must not leak into the summary.
      expect(summary, isNot(contains('Internal coding')));
    });

    test('captures narrative histopathology sections', () {
      const text = '''
HISTOPATHOLOGY
Ref No: H-802/25
Specimen:
Sinus from cold abscess of supraclavicular region
Macroscopic Description:
Received irregular grey brown tissue measuring 3.5 x 3 x 3 cm.
Microscopic Description:
Inflamed sinus tract with necrotizing granulomatous inflammation.
IMPRESSION:
Inflamed sinus tract with necrotizing granulomatous inflammation.
Comments:
Suggested correlation with clinical and radiological findings.
Tissue specimen received at Meadowlark Hospitals, Fairview will be discarded.
''';
      final summary = svc.extractFindingsSummary(text)!;
      expect(summary, contains('Specimen:'));
      expect(summary, contains('Macroscopic Description:'));
      expect(summary, contains('Microscopic Description:'));
      expect(summary, contains('Impression:'));
      expect(summary, contains('Comments:'));
      expect(summary, isNot(contains('H-802/25')));
      expect(summary, isNot(contains('Meadowlark Hospitals')));
      expect(summary, isNot(contains('Fairview')));
    });
  });

  group('detectType', () {
    test(
      'histopathology stays Lab report but uses narrative Summary shape',
      () {
        const text = 'HISTOPATHOLOGY\nMicroscopic Description: Inflammation.';
        expect(svc.detectType(text), DocumentType.lab);
        expect(isSummaryDocument(DocumentType.lab, text), isTrue);
      },
    );

    test('lab is the default for a results page', () {
      expect(svc.detectType(lftText), DocumentType.lab);
    });

    test('prescription and receipt by keyword', () {
      expect(
        svc.detectType('Prescription\nAmoxicillin 500 mg'),
        DocumentType.prescription,
      );
      expect(
        svc.detectType('Pharmacy Receipt\nGrand Total 24.50'),
        DocumentType.receipt,
      );
    });

    test('imaging for PET-CT / MRI headings', () {
      expect(
        svc.detectType(
          'Contrast Enhanced 18F-FDG Whole Body PET-CT Scan\n'
          'Findings: No FDG avid lesion.\n',
        ),
        DocumentType.imaging,
      );
      expect(
        svc.detectType('MRI Brain\nImpression: Normal study.'),
        DocumentType.imaging,
      );
    });

    test('discharge by keyword', () {
      expect(
        svc.detectType('Discharge Summary\nPulse 88\nPatient discharged.'),
        DocumentType.discharge,
      );
    });

    test('hospital cash bill without the word receipt is a receipt', () {
      expect(
        svc.detectType(
          'Day Care/OP Cash Bill - Bill of Supply\n'
          'GSTIN : 27AAAAA0000A1Z5\n'
          'Amount in words: Three Thousand Only\n'
          'USG Small Part 3,360.00',
        ),
        DocumentType.receipt,
      );
    });

    test('pharmacy GST invoice full of drug names is a receipt, not rx', () {
      expect(
        svc.detectType(
          'GST INVOICE\nFENWICK MEDICAL STORES\n'
          'BALBACK PRO 60ML 1440.00\nCERATINA CAP 516.10\nNET : 1956.00',
        ),
        DocumentType.receipt,
      );
    });

    test('a lab report with a stray Bill No line stays lab', () {
      expect(svc.detectType('Bill No: 1234\n$lftText'), DocumentType.lab);
    });
  });

  group('detectReceiptTitle', () {
    test('vendor from the letterhead, bill vs invoice from wording', () {
      expect(
        svc.detectTitle(
          'Meadowlark HOSPITALS\n'
          'GSTIN : 27AAAAA0000A1Z5   Day Care/OP Cash Bill - Bill of Supply\n'
          'Name : Mr. PETER VANCE DOE   Age : 34Yr\n'
          'Amount in words: Three Thousand Only',
        ),
        'Meadowlark Hospitals bill',
      );
      expect(
        svc.detectTitle(
          'GST INVOICE   FENWICK MEDICAL STORES   Inv.No: 26646\n'
          'NEW FAIRVIEW, RIVERTON.999206 MOB. NO 8000000000\n'
          'NET : 1956.00',
        ),
        'Fenwick Medical Stores invoice',
      );
    });

    test('falls back to Medical bill when no vendor line qualifies', () {
      expect(
        svc.detectTitle('CASH BILL\nSub Total 100.00\nGrand Total 100.00'),
        'Medical bill',
      );
    });
  });

  group('summarize', () {
    test('counts results and flags those outside range', () {
      final results = [
        const DocumentResult('SGPT', '31.7', range: '0 - 45'),
        const DocumentResult('Total Proteins', '8.5', range: '6.0 - 8.3'),
        const DocumentResult('Globulin', '4.1', range: '2.3 - 3.5'),
      ];
      // Two are above their upper bound.
      expect(
        svc.summarize(results),
        '3 results · 2 outside the normal range: Total Proteins, Globulin',
      );
    });

    test('all within range', () {
      final results = [
        const DocumentResult('Hemoglobin', '14.2', range: '13 - 17'),
      ];
      expect(svc.summarize(results), '1 result · all within the normal range');
    });

    test('receipts get a money note, never range talk', () {
      final results = [
        const DocumentResult('USG Small Part', '₹3,360.00'),
        const DocumentResult('Total', '₹3,360.00'),
      ];
      expect(
        svc.summarize(results, type: DocumentType.receipt),
        'Total ₹3,360.00 · 1 item',
      );
    });

    test('categorical antibody ranges are not called above normal', () {
      final results = [
        const DocumentResult(
          'Measles IgG antibody',
          'Positive, 161.00',
          range: 'Negative: < 13.5; Borderline: 13.5-16.49; Positive: >= 16.5',
        ),
      ];
      expect(svc.summarize(results), '1 result');
    });

    test('null for no results', () {
      expect(svc.summarize(const []), isNull);
    });
  });
}
