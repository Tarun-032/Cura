// Cloud PII barrier tests.
// Keep medical text; drop identity.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/ai/remote/cloud_privacy_gate.dart';
import 'package:cura/features/ai/remote/pii_redactor.dart';
import 'package:cura/features/ai/retrieval.dart';
import 'package:cura/features/library/document.dart';
import 'package:cura/features/scan/table_parser.dart';

const _report = '''
A. B. NORTHGATE NATIONAL HOSPITAL
& MEDICAL RESEARCH CENTRE
(Established and managed by the Northgate Health & Education Society)
GREENFIELD MARG, FAIRVIEW - 999 016, INDIA
PHONE : 1111 1515, 1111 2222   FAX : 1111 9151
DEPARTMENT OF LABORATORY MEDICINE
ORDER NO. : 11112222   EX NO. : 3334444   ADM. NO. :
NAME : DOE PETER S   AGE : 34 YEARS   SEX : MALE
DATE : 05/09/2024   LOCATION : OPD   REFERRED BY DR. : MEADOWLARK HOSP
Passport No. :
UHID: 1234567
Email: info@citycare.com
TB PYROSEQUENCING XDR
SAMPLE    TISSUE
Mycobacterium Tuberculosis Complex ( IS6110 )   NOT DETECTED
Haemoglobin        13.5 g/dL      13.0-17.0
Platelet Count     150000 /cumm   150000-410000
Sex Hormone Binding Globulin   45 nmol/L
Prostate Specific Antigen   1.2 ng/mL
ECG: Left bundle branch block, normal axis
Impression: Mild anemia noted.
Collected: 03/09/2024
''';

