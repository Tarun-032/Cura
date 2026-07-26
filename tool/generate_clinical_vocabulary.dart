// Dev-time generator for `lib/features/ai/remote/clinical_vocabulary.g.dart`.
// Never runs inside the app: the app only imports the emitted `.g.dart`.
//
// Run from the repo root, after downloading the two sources:
//   dart run tool/generate_clinical_vocabulary.dart <sources_dir>
// where <sources_dir> contains:
//   icd10cm_codes_2026.txt          (CMS ICD-10-CM FY2026 code descriptions)
//   rrf/RXNCONSO.RRF                (NLM RxNorm Current Prescribable Content)
//
// Attribution, recorded in the generated header:
//   ICD-10-CM: U.S. CMS/CDC, public domain.
//   RxNorm Current Prescribable Content: U.S. NLM, license-free
//     (https://www.nlm.nih.gov/research/umls/rxnorm/).
//
// The token set protects clinical prose from name-run deletion, so person and
// place names must never be in it. Eponymous surnames run all through ICD
// descriptions and are subtracted via [_nameLikeStoplist].

import 'dart:io';

/// Drop generated tokens shorter than this. Short medical abbreviations that
/// matter (hb, ct, iu, dl, …) live in the hand-curated set, not here, so a low
/// cut-off only removes noise ("ii", "iv" numerals, stray letters).
const _minTokenLength = 3;

/// RxNorm term types worth harvesting: ingredients, brand names and the
/// human-readable prescribable names. Dose/form clutter (SCD/SBD strings) is
/// skipped — the ingredient tokens inside them are already captured via IN/PIN.
const _rxTermTypes = {'IN', 'PIN', 'MIN', 'BN', 'PSN', 'SY'};

void main(List<String> args) {
  final sourcesDir = args.isNotEmpty ? args[0] : 'tool/vocab_sources';
  final icdFile = File('$sourcesDir/icd10cm_codes_2026.txt');
  final rxFile = File('$sourcesDir/rrf/RXNCONSO.RRF');
  if (!icdFile.existsSync() || !rxFile.existsSync()) {
    stderr.writeln('Missing sources under "$sourcesDir".');
    stderr.writeln('  expected: icd10cm_codes_2026.txt and rrf/RXNCONSO.RRF');
    exitCode = 2;
    return;
  }

  final tokens = <String>{};

  // ── ICD-10-CM: "<code><spaces><description>" per line ────────────────────
  var icdLines = 0;
  for (final line in icdFile.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    icdLines++;
    // First whitespace run separates the code from its description.
    final space = line.indexOf(RegExp(r'\s'));
    final description = space < 0 ? '' : line.substring(space);
    _tokenize(description, tokens);
  }

  // ── RxNorm RXNCONSO.RRF: pipe-delimited, LAT=field 1, TTY=field 12,
  //    STR=field 14 (0-based) ────────────────────────────────────────────────
  var rxKept = 0;
  for (final line in rxFile.readAsLinesSync()) {
    if (line.isEmpty) continue;
    final f = line.split('|');
    if (f.length < 15) continue;
    if (f[1] != 'ENG') continue;
    if (!_rxTermTypes.contains(f[12])) continue;
    rxKept++;
    _tokenize(f[14], tokens);
  }

  // ── Cura's own scan/router vocabulary (abbreviations ICD/RxNorm lack) ──────
  for (final t in _appSeedVocabulary) {
    _tokenize(t, tokens);
  }

  // ── Prune name-like / place tokens so they cannot be treated as known ──────
  final review = <String, List<String>>{
    'names/eponyms': [],
    'demonyms/geography': [],
    'redactor-collisions': [],
  };
  final pruned = <String>{};
  for (final token in tokens) {
    if (_nameLikeStoplist.contains(token)) {
      review['names/eponyms']!.add(token);
      continue;
    }
    if (_geographyStoplist.contains(token)) {
      review['demonyms/geography']!.add(token);
      continue;
    }
    if (_redactorCollisions.contains(token)) {
      review['redactor-collisions']!.add(token);
      continue;
    }
    pruned.add(token);
  }

  final sorted = pruned.toList()..sort();

  // ── Emit the committed asset ──────────────────────────────────────────────
  final out = StringBuffer()
    ..writeln('// GENERATED FILE — DO NOT EDIT BY HAND.')
    ..writeln('// Regenerate with: dart run tool/generate_clinical_vocabulary.dart')
    ..writeln('//')
    ..writeln('// Sources:')
    ..writeln('//   ICD-10-CM FY2026 code descriptions — U.S. CMS/CDC (public domain).')
    ..writeln('//   RxNorm Current Prescribable Content — U.S. NLM (license-free).')
    ..writeln('// Person names, place names and demonyms are deliberately excluded;')
    ..writeln('// see tool/generate_clinical_vocabulary.dart for the pruning rules.')
    ..writeln('//')
    ..writeln('// Tokens: ${sorted.length}. Pruned: names=${review['names/eponyms']!.length} '
        'geo=${review['demonyms/geography']!.length} '
        'redactor=${review['redactor-collisions']!.length}.')
    ..writeln('// dart format off')
    ..writeln('library;')
    ..writeln()
    ..writeln('const kGeneratedClinicalVocabulary = <String>{');
  const perLine = 8;
  for (var i = 0; i < sorted.length; i += perLine) {
    final chunk = sorted.skip(i).take(perLine).map((t) => "'$t'").join(', ');
    out.writeln('  $chunk,');
  }
  out.writeln('};');

  File('lib/features/ai/remote/clinical_vocabulary.g.dart')
      .writeAsStringSync(out.toString());

  // ── Emit the human review report ──────────────────────────────────────────
  final report = StringBuffer()
    ..writeln('Clinical vocabulary generation review')
    ..writeln('=====================================')
    ..writeln('ICD-10-CM description lines: $icdLines')
    ..writeln('RxNorm terms harvested: $rxKept')
    ..writeln('Final vocabulary tokens: ${sorted.length}')
    ..writeln();
  for (final entry in review.entries) {
    final list = entry.value..sort();
    report
      ..writeln('Pruned — ${entry.key} (${list.length}):')
      ..writeln(list.join(', '))
      ..writeln();
  }
  File('tool/vocab_review.txt').writeAsStringSync(report.toString());

  stdout.writeln('Wrote lib/features/ai/remote/clinical_vocabulary.g.dart '
      '(${sorted.length} tokens) and tool/vocab_review.txt.');
}

/// Lowercase every alphabetic run of [_minTokenLength]+ chars into [into].
void _tokenize(String text, Set<String> into) {
  for (final m in RegExp(r'[a-zA-Z]+').allMatches(text.toLowerCase())) {
    final t = m.group(0)!;
    if (t.length >= _minTokenLength) into.add(t);
  }
}

/// Cura's own scan/router vocabulary — abbreviations and panel names that the
/// medical corpora do not spell out. Mirrors query_router `_aliasGroups`,
/// retrieval `_imagingModalities`, scan_service `_knownPanels`/`_knownProcedures`.
const _appSeedVocabulary = <String>[
  'hemoglobin', 'haemoglobin', 'hgb', 'hba1c', 'glycated', 'glucose', 'fbs',
  'leukocyte', 'platelet', 'cholesterol', 'triglyceride', 'creatinine', 'urea',
  'bun', 'thyroid', 'tsh', 'bilirubin', 'albumin', 'globulin', 'potassium',
  'sodium', 'chloride', 'calcium', 'esr', 'alkaline', 'phosphatase',
  'magnetic', 'resonance', 'computed', 'tomography', 'ultrasound', 'sonography',
  'sonograph', 'doppler', 'radiograph', 'mammogram', 'mammograph',
  'echocardiogram', 'haemogram', 'hemogram', 'lipid', 'electrolyte', 'vitamin',
  'histopathology', 'biopsy', 'cytology', 'culture', 'haematology',
  'biochemistry', 'microbiology', 'serology', 'urinalysis', 'coagulation',
  'prothrombin', 'ferritin', 'reticulocyte', 'eosinophil', 'neutrophil',
  'lymphocyte', 'monocyte', 'basophil', 'haematocrit', 'hematocrit',
];