void main() {
  group('billCloudText (bill allowlist)', () {
    const bill = '''
Meadowlark HOSPITALS
GSTIN : 27AAAAA0000A1Z5   Day Care/OP Cash Bill - Bill of Supply
Name : Mr. PETER VANCE DOE   Age : 34Yr 6Mth   Sex : Male
Address : A1/11/1, SEC-11, NEW FAIRVIEW   CellNo:91-9000000000
UHID: ANM1.0000000000
OP Consultation - First Visit   Medical   1   2,000.00   0.00   2,000.00
Sub Total   2,000.00
Final Payment   (Cash:0.00, NonCash:2,000.00)   2,000.00
Two Thousand Only From Mr. PETER VANCE DOE
NET : 1956.00
''';

    test('keeps fee lines and totals the medical allowlist would starve', () {
      final safe = billCloudText(bill);
      expect(safe, contains('OP Consultation - First Visit'));
      expect(safe, contains('2,000.00'));
      expect(safe, contains('Sub Total'));
      expect(safe, contains('NET : 1956.00'));
    });

    test('drops the patient block wholesale, even ALL-CAPS names', () {
      final safe = billCloudText(bill);
      expect(safe, isNot(contains('PETER')));
      expect(safe, isNot(contains('DOE')));
      expect(safe, isNot(contains('9000000000')));
      expect(safe, isNot(contains('FAIRVIEW')));
      expect(safe, isNot(contains('ANM1.0000000000')));
      // Keep the vendor out.
      expect(safe, isNot(contains('Meadowlark')));
    });

    test('gate routes receipts through the bill allowlist', () {
      const gate = CloudPrivacyGate();
      final medical = gate.scanText(bill, type: DocumentType.lab).text;
      final asBill = gate.scanText(bill, type: DocumentType.receipt).text;
      // Medical path drops the fee.
      expect(medical, isNot(contains('OP Consultation - First Visit')));
      // Bill path keeps it, without identity.
      expect(asBill, contains('OP Consultation'));
      expect(asBill, isNot(contains('PETER')));
    });

    test(
      'keeps a complete table window but strips footer cells sharing rows',
      () {
        const noisy = '''
Product Name   MRP   Batch   Expiry   GST   Amount
BALBACK PRO 60ML   1440.00   BCC4754   10/26   18   1440.00
CERATINA CAP   258.05   CER5C02A   02/27   5   516.10
D.L.No:20/111111,21/111112   Gross : 1956.10
SHOP NO. 1 SEC-1-S   Less : 0.00
PLOT NO 46 NEW FAIRVIEW   GST Tax: 244.24
Get Well Soon   NET : 1956.00
''';

        final safe = billCloudText(noisy);

        expect(safe, contains('BALBACK PRO 60ML'));
        expect(safe, contains('CERATINA CAP'));
        expect(safe, contains('Gross : 1956.10'));
        expect(safe, contains('GST Tax: 244.24'));
        expect(safe, contains('NET : 1956.00'));
        for (final leak in [
          'D.L.No',
          '111111',
          'SHOP NO',
          'PLOT NO',
          'FAIRVIEW',
          'Get Well Soon',
        ]) {
          expect(safe, isNot(contains(leak)), reason: leak);
        }
      },
    );
  });

  group('redactForCloud', () {
    final out = redactForCloud(_report);

    test('removes every identifying detail', () {
      for (final leak in [
        'NORTHGATE',
        'HOSPITAL',
        'MEDICAL RESEARCH CENTRE',
        'Education Society',
        'GREENFIELD',
        'MARG',
        'FAIRVIEW',
        'INDIA',
        '999 016',
        '1111',
        'LABORATORY MEDICINE',
        'ORDER NO',
        '11112222',
        '3334444',
        'DOE PETER S',
        'MEADOWLARK HOSP',
        'Passport',
        'UHID',
        '1234567',
        'citycare.com',
      ]) {
        expect(out, isNot(contains(leak)), reason: 'leaked: $leak');
      }
    });

    test('keeps medical content, results and the date', () {
      expect(out, contains('TB PYROSEQUENCING XDR'));
      expect(out, contains('SAMPLE'));
      expect(out, contains('TISSUE'));
      expect(out, contains('Mycobacterium Tuberculosis Complex'));
      expect(out, contains('NOT DETECTED'));
      expect(out, contains('Haemoglobin'));
      expect(out, contains('13.5 g/dL'));
      expect(out, contains('13.0-17.0'));
      expect(out, contains('Impression'));
      expect(out, contains('Mild anemia'));
      expect(out, contains('03/09/2024'));
    });

    test('does not mistake real medical lines for PII', () {
      expect(out, contains('Platelet Count')); // 150000 is a count, not a PIN
      expect(out, contains('150000'));
      expect(out, contains('150000-410000'));
      expect(
        out,
        contains('Sex Hormone Binding Globulin'),
      ); // "sex" w/o a colon
      expect(
        out,
        contains('Prostate Specific Antigen'),
      ); // "state" inside prostate
      expect(out, contains('bundle branch block')); // ECG "block", not address
    });

    test('empty in → empty out', () {
      expect(redactForCloud(''), '');
      expect(redactForCloud('   '), '   ');
    });
  });

  // Allowlist test.
  group('medicalCloudText (allowlist minimization)', () {
    const report = '''
A. B. NORTHGATE NATIONAL HOSPITAL
GREENFIELD MARG, FAIRVIEW - 999 016, INDIA
Flat 3B, Green Meadows, Faketown 999103
221B Baker Street, London NW1
NAME : DOE PETER S   AGE : 34 YEARS   SEX : MALE
TB PYROSEQUENCING XDR
SAMPLE    TISSUE
Mycobacterium Tuberculosis Complex ( IS6110 )   NOT DETECTED
Haemoglobin        13.5 g/dL      13.0-17.0
Rpt Released dt. : 11-Sep-2024
Impression: Mild anemia noted.
Reviewed by Grace Quinn
This Report is electronically Signed.
''';

    final out = medicalCloudText(report, title: 'TB PYROSEQUENCING XDR');

    test('drops the whole letterhead / patient block / footer', () {
      for (final leak in [
        'NORTHGATE', 'HOSPITAL', 'MARG', 'FAIRVIEW',
        'Faketown', '999103', // unlisted city + keyword-less address
        'Baker Street', 'London', // foreign address, no cue needed
        'DOE PETER S', 'AGE', 'SEX',
        'Grace Quinn', // a bare name — no label, dropped by allowlist
        'Signed',
      ]) {
        expect(out, isNot(contains(leak)), reason: 'leaked: $leak');
      }
    });

    test('keeps the medical body', () {
      expect(out, contains('TB PYROSEQUENCING XDR'));
      expect(out, contains('TISSUE'));
      expect(out, contains('NOT DETECTED'));
      expect(out, contains('Haemoglobin'));
      expect(out, contains('13.5 g/dL'));
      expect(out, contains('Impression'));
      expect(out, contains('Mild anemia'));
      expect(out, contains('11-Sep-2024'));
    });
  });

  // Cloud Ask context test.
  group('buildContext includeRawText', () {
    final doc = CuraDocument(
      id: 'd1',
      title: 'PET-CT Scan',
      type: DocumentType.imaging,
      date: DateTime(2024, 9, 11),
      extractedText:
          'PATIENT NAME: DOE PETER S, 45 Meadow Street, Fairview.\n'
          'Impression: No FDG-avid lesion in the mediastinum.\n'
          'Findings: Necrotic right supraclavicular nodes show uptake.\n',
      resultsNote: 'No abnormality detected.',
    );

    test('cloud path keeps note + medical lines, drops letterhead', () {
      final safe = redactForCloud(buildContext([doc], includeRawText: false));
      expect(safe, isNot(contains('DOE PETER S')));
      expect(safe, isNot(contains('Meadow Street')));
      expect(safe, contains('PET-CT Scan')); // title kept
      expect(
        safe,
        contains('Imaging'),
      ); // type label on our header must survive
      expect(safe, contains('No abnormality detected')); // note kept
      expect(safe, contains('Impression')); // medical excerpt kept
      expect(safe, contains('supraclavicular'));
    });

    test('redactForCloud drops Imaging Centre but keeps bare Imaging', () {
      final out = redactForCloud(
        '[1] PET-CT Scan — Imaging — 11 Sep 2024\n'
        'City Imaging Centre\n'
        'Impression: No FDG-avid lesion.\n',
      );
      expect(out, contains('[1] PET-CT Scan — Imaging'));
      expect(out, contains('Impression'));
      expect(out, isNot(contains('City Imaging Centre')));
    });

    test('on-device path includes a long OCR excerpt', () {
      final full = buildContext([doc]);
      expect(full, contains('DOE PETER S')); // full OCR on device
      expect(full, contains('supraclavicular'));
      expect(full, contains('No abnormality detected'));
    });
  });

  group('cloud Ask payload inputs', () {
    test(
      'complete inventory exposes every record without OCR or page data',
      () {
        final docs = [
          CuraDocument(
            id: 'us-new',
            title: 'Ultrasound of neck',
            type: DocumentType.imaging,
            date: DateTime(2025, 4, 2),
            extractedText: 'PATIENT NAME: PRIVATE PERSON',
            pages: const ['C:/private/patient-scan.jpg'],
          ),
          CuraDocument(
            id: 'us-old',
            title: 'Ultrasound of abdomen',
            type: DocumentType.imaging,
            date: DateTime(2025, 1, 23),
            extractedText: 'UHID: 123456789',
          ),
          CuraDocument(
            id: 'cbc',
            title: 'Complete blood count',
            type: DocumentType.lab,
            date: DateTime(2024, 9, 3),
          ),
        ];

        final inventory = redactForCloud(buildRecordInventory(docs));
        expect(inventory, contains('3 total records'));
        expect(inventory, contains('Ultrasound of neck'));
        expect(inventory, contains('Ultrasound of abdomen'));
        expect(inventory, contains('Complete blood count'));
        expect(inventory, isNot(contains('PRIVATE PERSON')));
        expect(inventory, isNot(contains('123456789')));
        expect(inventory, isNot(contains('patient-scan.jpg')));
      },
    );

    test('chat sanitizer removes identifiers but preserves the question', () {
      final safe = redactConversationForCloud(
        'My name is Doe Peter S, MRN: 123456789; email peter@example.com. '
        'How many ultrasound reports do I have?',
      );
      expect(safe, isNot(contains('Doe Peter')));
      expect(safe, isNot(contains('123456789')));
      expect(safe, isNot(contains('peter@example.com')));
      expect(safe, contains('How many ultrasound reports do I have?'));
    });

    test('structured context cannot preserve a patient-labelled title', () {
      final safe = redactForCloud(
        '[1] Patient Name: Doe Peter S — Imaging — Apr 2, 2025',
      );
      expect(safe, contains('[1] Medical document — Imaging'));
      expect(safe, isNot(contains('Doe Peter S')));
    });

    test('structured header keeps a receipt vendor title verbatim', () {
      // Keep approved titles intact.
      final safe = redactForCloud(
        '[1] Fenwick Medical Stores invoice — Receipt — Jan 21, 2026',
      );
      expect(safe, contains('[1] Fenwick Medical Stores invoice — Receipt'));
      expect(safe, isNot(contains('Medical document')));
    });

    test('chat sanitizer removes clinician names from saved history', () {
      final safe = redactConversationForCloud(
        'Dr. Grace Quinn reviewed it. Explain the ultrasound findings.',
      );
      expect(safe, isNot(contains('Grace Quinn')));
      expect(safe, contains('Explain the ultrasound findings'));
    });
  });

  // Discharge summary test.
  group('discharge medicalCloudText', () {
    const discharge = '''
CITY CARE HOSPITAL
12 Meadow Street, Fairview - 999 001
NAME : DOE PETER S   AGE : 45 YEARS   SEX : MALE
DISCHARGE SUMMARY
Diagnosis:
Acute calculous cholecystitis.
Procedure:
Laparoscopic cholecystectomy.
Hospital course:
Uneventful postoperative recovery. Patient was advised soft diet.
Condition on discharge:
Stable.
Reviewed by Dr. Grace Quinn
''';

    final out = medicalCloudText(discharge, title: 'DISCHARGE SUMMARY');

    test('drops letterhead and patient identity', () {
      for (final leak in [
        'CITY CARE HOSPITAL',
        'Meadow Street',
        'Fairview',
        'DOE PETER S',
        'Grace Quinn',
      ]) {
        expect(out, isNot(contains(leak)), reason: 'leaked: $leak');
      }
    });

    test('keeps diagnosis and procedure bodies', () {
      expect(out, contains('Diagnosis'));
      expect(out, contains('Acute calculous cholecystitis'));
      expect(out, contains('Procedure'));
      expect(out, contains('Laparoscopic cholecystectomy'));
    });

    test('keeps hospital course and patient narrative', () {
      expect(out, contains('Hospital course'));
      expect(out, contains('Uneventful postoperative recovery'));
      expect(out, contains('Patient was advised soft diet'));
      expect(out, contains('Condition on discharge'));
      expect(out, contains('Stable'));
    });
  });

  group('CloudPrivacyGate', () {
    const gate = CloudPrivacyGate();

    test('dictionary-word person title falls back to a canonical title', () {
      final doc = CuraDocument(
        id: 'private',
        title: 'Amber Brown',
        type: DocumentType.imaging,
        date: DateTime(2025, 2, 1),
        extractedText: 'Ultrasound\nImpression: No focal lesion.',
      );

      final inventory = gate.buildInventory([doc]);
      expect(inventory.text, contains('Ultrasound'));
      expect(inventory.text, isNot(contains('Amber Brown')));
      expect(inventory.stats.titlesReplaced, 1);
    });

    test('safe clinical title and full report date survive', () {
      final doc = CuraDocument(
        id: 'safe',
        title: 'Ultrasound examination of right supraclavicular region',
        type: DocumentType.imaging,
        date: DateTime(2025, 4, 2),
      );

      final inventory = gate.buildInventory([doc]).text;
      expect(inventory, contains(doc.title));
      expect(inventory, contains('Apr 2, 2025'));
    });

    test('removes provider tails and labeled short identifiers from notes', () {
      final doc = CuraDocument(
        id: 'note',
        title: 'Ultrasound',
        type: DocumentType.imaging,
        date: DateTime(2025, 4, 2),
        resultsNote:
            'Impression: No focal lesion. Reviewed by Dr Amber Brown\n'
            'MRN: LH-1234',
        extractedText: 'Findings: Liver appears unremarkable.',
      );

      final context = gate.buildContext([doc]).text;
      expect(context, contains('No focal lesion'));
      // Note already covers it.
      expect(context, isNot(contains('Text:')));
      expect(context, isNot(contains('Amber Brown')));
      expect(context, isNot(contains('LH-1234')));
      expect(context, isNot(contains('MRN')));
    });

    test('user-authored ordinary language is not vocabulary filtered', () {
      final message = gate.userMessage(
        'Should I be worried about my kidney numbers after my gym routine changed?',
      );
      expect(message.content, contains('gym routine changed'));
      expect(message.origin, CloudMessageOrigin.userAuthored);
    });

    test('removes identity and organisation riding on a medical line', () {
      final doc = CuraDocument(
        id: 'merged-ocr',
        title: 'Ultrasound',
        type: DocumentType.imaging,
        date: DateTime(2025, 4, 2),
        extractedText:
            'Impression: No focal liver lesion; Patient Name: Amber Brown;\n'
            'Findings: Liver is unremarkable. Sunshine General Hospital\n'
            'Conclusion: Stable. Location: Rose Hill;',
      );

      final context = gate.buildContext([doc]).text;
      expect(context, contains('No focal liver lesion'));
      expect(context, contains('Liver is unremarkable'));
      expect(context, contains('Stable'));
      for (final leak in [
        'Amber Brown',
        'Sunshine General Hospital',
        'Rose Hill',
      ]) {
        expect(context, isNot(contains(leak)), reason: 'leaked $leak');
      }
    });

    test('cloud table repair payload keeps measurements and removes PII', () {
      const repairText = '''
Patient Name: Peter Doe HbA1c 5.1 %
HbA1c- Glycated Haemoglobin 5.1 %
Estimated Average Glucose (eAG) 99.67 mg/dL
Silverline Hospital Fairview 999206
''';
      final safe = gate.scanText(repairText, title: 'HbA1c Report').text;
      expect(safe, contains('HbA1c'));
      expect(safe, contains('5.1'));
      expect(safe, contains('99.67'));
      expect(safe, isNot(contains('Peter Doe')));
      expect(safe, isNot(contains('Silverline')));
      expect(safe, isNot(contains('Fairview')));
      expect(safe, isNot(contains('999206')));
    });

    test('opaque table-grid cell IDs survive privacy minimization', () {
      const evidence = TableRepairEvidence(
        [],
        cells: [
          TableGridCell(
            id: 'p1_c0',
            text: 'Neutrophils',
            column: TableCellColumn.label,
            rowHint: 0,
          ),
          TableGridCell(
            id: 'p1_c1',
            text: '66',
            column: TableCellColumn.value,
            rowHint: 0,
          ),
          TableGridCell(
            id: 'p1_c2',
            text: '%',
            column: TableCellColumn.unit,
            rowHint: 0,
          ),
          TableGridCell(
            id: 'p1_c3',
            text: '40-75',
            column: TableCellColumn.range,
            rowHint: 0,
          ),
        ],
      );
      final safe = gate.scanText(evidence.gridText, title: 'CBC').text;
      expect(safe, contains('p1_c0'));
      expect(safe, contains('p1_c1'));
      expect(safe, contains('Neutrophils'));
      expect(safe, contains('66'));
    });

    test('table policy preserves uncommon clinical cells but blocks PII', () {
      const grid = '''
TABLE ROW 1 label[p1_c0]=xylometazoline metabolite ratio | value[p1_c1]=7.2 | unit[p1_c2]=qU/mL | range[p1_c3]=2.0-8.0
TABLE ROW 2 label[p1_c4]=Patient Name: Peter Doe | value[p1_c5]=999000111222333
TABLE ROW 3 label[p1_c6]=Meadowlark Hospitals Fairview | value[p1_c7]=999206
''';
      final safe = gate.tableText(grid).text;

      expect(safe, contains('xylometazoline metabolite ratio'));
      expect(safe, contains('7.2'));
      expect(safe, contains('qU/mL'));
      expect(safe, isNot(contains('Peter Doe')));
      expect(safe, isNot(contains('999000111222333')));
      expect(safe, isNot(contains('Meadowlark Hospitals')));
      expect(safe, isNot(contains('Fairview')));
      expect(safe, isNot(contains('999206')));
    });

    test('measures unknown clinical vocabulary without dropping prose', () {
      final doc = CuraDocument(
        id: 'vocab-metric',
        title: 'Ultrasound',
        type: DocumentType.imaging,
        date: DateTime(2025, 4, 2),
        extractedText:
            'Impression: There is no evidence of an uncommonword lesion.',
      );

      final safe = gate.buildContext([doc]);
      expect(safe.text, contains('uncommonword lesion'));
      expect(safe.stats.unknownTokens, greaterThan(0));
      expect(safe.stats.unknownTokenRatio, greaterThan(0));
    });

    test(
      'drops pathology case identifiers and administrative footer prose',
      () {
        const text = '''
Histopathology case number H-802/25
Impression: Necrotizing granulomatous inflammation.
Tissue specimen received at Meadowlark Hospitals, Fairview will be discarded.
''';
        final safe = medicalCloudText(text, title: 'Histopathology Report');
        expect(safe, contains('granulomatous inflammation'));
        expect(safe, isNot(contains('H-802/25')));
        expect(safe, isNot(contains('Meadowlark Hospitals')));
        expect(safe, isNot(contains('Fairview')));
        expect(safe, isNot(contains('discarded')));
      },
    );

    test('deletes a bare name run inside a kept medical sentence', () {
      final doc = CuraDocument(
        id: 'bare-name',
        title: 'Ultrasound',
        type: DocumentType.imaging,
        date: DateTime(2025, 4, 2),
        extractedText:
            'Impression: Mild hepatomegaly, correlate with Grace Quinn '
            'clinical findings.',
      );

      final safe = gate.buildContext([doc]);
      expect(safe.text, contains('Mild hepatomegaly'));
      expect(safe.text, contains('clinical findings'));
      expect(safe.text, isNot(contains('Grace')));
      expect(safe.text, isNot(contains('Quinn')));
      expect(safe.stats.nameRunsDeleted, greaterThan(0));
    });

    test('high unknown-ratio narrative falls back to structured facts', () {
      final doc = CuraDocument(
        id: 'gibberish',
        title: 'Complete blood count',
        type: DocumentType.lab,
        date: DateTime(2025, 4, 2),
        results: const [DocumentResult('Hemoglobin', '13 g/dL')],
        // Block drops, results stay.
        resultsNote:
            'Zqwx frobble wibble snarf blorp quix vunk trundle grelp mibbo.',
      );

      final safe = gate.buildContext([doc]);
      expect(safe.text, contains('Hemoglobin'));
      expect(safe.text, isNot(contains('frobble')));
      expect(safe.stats.narrativeFallbacks, greaterThan(0));
    });

    test('canonical imaging titles carry anatomy and stay distinguishable', () {
      final abdomen = CuraDocument(
        id: 'us1',
        title: 'Amber Brown', // unsafe → canonical fallback
        type: DocumentType.imaging,
        date: DateTime(2025, 5, 1),
        extractedText: 'Ultrasound of the abdomen. Liver normal.',
      );
      final neck = CuraDocument(
        id: 'us2',
        title: 'Grace Young', // unsafe → canonical fallback
        type: DocumentType.imaging,
        date: DateTime(2025, 5, 2),
        extractedText: 'Ultrasound of the neck. Thyroid unremarkable.',
      );

      final inventory = gate.buildInventory([abdomen, neck]).text;
      expect(inventory, contains('Ultrasound — abdomen'));
      expect(inventory, contains('Ultrasound — neck'));
      expect(inventory, isNot(contains('Amber Brown')));
      expect(inventory, isNot(contains('Grace Young')));
    });

    test('modality is chosen by first mention, not list order', () {
      final mri = CuraDocument(
        id: 'mri1',
        title: 'Amber Brown', // unsafe → forces the canonical builder
        type: DocumentType.imaging,
        date: DateTime(2025, 5, 3),
        extractedText: 'MRI brain, compared with the prior CT scan.',
      );
      expect(gate.safeTitle(mri), startsWith('MRI scan'));
    });

    test('a lipid-panel stored title now passes the strict gate', () {
      final doc = CuraDocument(
        id: 'lipid',
        title: 'Lipid profile',
        type: DocumentType.lab,
        date: DateTime(2025, 5, 4),
      );
      expect(gate.safeTitle(doc), 'Lipid profile');
    });

    test('uncommon medical titles pass verbatim (no allowlist needed)', () {
      // No identity here.
      for (final title in [
        'TB Pyrosequencing XDR',
        'C-Reactive Protein',
        'Karyotype 46XY',
        'BRCA1 Mutation Analysis',
        '24-Hour Urine Metanephrines',
      ]) {
        final doc = CuraDocument(
          id: title,
          title: title,
          type: DocumentType.lab,
          date: DateTime(2025, 6, 1),
        );
        expect(gate.safeTitle(doc), title, reason: 'canonicalised "$title"');
      }
    });

    test('identity-bearing titles still fall back to canonical', () {
      final cases = <String, DocumentType>{
        'Amber Brown': DocumentType.imaging, // person name
        'Meadowlark Diagnostics Fairview': DocumentType.lab, // org + place
        'Whitcombe': DocumentType.lab, // lone surname
      };
      cases.forEach((title, type) {
        final doc = CuraDocument(
          id: title,
          title: title,
          type: type,
          date: DateTime(2025, 6, 2),
        );
        expect(gate.safeTitle(doc), isNot(title), reason: 'leaked "$title"');
      });
    });

    test('receipt vendor title is canonicalized, never sent', () {
      // Vendor names count as identity.
      final doc = CuraDocument(
        id: 'fenwick',
        title: 'Fenwick Medical Stores invoice',
        type: DocumentType.receipt,
        date: DateTime(2026, 1, 21),
      );
      expect(gate.safeTitle(doc), isNot(contains('Fenwick')));
      final inventory = gate.buildInventory([doc]);
      expect(inventory.text, isNot(contains('Fenwick')));
      expect(inventory.stats.titlesReplaced, 1);
    });

    test('receipt title with a place name is still canonicalized', () {
      final doc = CuraDocument(
        id: 'meadowlark-place',
        title: 'Meadowlark Pharmacy Fairview',
        type: DocumentType.receipt,
        date: DateTime(2025, 6, 2),
      );
      expect(gate.safeTitle(doc), 'Receipt');
    });

    test('receipt title carrying a hard identifier is canonicalized', () {
      final doc = CuraDocument(
        id: 'phone-title',
        title: 'Fenwick Medical Stores 9876543210',
        type: DocumentType.receipt,
        date: DateTime(2025, 6, 2),
      );
      expect(gate.safeTitle(doc), 'Receipt');
    });

    test(
      'inventory line carries a scrubbed findings hint for topical queries',
      () {
        final histo = CuraDocument(
          id: 'histo',
          title: 'Histopathology',
          type: DocumentType.lab,
          date: DateTime(2025, 2, 19),
          resultsNote:
              'Impression: Necrotizing granulomatous inflammation of likely '
              "Koch's etiology.",
        );
        final xpert = CuraDocument(
          id: 'xpert',
          title: 'Xpert MTB/RIF',
          type: DocumentType.lab,
          date: DateTime(2025, 2, 18),
          results: const [DocumentResult('MTB Complex', 'Detected')],
        );

        final inventory = gate.buildInventory([histo, xpert]).text;
        // Topic comes from the hint.
        expect(inventory, contains('granulomatous inflammation'));
        expect(inventory, contains('MTB Complex: Detected'));
      },
    );

    test('a lab hint carries its values, not its result count', () {
      final doc = CuraDocument(
        id: 'afb',
        title: 'AFB Culture',
        type: DocumentType.lab,
        date: DateTime(2024, 9, 3),
        results: const [
          DocumentResult('Acid Fast Stain', 'No AFB seen'),
          DocumentResult('AFB Culture', 'No Mycobacterium species isolated'),
        ],
        // Keep the note, not the row count.
        resultsNote: '2 results',
      );

      final inventory = gate.buildInventory([doc]).text;
      expect(inventory, contains('Acid Fast Stain: No AFB seen'));
      expect(inventory, contains('No Mycobacterium species isolated'));
      expect(inventory, isNot(contains('2 results')));
    });

    test('a report with no rows still shows its note', () {
      final doc = CuraDocument(
        id: 'histo-note',
        title: 'Histopathology',
        type: DocumentType.lab,
        date: DateTime(2020, 2, 19),
        resultsNote: 'Impression: Inflamed sinus tract.',
      );
      expect(gate.buildInventory([doc]).text, contains('Inflamed sinus tract'));
    });

    test('inventory findings hint still drops embedded identifiers', () {
      final doc = CuraDocument(
        id: 'note-pii',
        title: 'Ultrasound',
        type: DocumentType.imaging,
        date: DateTime(2025, 4, 2),
        resultsNote:
            'Impression: No focal lesion. Reviewed by Dr Amber Brown, MRN LH-1234.',
      );

      final inventory = gate.buildInventory([doc]).text;
      expect(inventory, contains('No focal lesion'));
      expect(inventory, isNot(contains('Amber Brown')));
      expect(inventory, isNot(contains('LH-1234')));
    });

    test(
      'assistant history keeps benign prose, drops names and identifiers',
      () {
        final msg = gate.assistantMessage(
          'Your haemoglobin is 13 g/dL, within range.\n'
          "Ask your doctor about the hospital's follow-up plan.\n"
          'This was reviewed with Grace Quinn.\n'
          'Your MRN is LH-99215.',
        );
        expect(msg.role, 'assistant');
        // Benign prose survives.
        expect(msg.content, contains('haemoglobin is 13'));
        expect(msg.content, contains('Ask your doctor'));
        // Names and IDs are removed.
        expect(msg.content, isNot(contains('Grace')));
        expect(msg.content, isNot(contains('Quinn')));
        expect(msg.content, isNot(contains('LH-99215')));
      },
    );
  });

  group('deleteNameRuns', () {
    test('removes multi-token names, keeps single unknown terms', () {
      expect(
        deleteNameRuns('Reviewed findings with Anne-Marie D’Souza today').text,
        isNot(contains('Anne-Marie')),
      );
      expect(
        deleteNameRuns('R. Quinn examined the patient').text,
        isNot(contains('Quinn')),
      );
      // Single title-case tokens stay.
      expect(
        deleteNameRuns('Hepatitis B surface antigen').text,
        contains('Hepatitis B surface antigen'),
      );
    });

    test('a first-person contraction never starts a name run', () {
      // Keep contractions out of name runs.
      expect(
        deleteNameRuns("I'm Cura, your medical assistant").text,
        "I'm Cura, your medical assistant",
      );
      expect(deleteNameRuns("I've reviewed Hemoglobin").text, contains("I've"));
      // Real name runs still go.
      expect(deleteNameRuns("I'm Grace Quinn").text, isNot(contains('Quinn')));
    });

    test('leaves Title-case clinical headings untouched', () {
      for (final heading in [
        'Complete Blood Count',
        'Right Supraclavicular Region',
        'Chronic Cholecystitis',
      ]) {
        expect(
          deleteNameRuns(heading).text,
          heading,
          reason: 'altered "$heading"',
        );
      }
    });

    test('deletes ALL-CAPS name runs and keeps clinical caps', () {
      const line = 'GRACE QUINN HEMOGLOBIN 13 G/DL';
      final out = deleteNameRuns(line);
      expect(out.text, isNot(contains('GRACE')));
      expect(out.text, isNot(contains('QUINN')));
      expect(out.text, contains('HEMOGLOBIN'));
      expect(out.runs, 1);
    });

    test('leaves ALL-CAPS clinical phrases alone', () {
      for (final phrase in [
        'MTB COMPLEX NOT DETECTED',
        'COMPLETE BLOOD COUNT',
        'LIVER FUNCTION TEST',
        'HEMOGLOBIN 13 G/DL',
      ]) {
        expect(deleteNameRuns(phrase).text, phrase, reason: 'altered $phrase');
      }
    });
  });

  // ALL-CAPS identity test.
  group('ALL-CAPS identity never reaches the cloud', () {
    const gate = CloudPrivacyGate();
    const patient = 'DOE JANE MARIE';
    const facility = 'LAKEVIEW HOSPITAL & HEART INSTITUTE';

    // OCR input.
    const ocr =
        '$facility\n'
        'SECTOR 27, FAIRVIEW 999301\n'
        'Patient Name : $patient\n'
        'Age / Sex : 34 Y / F\n'
        'Findings: Alive fetus seen with fetal heart rate 166 bpm.\n'
        'Impression: Fetal anatomy appears normal.';

    void expectClean(String context, {required List<String> keep}) {
      for (final leak in [
        patient,
        facility,
        'DOE',
        'LAKEVIEW',
        'Doe Jane Marie',
        'Lakeview Hospital',
      ]) {
        expect(context, isNot(contains(leak)), reason: 'leaked "$leak"');
      }
      for (final wanted in keep) {
        expect(context, contains(wanted), reason: 'lost "$wanted"');
      }
    }

    test('stored summary with letterhead and patient block', () {
      final doc = CuraDocument(
        id: 'trimester',
        title: 'First Trimester Screening',
        type: DocumentType.imaging,
        date: DateTime(2026, 7, 10),
        resultsNote:
            'Findings: $facility\n'
            '$patient\n'
            'Alive fetus seen with fetal heart rate 166 bpm.\n'
            'Impression: Fetal anatomy appears normal.',
        extractedText: ocr,
      );

      expectClean(
        gate.buildContext([doc]).text,
        keep: ['fetal heart rate', 'Fetal anatomy appears normal'],
      );
    });

    test('identity merged into Impression', () {
      final doc = CuraDocument(
        id: 'merged',
        title: 'First Trimester Screening',
        type: DocumentType.imaging,
        date: DateTime(2026, 7, 10),
        resultsNote:
            'Impression: $facility Fetal anatomy appears normal. $patient',
        extractedText: ocr,
      );

      expectClean(
        gate.buildContext([doc]).text,
        keep: ['Fetal anatomy appears normal'],
      );
    });

    test('same identity in Title Case', () {
      final doc = CuraDocument(
        id: 'titlecase',
        title: 'First Trimester Screening',
        type: DocumentType.imaging,
        date: DateTime(2026, 7, 10),
        resultsNote:
            'Findings: Lakeview Hospital & Heart Institute\n'
            'Doe Jane Marie\n'
            'Alive fetus seen with fetal heart rate 166 bpm.',
        extractedText: ocr,
      );

      expectClean(gate.buildContext([doc]).text, keep: ['fetal heart rate']);
    });

    test('ALL-CAPS stored title is replaced', () {
      final doc = CuraDocument(
        id: 'captitle',
        title: patient,
        type: DocumentType.imaging,
        date: DateTime(2026, 7, 10),
        extractedText: ocr,
      );

      final safe = gate.buildContext([doc]);
      expectClean(safe.text, keep: const []);
      expect(safe.stats.titlesReplaced, 1);
    });

    test('identity results rows are dropped', () {
      final doc = CuraDocument(
        id: 'rows',
        title: 'First Trimester Screening',
        type: DocumentType.imaging,
        date: DateTime(2026, 7, 10),
        results: const [
          DocumentResult('Patient', patient),
          DocumentResult('FHR', '166 bpm'),
        ],
      );

      expectClean(gate.buildContext([doc]).text, keep: ['166 bpm']);
    });

    test('inventory hint keeps no identity', () {
      final doc = CuraDocument(
        id: 'inv',
        title: 'First Trimester Screening',
        type: DocumentType.imaging,
        date: DateTime(2026, 7, 10),
        resultsNote: 'Findings: $facility $patient Alive fetus seen.',
        extractedText: ocr,
      );

      expectClean(gate.buildInventory([doc]).text, keep: const []);
    });
  });

  // Demographic rows test.
  group('demographic results rows', () {
    const gate = CloudPrivacyGate();

    CuraDocument geneticScan() => CuraDocument(
      id: 'genetic',
      title: 'Ultrasound PREGNANCY 1TRIM (GENETIC SCAN)',
      type: DocumentType.imaging,
      date: DateTime(2026, 7, 3),
      extractedText:
          'LAKEVIEW HOSPITAL & HEART INSTITUTE\n'
          'Patient Name : DOE JANE MARIE\n'
          'Findings: Nuchal translucency 3.30 mm.',
      results: const [
        DocumentResult('Patient', 'Doe Jane Marie'),
        DocumentResult('Name', 'DOE JANE MARIE'),
        DocumentResult('Date of birth', '01/01/1990'),
        DocumentResult('DOB', '01-Jan-1990'),
        DocumentResult('Address', 'Sector 27, Fairview'),
        DocumentResult('UHID', 'LH2026071012'),
        DocumentResult('Age', '34 years'),
        DocumentResult('Parity', '0'),
        DocumentResult('Smoking', 'No'),
        DocumentResult('Nuchal translucency', '3.30', unit: 'mm'),
        DocumentResult('Free beta-hCG', '0.470', unit: 'MoM'),
        DocumentResult('PAPP-A', '0.510', unit: 'MoM'),
      ],
    );

    test('identity rows are dropped, clinical rows survive', () {
      final context = gate.buildContext([geneticScan()]).text;

      for (final leak in [
        'Doe',
        'DOE',
        'Jane',
        'Marie',
        '01/01/1990',
        '01-Jan-1990',
        '1990',
        'Fairview',
        'LH2026071012',
        'Lakeview',
        'LAKEVIEW',
      ]) {
        expect(context, isNot(contains(leak)), reason: 'leaked "$leak"');
      }

      // Keep the measurements.
      for (final wanted in ['3.30', '0.470', '0.510']) {
        expect(context, contains(wanted), reason: 'lost "$wanted"');
      }
      // Keep age and sex.
      expect(context, contains('34 years'));
    });

    test('inventory hint never carries a demographic row', () {
      final inventory = gate.buildInventory([geneticScan()]).text;
      for (final leak in ['Doe', 'DOE', '01/01/1990', 'LH2026071012']) {
        expect(inventory, isNot(contains(leak)), reason: 'leaked "$leak"');
      }
    });
  });

  // OCR-mangled text test.
  group('OCR-mangled letterhead never reaches the cloud', () {
    const gate = CloudPrivacyGate();

    const scannedPage =
        'Findings:\n'
        'Nuchal translucency (NT) 3.30 mm\n'
        'Crown-rump length (CRL) 67.7 mm\n'
        'Springvale\n'
        'sprIngVales Admn Date: 03 Jul 2026\n'
        'General Speciality\n'
        'Lakeview Hospital & Heart Institute\n'
        'Free B-hcG equivalent to 0.470 MoM\n'
        'Page 1 of3 printed on 10 July 2026. Janc (31892) examined on 10 July 2026.\n'
        'Janc Examination date: 10 July 2026\n'
        'Date of blrth: 01 January 1990\n'
        'ki H-33, : 0999-111 11 11, 222 22 22 spaclally FaLrview 999301\n';

    test('date alone does not qualify a line', () {
      final kept = keepMedicalLines(scannedPage, title: 'FIRST TRIMESTER');
      expect(kept, isNot(contains('blrth')));
      expect(kept, isNot(contains('1990')));
      expect(kept, isNot(contains('Examination date')));
    });

    test('title-case fragments do not ride a section', () {
      final kept = keepMedicalLines(scannedPage, title: 'FIRST TRIMESTER');
      expect(kept, isNot(contains('Springvale')));
      expect(kept, isNot(contains('sprIngVales')));
      // One hit is not enough.
      expect(kept, isNot(contains('General Speciality')));
      expect(kept, isNot(contains('Lakeview Hospital & Heart Institute')));
    });

    test('clinical title-case labels survive', () {
      final kept = keepMedicalLines(
        'Findings:\n'
        'Placenta Posterior\n'
        'Ductus Venosus P! 1.30\n'
        'Maternal Serum Biochemistry\n'
        'General Speciality\n',
        title: 'FIRST TRIMESTER',
      );
      expect(kept, contains('Placenta Posterior'));
      expect(kept, contains('Ductus Venosus'));
      expect(kept, contains('Maternal Serum Biochemistry'));
      expect(kept, isNot(contains('General Speciality')));
    });

    test('page and print footers are dropped', () {
      final kept = keepMedicalLines(scannedPage, title: 'FIRST TRIMESTER');
      expect(kept, isNot(contains('Janc')));
      expect(kept, isNot(contains('31892')));
    });

    test('measurements survive all of it', () {
      final kept = keepMedicalLines(scannedPage, title: 'FIRST TRIMESTER');
      for (final wanted in ['3.30', '67.7', '0.470']) {
        expect(kept, contains(wanted), reason: 'lost "$wanted"');
      }
    });

    test('raw page text stays out when note covers it', () {
      final doc = CuraDocument(
        id: 'screening',
        title: 'FIRST TRIMESTER SCREENING',
        type: DocumentType.imaging,
        date: DateTime(2026, 7, 10),
        extractedText: scannedPage,
        resultsNote: 'Nuchal translucency (NT) 3.30 mm',
      );
      final context = gate.buildContext([doc]).text;
      expect(context, contains('3.30'));
      expect(context, isNot(contains('Text:')));
      for (final leak in ['Janc', 'blrth', '1990', 'FaLrview', '0999']) {
        expect(context, isNot(contains(leak)), reason: 'leaked "$leak"');
      }
    });
  });
}