/// Eponymous surnames and personal names recurring across ICD-10-CM
/// descriptions, subtracted so they never count as known clinical tokens. Broad
/// on purpose; the only cost is a lone eponym counting as one unknown token.
const _nameLikeStoplist = <String>{
  // Eponymous conditions (surname component).
  'addison', 'albright', 'alport', 'alzheimer', 'arnold', 'asherman', 'barre',
  'barrett', 'bartter', 'basedow', 'becker', 'behcet', 'bell', 'berger',
  'boerhaave', 'bowen', 'bright', 'brown', 'budd', 'buerger', 'burkitt',
  'charcot', 'chiari', 'colles', 'conn', 'creutzfeldt', 'crigler', 'crohn',
  'cushing', 'down', 'dressler', 'dubin', 'duchenne', 'dupuytren', 'ebstein',
  'ehlers', 'ellison', 'erb', 'ewing', 'fanconi', 'fallot', 'gaucher',
  'gilbert', 'goodpasture', 'graves', 'guillain', 'hashimoto', 'hirschsprung',
  'hodgkin', 'horner', 'huntington', 'jakob', 'jeghers', 'kaposi', 'kawasaki',
  'klinefelter', 'klumpke', 'legg', 'lyme', 'mallory', 'marfan', 'meckel',
  'meigs', 'meniere', 'najjar', 'niemann', 'osgood', 'paget', 'parkinson',
  'peutz', 'pick', 'plummer', 'pott', 'raynaud', 'reed', 'reye', 'riedel',
  'schlatter', 'sequard', 'sheehan', 'sjogren', 'sternberg', 'still',
  'takayasu', 'tay', 'sachs', 'turner', 'wallenberg', 'wegener', 'whipple',
  'wilms', 'wilson', 'young', 'zollinger',
  // Common given names / surnames that also surface in descriptions or that a
  // patient block would carry. (Names already listed above as eponyms — brown,
  // young, bell, reed — are intentionally not repeated.)
  'amber', 'grace', 'rose', 'hill', 'may', 'june', 'mark', 'bill', 'grant',
  'noble', 'ray', 'earl', 'guy',
};

/// Demonyms and geographic tokens seen in ICD descriptions (e.g. "Japanese
/// encephalitis", "Mediterranean fever"). Pruned so a place on a report cannot
/// become a known token.
const _geographyStoplist = <String>{
  'japanese', 'mediterranean', 'american', 'african', 'asian', 'european',
  'indian', 'mexican', 'brazilian', 'chinese', 'egyptian', 'german', 'french',
  'spanish', 'russian', 'italian', 'oriental', 'western', 'eastern', 'northern',
  'southern', 'california', 'colorado', 'rocky', 'marburg', 'ebola', 'nile',
  'ross', 'zika', 'lassa', 'omsk', 'kyasanur', 'chikungunya', 'murray',
  'venezuelan', 'bolivian', 'argentine', 'crimean', 'congo', 'hanta',
};

/// Tokens that Cura's redactor already treats as identity/address cues
/// (pii_redactor `_dropWord` / `_place`). Excluded so the vocabulary and the
/// redactor never disagree about the same word.
const _redactorCollisions = <String>{
  'name', 'address', 'phone', 'mobile', 'email', 'contact', 'father', 'mother',
  'husband', 'wife', 'spouse', 'guardian', 'nationality', 'religion',
  'occupation', 'hospital', 'clinic', 'centre', 'center', 'institute',
  'college', 'university', 'road', 'street', 'lane', 'nagar', 'colony',
  'sector', 'district', 'village', 'city', 'town', 'mumbai', 'delhi', 'chennai',
  'kolkata', 'bangalore', 'hyderabad', 'pune',
};
