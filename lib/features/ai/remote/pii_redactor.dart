/// Removes personal and identifying details from OCR text **before it is sent to
/// a cloud model**. On-device inference never calls this, so it is a cloud-only
/// barrier.
///
/// Aggressive by design: patient identity, contact details, record/ID numbers,
/// the hospital name and the full postal address are stripped, keeping only
/// medical content. A heuristic barrier, **not a guarantee**.
///
/// Pure and line-based, so it is unit-testable with no I/O. Over-redaction is
/// safe: `parseScanExtraction` validates values against the *unredacted* OCR.
library;

import '../../scan/receipt_parser.dart' show hasMoneyToken;
import 'clinical_vocabulary.dart';

// ── Inline scrubs (applied to every kept line) ──────────────────────────────
final _email = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
final _url = RegExp(r'(https?://|www\.)\S+', caseSensitive: false);
// Phone-like runs, kept specific so numeric lab ranges ("4000-11000") aren't
// mistaken for phone numbers: an international +cc number, a bare 10-digit run,
// or the common 5-5 / 3-3-4 groupings.
final _phone = RegExp(
  r'\+\d[\d\s\-]{7,}\d'
  r'|(?<!\d)\d{10}(?!\d)'
  r'|(?<!\d)\d{5}[\s\-]\d{5}(?!\d)'
  r'|(?<!\d)\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4}(?!\d)',
);
// Long ID-like numbers (accession/order/barcode). Lab values are <=6 digits
// (a platelet count is ~150000), so an 8+ digit run is an identifier, not a
// reading — scrub it wherever it appears.
final _longId = RegExp(r'\b\d{8,}\b');
// Identifier labels followed by the value. Unlike [_longId], this catches short
// alphanumeric medical IDs too; a label makes the intent unambiguous.
// Split by strength. An unmistakable identifier word may carry its value with no
// separator; a weak word that also occurs in ordinary billing prose ("First
// Visit", "Invoice") needs an explicit no/number/id token or a separator, or it
// eats the line item next to it.
final _labeledIdValue = RegExp(
  r'\b(?:(?:mrn|uhid|passport|ssn|social\s*security|npi|abha|aadhaar|aadhar)'
  r'\s*(?:no\.?|number|id|#)?'
  r'|(?:patient\s*id|registration|accession|case|visit|encounter|invoice|'
  r'account|insurance|policy|member|subscriber|beneficiary|medicare|medicaid|'
  r'health\s*plan|provider|order|specimen|sample)\s*(?:no\.?|number|id|#))\s*'
  r'[:=#\-]?\s*[a-z0-9][a-z0-9/\-]{2,}',
  caseSensitive: false,
);

/// Postal addresses that do not carry an explicit `Address:` label. The street
/// number + suffix pairing keeps ordinary measurements and reference ranges out.
final _postalAddress = RegExp(
  r'\b(?:p\.?\s*o\.?\s*box\s+\d+|\d{1,6}\s+[A-Za-z0-9.#\- ]{2,40}\s+'
  r'(?:street|st\.?|road|rd\.?|avenue|ave\.?|boulevard|blvd\.?|lane|ln\.?|'
  r'drive|dr\.?|court|ct\.?|terrace|way|highway|hwy\.?))\b'
  r'(?:[^\n;]{0,50}\b\d{5}(?:-\d{4})?\b)?',
  caseSensitive: false,
);

final _postalCode = RegExp(
  r'\b(?:zip|postal\s*code|postcode|pincode|pin)\s*[:#=\-]?\s*'
  r'[A-Z0-9][A-Z0-9 -]{2,9}\b',
  caseSensitive: false,
);

/// Provider labels are kept separate from general identity fields so clinical
/// uses of "provider" or "doctor" are not removed without a following value.
// Case matters on the name: `caseSensitive: false` would let `[A-Z]` match a
// lowercase word, so "doctor about the follow-up" would read as a clinician
// name. The label is spelled in both cases instead.
final _providerField = RegExp(
  r'\b(?:[Oo]rdering|ORDERING|[Rr]eferring|REFERRING|[Aa]ttending|ATTENDING|'
  r'[Tt]reating|TREATING|[Cc]onsulting|CONSULTING|[Rr]eporting|REPORTING|'
  r'[Ii]nterpreting|INTERPRETING)?\s*'
  r'(?:[Dd]octor|DOCTOR|[Pp]hysician|PHYSICIAN|[Pp]rovider|PROVIDER|'
  r'[Cc]linician|CLINICIAN|[Cc]onsultant|CONSULTANT|[Rr]adiologist|RADIOLOGIST|'
  r'[Pp]athologist|PATHOLOGIST|[Pp]rescriber|PRESCRIBER)'
  r"\s*(?:[Nn]ame|NAME)?\s*[:#=\-]\s*"
  r"(?:[Dd][Rr]\.?\s*)?[A-Z][A-Za-z'’-]+(?:\s+[A-Z][A-Za-z'’-]+){0,3}",
);

final _dobValue = RegExp(
  r'\b(?:d\.?o\.?b\.?|date\s*of\s*birth|birth\s*date)\s*'
  r'(?:is\s*)?[:#=\-]?\s*\d{1,2}[./\-]\d{1,2}[./\-]\d{2,4}',
  caseSensitive: false,
);

// Reviewer/provider tails occasionally share an OCR line with an Impression.
// Delete the tail rather than the whole medical sentence.
final _providerTail = RegExp(
  r'\b(?:reviewed|reported|verified|prepared|signed|interpreted|authorized)\s+by\b.*$',
  caseSensitive: false,
);

// Inline identity fields can ride after valid medical prose when OCR merges
// columns. Stop at sentence punctuation so the clinical sentence survives.
final _inlineIdentityField = RegExp(
  r'\b(?:patient\s*(?:name|id|number|no\.?)|name\s+of\s+(?:the\s+)?patient|'
  r'doctor|consultant|physician|provider|clinician|prescriber|'
  r'referring\s+doctor|ordering\s+provider)\s*[:=#\-]\s*'
  r'[^,;.!?\n]*[,;]?',
  caseSensitive: false,
);

// Proper-name phrase ending in an unmistakable organisation kind. This catches
// names composed only of dictionary words ("Sunshine General Hospital") without
// requiring an impossible global hospital list.
// Case stays significant on the prefix so "transferred to hospital" is never an
// organisation, but the kind itself is matched in caps too: reports letterhead
// in ALL-CAPS ("LAKEVIEW HOSPITAL & HEART INSTITUTE").
final _inlineOrganisation = RegExp(
  r"\b(?:(?:[A-Z][A-Za-z'’-]*|&)\s+){1,6}"
  r'(?:[Hh]ospitals?|HOSPITALS?|[Cc]linics?|CLINICS?|'
  r'[Ii]nstitutes?|INSTITUTES?|[Ll]aborator(?:y|ies)|LABORATOR(?:Y|IES)|'
  r'[Dd]iagnostics?|DIAGNOSTICS?|[Pp]olyclinic|POLYCLINIC|'
  r'[Hh]ealth\s+(?:[Ss]ystem|[Cc]are|[Cc]entre|[Cc]enter)|'
  r'HEALTH\s+(?:SYSTEM|CARE|CENTRE|CENTER)|'
  r'[Mm]edical\s+(?:[Gg]roup|[Pp]ractice|[Cc]enter)|'
  r'MEDICAL\s+(?:GROUP|PRACTICE|CENTER)|[Pp]harmac(?:y|ies)|PHARMAC(?:Y|IES)|'
  r'[Ii]maging\s+(?:[Cc]entre|[Cc]enter|[Cc]linic|[Ll]ab)|'
  r'IMAGING\s+(?:CENTRE|CENTER|CLINIC|LAB)|'
  r'[Mm]edical\s+[Cc]entre|MEDICAL\s+CENTRE)\b',
);

final _inlineLocationField = RegExp(
  r'\b(?:address|location|locality|city|district|state|country|pincode|postal\s*code|zip)\s*'
  r'[:=#\-]\s*[^,;.!?\n]*[,;]?',
  caseSensitive: false,
);

// ── Whole-word cues (both boundaries: `\b…\b`) ──────────────────────────────
// Bounded on both sides so "pan"/"tel" don't match inside "pancreas"/"platelet".
// A line carrying any of these as a word is identity text and is dropped whole.
final _dropWord = RegExp(
  r'\b(?:'
  // Person / relations. Bare "patient" is *not* here — discharge prose says
  // "Patient was advised…"; identity labels use [_patientLabel] instead.
  r'name|guardian|spouse|husband|wife|father|mother|attendant|'
  r'relative|nationality|religion|occupation|'
  // Contact.
  r'address|phone|mobile|email|e-?mail|contact|fax|website|'
  // Record / identity numbers (as words).
  r'uhid|mrn|registration|barcode|passport|aadhaar|aadhar|pan|episode|'
  r'encounter|invoice|gst|crn|uln|'
  // Referrers / staff.
  r'consultant|physician|referring|technician|signature|signed|dr|'
  // Organisation words.
  r'centre|center|institute|college|science|sciences|society|foundation|'
  r'university|polyclinic|nursing|pvt|ltd|llp|'
  // Address / geography.
  r'address|road|street|lane|marg|cross|sector|nagar|colony|layout|plot|'
  r'floor|opp|opposite|behind|avenue|boulevard|highway|phase|tower|'
  r'apartment|building|chowk|gali|vihar|enclave|extension|township|taluka|'
  r'tehsil|district|village|city|town|pincode|postal|india|bharat|landmark|'
  r'locality|zip'
  r')\b',
  caseSensitive: false,
);

/// Patient *identity* labels only (`Patient Name:`, `Patient:`, …). Narrative
/// "Patient was discharged…" must survive for discharge summaries.
final _patientLabel = RegExp(
  r'\bpatient\s*(?:name|id|no\.?|details?)?\s*[:/\-]'
  r'|\bpatient\s*name\b'
  r'|\bname\s*of\s*(?:the\s*)?patient\b',
  caseSensitive: false,
);

/// Clinical uses of "hospital" that must not be whole-line-dropped as org stems
/// (Hospital course, discharged, transferred to hospital, …).
final _hospitalClinical = RegExp(
  r'\bhospital\s*course\b|\bdischarged?\b|\badmission\b|'
  r'\b(?:in|to)\s*(?:the\s*)?hospital\b',
  caseSensitive: false,
);

/// Organisation-name stems, leading boundary only so suffixes match
/// (laborator→laboratory). Bare "imaging" is not a stem, since clinical notes
/// say "imaging findings"; only "Imaging Centre" / "Imaging Lab" are dropped.
final _dropStem = RegExp(
  r'\b(?:hospital|clinic|laborator|diagnostic|patholog|healthcare|radiolog|'
  r'imaging\s*(?:cent|clinic|lab|services|dept|department)|medical\s*cent)',
  caseSensitive: false,
);

/// Patient field labels like `Age: 45` / `Sex / Gender:` / `DOB -`. Bound left
/// so "dosage:" doesn't match, and anchored by the trailing separator so a "Sex
/// Hormone Binding Globulin" result line survives.
final _dropField = RegExp(
  r'\b(?:age|sex|gender|marital|d\.?o\.?b|date\s*of\s*birth)\s*[:/\-]'
  r'|\b[sdwcb]/o\b', // s/o, d/o, w/o, c/o, b/o
  caseSensitive: false,
);

/// A record/registration label followed by `No`/`Id`/`#`. The suffix requirement
/// keeps result rows safe: "SAMPLE : TISSUE" stays, "Sample No" is dropped.
final _dropIdNo = RegExp(
  r'\b(?:order|adm|ex|op|ip|opd|ipd|reg|lab|acc|accession|sample|specimen|'
  r'bill|receipt|visit|ward|bed|room|mrn|uhid|passport|sid|srf|slide|'
  r'requisition|req)\.?\s*(?:no|id|#)\b',
  caseSensitive: false,
);

/// City / state / union-territory names (India-focused), for address lines that
/// are just a locality + city + PIN with no street word.
final _place = RegExp(
  r'\b(?:'
  r'mumbai|navi\s*mumbai|delhi|new\s*delhi|bengaluru|bangalore|chennai|kolkata|'
  r'hyderabad|pune|ahmedabad|surat|jaipur|lucknow|kanpur|nagpur|indore|thane|'
  r'bhopal|visakhapatnam|vizag|patna|vadodara|ghaziabad|ludhiana|agra|nashik|'
  r'faridabad|meerut|rajkot|varanasi|srinagar|amritsar|allahabad|prayagraj|'
  r'ranchi|coimbatore|jabalpur|gwalior|vijayawada|madurai|guwahati|kochi|'
  r'cochin|chandigarh|mysuru|mysore|gurgaon|gurugram|noida|mahim|'
  r'maharashtra|karnataka|tamil\s*nadu|kerala|gujarat|rajasthan|punjab|haryana|'
  r'uttar\s*pradesh|madhya\s*pradesh|west\s*bengal|bihar|telangana|'
  r'andhra\s*pradesh|odisha|assam|jharkhand|chhattisgarh|uttarakhand|'
  r'himachal|goa|tripura|manipur|meghalaya|nagaland|sikkim'
  r')\b',
  caseSensitive: false,
);

/// A spaced or bare 6-digit Indian PIN, treated as an address only when the line
/// also carries a comma or geography cue, so a platelet count is never dropped.
final _spacedPin = RegExp(r'(?<!\d)\d{3}\s\d{3}(?!\d)');

// ── Name-run deletion (bare names in kept clinical prose) ───────────────────
// Names are unlistable, so instead of a denylist this deletes any run of two or
// more adjacent capitalised tokens that are not known clinical vocabulary. A
// lone capitalised unknown is never deleted; deletion needs a run.

/// One word, keeping internal apostrophes/hyphens so "Anne-Marie" / "D'Souza"
/// are a single token.
final _nameWordToken = RegExp(r"[A-Za-z][A-Za-z'’\-]*");

/// Title-case shape: an initial capital then lowercase, with capitalised parts
/// allowed only after an apostrophe or hyphen (D'Souza, Anne-Marie). A bare
/// single capital ("R." initial) also matches.
final _titleCaseName = RegExp(r"^[A-Z][a-z'’]*(?:['’\-][A-Z]?[a-z'’]+)*$");

/// Shortest ALL-CAPS token that may join a name run. Below this every acronym
/// column on a report (LDH, ECG, CRL, BPD, FHR, MTB) is left alone.
const _minCapsNameToken = 4;

/// No part of the token may be known clinical vocabulary (T-wave, HEART).
bool _noClinicalPart(String token) {
  for (final part in token.toLowerCase().split(RegExp(r"[-'’]"))) {
    if (part.length >= 2 && isKnownClinicalToken(part)) return false;
  }
  return true;
}

bool _nameRunEligible(String token) {
  // Reports print patient names in caps, so caps must not grant immunity. Long
  // unknown ALL-CAPS words join a run; short ones stay acronyms.
  if (token.length >= 2 && token == token.toUpperCase()) {
    return token.replaceAll(RegExp(r'[^A-Za-z]'), '').length >=
            _minCapsNameToken &&
        _noClinicalPart(token);
  }
  if (!_titleCaseName.hasMatch(token)) return false;
  return _noClinicalPart(token);
}

/// Deletes name-shaped runs from a line, returning it plus the removal count.
/// Works on Title Case and ALL-CAPS alike, since a run only forms from adjacent
/// words that are not clinical vocabulary.
({String text, int runs}) deleteNameRuns(String line) {
  final tokens = _nameWordToken.allMatches(line).toList();
  final ranges = <List<int>>[]; // [start, end) spans to delete
  var i = 0;
  while (i < tokens.length) {
    if (!_nameRunEligible(tokens[i].group(0)!)) {
      i++;
      continue;
    }
    var j = i;
    while (j + 1 < tokens.length && _nameRunEligible(tokens[j + 1].group(0)!)) {
      final gap = line.substring(tokens[j].end, tokens[j + 1].start);
      // Adjacent only across a small run of spaces / a comma / a period
      // ("Quinn, Dana", "R. Quinn"); anything else ends the run.
      if (gap.length > 3 || RegExp(r'[^ \t.,]').hasMatch(gap)) break;
      j++;
    }
    if (j > i) ranges.add([tokens[i].start, tokens[j].end]);
    i = j + 1;
  }
  if (ranges.isEmpty) return (text: line, runs: 0);

  var out = line;
  for (final r in ranges.reversed) {
    out = out.substring(0, r[0]) + out.substring(r[1]);
  }
  out = out
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\s+([,;.])'), r'$1')
      .trim();
  return (text: out, runs: ranges.length);
}

// ── Known-identity denylist (exact strings read off this document) ──────────
// The scan already read the letterhead and the patient block. Rather than ask a
// regex to re-recognise them in every later payload, the exact strings are
// pulled out once and removed verbatim. An exact match cannot silently regress
// the way a shape heuristic can.

/// A labelled identity or quasi-identifier value. These exact values are also
/// used to scrub cloud replies and cross-document context, where the label is no
/// longer present and a shape-only regular expression would miss them.
final _identityValue = RegExp(
  r'\b(?:patient\s*name|patients?\s*name|name\s*of\s*(?:the\s*)?patient|'
  r'patient|name|(?:ordering|referring|attending|treating|consulting|reporting|'
  r'interpreting)?\s*(?:doctor|physician|provider|clinician|consultant|'
  r'radiologist|pathologist|prescriber)|address|location|locality|'
  r'd\.?o\.?b\.?|date\s*of\s*birth|birth\s*date|phone|mobile|contact|'
  r'mrn|uhid|patient\s*id|registration|accession|account|passport|ssn|'
  r'social\s*security|insurance|policy|member|subscriber|beneficiary|'
  r'medicare|medicaid|health\s*plan|npi)\s*[:#=\-]\s*(.+)$',
  caseSensitive: false,
);

/// A line that is a facility letterhead rather than clinical content.
final _facilityLine = RegExp(
  r'\b(?:hospital|clinic|institute|laborator(?:y|ies)|diagnostics?|'
  r'nursing\s+home|medical\s+(?:centre|center|college)|health\s+care|'
  r'health\s+system|medical\s+(?:group|practice)|pharmac(?:y|ies)|'
  r'imaging\s+(?:centre|center)|polyclinic|pathlab|path\s+lab)\b',
  caseSensitive: false,
);

/// Words never worth stripping on their own, even inside an identity phrase.
bool _stripWorthy(String token) =>
    token.length >= 4 &&
    !isKnownClinicalToken(token.toLowerCase()) &&
    !_identityStopWords.contains(token.toLowerCase());

const _identityStopWords = <String>{
  'name',
  'patient',
  'this',
  'that',
  'with',
  'from',
  'report',
  'centre',
  'center',
  'department',
};

/// The exact identity strings printed on [ocr]: the patient value from any
/// labelled name field, and any letterhead line naming a facility.
///
/// Derived from the stored OCR, so records saved before this existed are
/// covered too and no schema change is needed.
Set<String> identityTermsFor(String ocr) {
  final terms = <String>{};
  if (ocr.trim().isEmpty) return terms;
  for (final raw in ocr.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.length > 120) continue;

    final labelled = _identityValue.firstMatch(line);
    if (labelled != null) {
      // Stop at the next `Label:` so a merged demographics column contributes
      // only its own value.
      final value = labelled
          .group(1)!
          .split(RegExp(r'\s{2,}|\s+(?=\w+\s*[:#=])'))
          .first
          .trim();
      if (value.length >= 4) terms.add(value);
    }

    // A letterhead line is identity unless it is clinical narrative mentioning
    // a hospital ("discharged to hospital", "Hospital course").
    if (_facilityLine.hasMatch(line) &&
        !_hospitalClinical.hasMatch(line) &&
        !_medSection.hasMatch(line)) {
      terms.add(line);
    }
  }
  return terms;
}

/// Removes every term in [terms] from [text], plus the individual distinctive
/// words inside them, case-insensitively and on word boundaries.
///
/// Whole-phrase removal alone is not enough: OCR re-flows the letterhead, so the
/// facility can reappear as a fragment. Only tokens that are not clinical
/// vocabulary are removed individually, so "HEART" inside a hospital name is
/// never stripped out of "fetal heart rate".
String stripKnownIdentity(String text, Set<String> terms) {
  if (text.isEmpty || terms.isEmpty) return text;
  var out = text;
  final phrases = terms.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final phrase in phrases) {
    out = out.replaceAll(
      RegExp(RegExp.escape(phrase), caseSensitive: false),
      ' ',
    );
  }
  final words = <String>{};
  for (final phrase in phrases) {
    for (final token in _nameWordToken.allMatches(phrase)) {
      final w = token.group(0)!;
      if (_stripWorthy(w)) words.add(w);
    }
  }
  for (final word in words) {
    out = out.replaceAll(
      RegExp('\\b${RegExp.escape(word)}\\b', caseSensitive: false),
      ' ',
    );
  }
  return out
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\s+([,;.])'), r'$1')
      .replaceAll(RegExp(r'^[\s,;.&-]+', multiLine: true), '')
      .trim();
}

/// True when [text] carries letterhead or address vocabulary. The title gate
/// uses it to reject a stored title that is really identity ("Meadowlark Hospital").
bool containsIdentityContext(String text) =>
    _dropWord.hasMatch(text) ||
    _dropStem.hasMatch(text) ||
    _place.hasMatch(text) ||
    _patientLabel.hasMatch(text);

/// True when [text] contains a city/state/locality or a spaced Indian PIN.
/// Exposed so the receipt-title gate can still keep addresses out of vendor
/// titles it otherwise sends verbatim.
bool containsPlaceName(String text) =>
    _place.hasMatch(text) || _spacedPin.hasMatch(text);

/// Results-row labels that make the entire row identity, whatever the value is.
///
/// A results table arrives already split into label and value, so the `Label:`
/// separator every other rule here is anchored on has been consumed by the
/// parser. Matching the bare label is what makes a demographic row visible to
/// the barrier at all.
///
/// Age and sex are deliberately absent: they drive the risk calculation on a
/// screening report and are weak identifiers on their own.
final _identityRowLabel = RegExp(
  r'^(?:'
  r"(?:patient|person'?s?|full)?\s*name"
  r'|patient(?:\s*(?:id|no\.?|number|details?))?'
  r'|d\.?o\.?b\.?|date\s*of\s*birth|birth\s*date'
  r'|address|residence|locality|city|state|country|pin\s*code|postal\s*code|zip'
  r'|phone|mobile|tel(?:ephone)?|fax|e-?mail|contact'
  r'|uhid|mrn|crn|abha|aadhaar|aadhar|passport|ssn'
  r'|(?:hospital|registration|regn?|accession|episode|encounter|visit|admission'
  r'|ip|op|lab|sample|specimen|order|barcode|case|file|record|bill|invoice)'
  r'\s*(?:id|no\.?|number|#)'
  r'|guardian|spouse|husband|wife|father|mother|next\s*of\s*kin|attendant'
  r'|nationality|religion|occupation|employer|insurance|policy(?:\s*no\.?)?'
  r'|referr?(?:ed|ing)(?:\s*(?:by|doctor|physician))?'
  r'|consultant|physician|doctor|clinician|prescriber|technician'
  r'|hospital|clinic|centre|center|institute|laborator(?:y|ies)'
  r')$',
  caseSensitive: false,
);

/// True when a results-row [label] means the row is identity, not a finding.
bool isIdentityRowLabel(String label) => _identityRowLabel.hasMatch(
  label.trim().replaceAll(RegExp(r'[\s:\-#=.]+$'), ''),
);

/// Demographic labels kept on purpose: they are clinical inputs, not identity.
/// Maternal age and sex drive the risk figure a screening report exists to
/// produce, and neither identifies anyone on its own.
final _keptDemographicLabel = RegExp(
  r'^(?:(?:maternal|gestational|patient)?\s*age(?:\s*at\s*\w+)?'
  r'|sex|gender)$',
  caseSensitive: false,
);

/// True when a row is demographic but deliberately retained. [_dropField] treats
/// `Age:` as a patient-block field, which is correct for an OCR line and wrong
/// for a results row, so the row scrub consults this first.
bool isKeptDemographicRowLabel(String label) => _keptDemographicLabel.hasMatch(
  label.trim().replaceAll(RegExp(r'[\s:\-#=.]+$'), ''),
);

/// Final block conditions, applied immediately before cloud serialization.
/// Public so the typed gate and its tests share one hard stop.
bool containsHardCloudRisk(String text) =>
    _email.hasMatch(text) ||
    _url.hasMatch(text) ||
    _phone.hasMatch(text) ||
    _postalAddress.hasMatch(text) ||
    _postalCode.hasMatch(text) ||
    _dobValue.hasMatch(text) ||
    _longId.hasMatch(text) ||
    _labeledIdValue.hasMatch(text) ||
    _providerField.hasMatch(text) ||
    _inlineIdentityField.hasMatch(text) ||
    _inlineLocationField.hasMatch(text) ||
    _patientLabel.hasMatch(text) ||
    _dropField.hasMatch(text) ||
    _dropIdNo.hasMatch(text);

/// Returns [text] with personal and identifying details removed; empty in, empty
/// out. Structured Ask-context headers (`[1] Title — Type — date`) have their
/// title vetted by [_sanitizeStructuredHeader] before the normal inline scrub.
final _structuredHeader = RegExp(r'^\[\d+\]\s');

String _sanitizeStructuredHeader(String raw) {
  final divider = raw.indexOf(' — ');
  final bracket = raw.indexOf('] ');
  if (divider < 0 || bracket < 0 || bracket + 2 >= divider) return raw;
  final title = raw.substring(bracket + 2, divider);
  // CloudPrivacyGate.safeTitle already vetted this title, so the backstop only
  // re-checks for a hard identifier or a place. It must not re-canonicalize on
  // "invoice"/"bill", which would blank a real receipt title.
  final unsafe = containsHardCloudRisk(title) || containsPlaceName(title);
  if (!unsafe) return raw;
  return '${raw.substring(0, bracket + 2)}Medical document${raw.substring(divider)}';
}

String redactForCloud(String text) {
  if (text.trim().isEmpty) return text;
  final out = <String>[];
  for (final original in text.split('\n')) {
    var raw = original;
    final isHeader = _structuredHeader.hasMatch(raw.trimLeft());
    if (isHeader) raw = _sanitizeStructuredHeader(raw);
    if (_administrativeFooter.hasMatch(raw)) continue;
    // Medical section lines (Diagnosis, Hospital course, …) are never
    // whole-line-dropped — only inline ID scrub below. Org stems like
    // "hospital" would otherwise kill discharge narrative.
    final isMed = _medSection.hasMatch(raw);
    final dropStem =
        _dropStem.hasMatch(raw) && !isMed && !_hospitalClinical.hasMatch(raw);
    // Whole-line drops: identity, contact, org, address, place, id-number.
    if (!isHeader &&
        !isMed &&
        (_dropWord.hasMatch(raw) ||
            _patientLabel.hasMatch(raw) ||
            dropStem ||
            _dropField.hasMatch(raw) ||
            _dropIdNo.hasMatch(raw) ||
            _place.hasMatch(raw))) {
      continue;
    }
    // A PIN-like number on a line that also looks like an address (has a comma).
    if (!isMed && _spacedPin.hasMatch(raw) && raw.contains(',')) continue;

    // Scrub inline identifiers from what remains.
    var scrubbed = raw
        .replaceAll(_providerTail, ' ')
        .replaceAll(_providerField, ' ')
        .replaceAll(_dobValue, ' ')
        .replaceAll(_labeledIdValue, ' ')
        .replaceAll(_inlineIdentityField, ' ')
        .replaceAll(_inlineLocationField, ' ')
        .replaceAll(_inlineOrganisation, ' ')
        .replaceAll(_email, ' ')
        .replaceAll(_url, ' ')
        .replaceAll(_phone, ' ')
        .replaceAll(_postalAddress, ' ')
        .replaceAll(_postalCode, ' ')
        .replaceAll(_longId, ' ');
    // Collapse the whitespace our replacements may have left behind.
    scrubbed = scrubbed.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trimRight();
    if (scrubbed.trim().isEmpty) continue;
    out.add(scrubbed);
  }
  return out.join('\n');
}

/// Scrubs user-authored Ask text before it goes into a remote request.
///
/// [redactForCloud] drops whole lines, which on a chat message would erase the
/// question along with the name. This variant removes identity spans and inline
/// identifiers while keeping the surrounding question, for both the current turn
/// and history.
String redactConversationForCloud(String text) {
  if (text.trim().isEmpty) return '';
  var scrubbed = text
      .replaceAll(_providerTail, ' ')
      .replaceAll(_providerField, ' ')
      .replaceAll(_dobValue, ' ')
      .replaceAll(_labeledIdValue, ' ')
      .replaceAll(_inlineIdentityField, ' ')
      .replaceAll(_inlineLocationField, ' ')
      .replaceAll(_inlineOrganisation, ' ')
      .replaceAll(_email, ' ')
      .replaceAll(_url, ' ')
      .replaceAll(_phone, ' ')
      .replaceAll(_postalAddress, ' ')
      .replaceAll(_postalCode, ' ')
      .replaceAll(_longId, ' ');

  // Explicit identity/contact fields. Stop at punctuation so a medical question
  // later in the same sentence survives the removal.
  scrubbed = scrubbed.replaceAll(
    RegExp(
      r'\b(?:my\s+name\s+is|patient\s*(?:name|id|number|no\.?)?\s*[:=-]|'
      r'(?:my\s+)?(?:address|phone|mobile|email|e-mail)\s*(?:is|[:=-])|'
      r'(?:my\s+)?(?:dob|date\s+of\s+birth)\s*(?:is|[:=-])|'
      r'(?:mrn|uhid|registration|patient\s+id|insurance|policy|member|'
      r'subscriber|beneficiary|medicare|medicaid|health\s*plan|ssn|npi)'
      r'\s*(?:is|[:=#-]))'
      r'\s*[^,;.!?\n]*[,;]?',
      caseSensitive: false,
    ),
    ' ',
  );
  return scrubbed
      .split('\n')
      // A copied question or earlier cloud answer can contain an unlabelled
      // person name. Delete name-shaped runs here as well as in document prose.
      .map((line) => deleteNameRuns(line).text)
      .map((line) => line.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n')
      .trim();
}

// ── Allowlist for bills (cloud scan refinement of receipts) ──────────────────
// `keepMedicalLines` rejects exactly the lines a bill is made of (fees, totals,
// GST), starving the model into inventing a lab title. Bills therefore keep only
// money lines and billing wording; letterhead, patient block and barcodes go.

/// Billing wording that keeps a money-free line: table headers, totals, taxes.
/// The vendor letterhead never matches, so the vendor name stays on the phone.
final _billWord = RegExp(
  r'sub\s*-?\s*total|\btotal\b|\bnet\b|\bgross\b|\bgrand\b|\bgst\b|\bcgst\b|'
  r'\bsgst\b|\bigst\b|\btax\b|discount|\bamount\b|\bqty\b|quantity|\bmrp\b|'
  r'\brate\b|\bitem\b|product|service|description|particulars|consultation|'
  r'charge|\bpaid\b|payment|balance|payable|\bbill\b|\binv\b|invoice|'
  r'\breceipt\b|cash\s*(bill|memo)|tariff',
  caseSensitive: false,
);

/// Identity wording that vetoes a bill line even when it carries money. Bills
/// print names in ALL-CAPS, which the name-run deleter ignores by design.
final _billIdentityVeto = RegExp(
  r"\b(?:mr|mrs|ms|master|miss|shri|smt|dr)\b\.?\s|patient|\bname\b|father|"
  r"husband|\bs/o\b|\bw/o\b|\bd/o\b|\bage\b|\bsex\b|\bdob\b|address|"
  r"\bcell\b|\bmob\b|phone|email",
  caseSensitive: false,
);

final _billAdministrative = RegExp(
  // Word-bounded, or short identifiers like TIN match inside product names
  // ("CERATINA") and silently remove a genuine bill row.
  r'\b(?:gst\s*(?:no|number|in)|gstin|pan|tan|cin|uin|tin|'
  r'd\.?\s*l\.?\s*(?:no|number)|drug\s*lic|licen[cs]e|'
  r'inv(?:oice)?\s*(?:no|number)|bill\s*(?:no|number)|uhid|mrn|'
  r'mob\.?\s*no|phone|address|shop\s*(?:no|number|o)|'
  r'plot\s*(?:no|number|n)|sector|pincode|get\s+well|thank\s+you)\b|'
  r'\b(?:shop|plot)\s*#',
  caseSensitive: false,
);

final _billTableHeader = RegExp(
  r'\b(product|item|description|particulars?|service|procedure|investigation)\b'
  r'.*\b(amount|charges?|value|total)\b',
  caseSensitive: false,
);

final _billSummaryLine = RegExp(
  r'\b(sub\s*-?\s*total|gross|gst\s*tax|cgst|sgst|igst|discount|less|'
  r'grand\s*total|net|final\s*payment|amount\s*payable|total\s*bill)\b',
  caseSensitive: false,
);

/// The bill allowlist: lines with a money amount or billing wording, minus
/// identity-veto lines. Pure selection — no scrubbing here.
List<String> keepBillLines(String ocr) {
  final lines = ocr.split('\n');
  final header = lines.indexWhere(_billTableHeader.hasMatch);
  var tableEnd = -1;
  if (header >= 0) {
    for (var i = header; i < lines.length; i++) {
      if (_billSummaryLine.hasMatch(lines[i]) || hasMoneyToken(lines[i])) {
        tableEnd = i;
      }
    }
  }

  final kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i].trim();
    if (raw.isEmpty || _billIdentityVeto.hasMatch(raw)) continue;
    final inTable = header >= 0 && i >= header && i <= tableEnd;
    final signal = hasMoneyToken(raw) || _billWord.hasMatch(raw) || inTable;
    if (!signal) continue;
    // Drop a pure administrative/footer row, but keep a row where OCR placed a
    // real summary to its right; billCloudText strips the administrative prefix.
    if (_billAdministrative.hasMatch(raw) && !_billSummaryLine.hasMatch(raw)) {
      continue;
    }
    kept.add(raw);
  }
  return kept;
}

/// Bill payload for the cloud: allowlist, then per-line inline scrubs and the
/// shared hard-risk stop. The scrub set is narrower than the conversation one
/// because the allowlist veto already dropped every identity-labeled line.
/// Name-run deletion is skipped on billing vocabulary, which is title-case and
/// would otherwise be eaten.
String billCloudText(String ocr) {
  final gstin = RegExp(r'\bgstin\b\s*[:#]?\s*\w*', caseSensitive: false);
  // Scrub the id but keep the rest of the line, since its date is useful. The
  // generic hard-risk stop would eat "First Visit" from a consultation fee.
  final billId = RegExp(
    r'\b(?:bill|inv(?:oice)?|op|ip|reg(?:n)?)\.?\s*(?:no|number|id|#)\.?\s*'
    r'[:=#\-]?\s*[a-z0-9][a-z0-9/\-]*',
    caseSensitive: false,
  );
  final administrativeId = RegExp(
    r'\b(?:gst\s*(?:no|number|in)|gstin|pan|tan|cin|uin|tin|'
    r'd\.?\s*l\.?\s*(?:no|number)|drug\s*lic(?:en[cs]e)?)\b'
    r'\s*[:#.=\-]?\s*[a-z0-9][a-z0-9/,.\-]*',
    caseSensitive: false,
  );
  final out = <String>[];
  for (final line in keepBillLines(ocr)) {
    var safe = line
        .replaceAll(_providerField, ' ')
        .replaceAll(_dobValue, ' ')
        .replaceAll(_labeledIdValue, ' ')
        .replaceAll(_email, ' ')
        .replaceAll(_url, ' ')
        .replaceAll(_phone, ' ')
        .replaceAll(_postalAddress, ' ')
        .replaceAll(_postalCode, ' ')
        .replaceAll(_longId, ' ')
        .replaceAll(gstin, ' ')
        .replaceAll(billId, ' ')
        .replaceAll(administrativeId, ' ')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .trim();
    // Geometry-to-text can put a footer cell before a valid summary on the same
    // line, so drop the prefix and keep the summary and its amount.
    if (_billAdministrative.hasMatch(safe) && _billSummaryLine.hasMatch(safe)) {
      final summary = _billSummaryLine.firstMatch(safe);
      if (summary != null && summary.start > 0) {
        safe = safe.substring(summary.start);
      }
    }
    if (safe.isEmpty ||
        _patientLabel.hasMatch(safe) ||
        _inlineIdentityField.hasMatch(safe)) {
      continue;
    }
    if (!_billWord.hasMatch(safe)) {
      final deleted = deleteNameRuns(safe);
      safe = deleted.text.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
      if (safe.isEmpty || _patientLabel.hasMatch(safe)) {
        continue;
      }
    }
    out.add(safe);
  }
  return out.join('\n');
}

// ── Allowlist: keep only lines that look medical ────────────────────────────
// The strong barrier. Rather than enumerate what to remove, keep only lines with
// a medical signal, so letterhead, patient block and footer go wholesale however
// they are worded and whether or not the name is on any list.

/// A number attached to a unit, or a numeric reference range — a result reading.
final _valueUnit = RegExp(
  r'\d\s*(?:%|mg|mcg|ug|µg|ng|pg|kg|dl|ml|iu|miu|meq|mmol|umol|nmol|pmol|mol|'
  r'mm|cm|fl|sec|ratio|cells|cumm|cmm|hpf|lpf|/\s*(?:u?l|µl|cu\s?mm|hpf|lpf|ml)|'
  r'\s?x\s?10)'
  r'|\d+(?:\.\d+)?\s*[-–]\s*\d+(?:\.\d+)?'
  r'|\d\s*(?:g|u)/',
  caseSensitive: false,
);

/// Qualitative verdicts (mirrors scan/qualitative_parser.dart `_verdicts`).
final _verdict = RegExp(
  r'\b(?:not\s+detected|detected|non[\s-]?reactive|reactive|positive|negative|'
  r'abnormal|normal|present|absent|nil|no\s+growth|growth|isolated|'
  r'susceptible|resistant|sensitive|borderline|deficient|high|low|'
  r'stable|unremarkable|uneventful)\b',
  caseSensitive: false,
);

/// Medical section headers and result-table words, mirroring scan_service's
/// `_sectionHeaderRe` + `_summarySections`. Letterheads never use these.
final _medSection = RegExp(
  r'\b(?:test|result|investigation|findings?|impression|conclusion|opinion|'
  r'advice|comments?|interpretation|observation|specimen|sample|method|'
  r'technique|procedure|diagnosis|final\s*diagnosis|indication|'
  r'reference\s*range|units?|biological\s*ref|report\s*status|protocol|'
  r'microscop|macroscop|morpholog|histopatholog|cytolog|hospital\s*course|'
  r'treatment|chief\s*complaint|'
  r'operative(?:\s*(?:findings?|notes?|procedure))?|surgery|'
  r'condition\s*on\s*discharge|medications?\s*on\s*discharge)\b',
  caseSensitive: false,
);

/// Start-of-line medical section header (`Diagnosis:`, `Hospital course`, …).
/// Used to open a keep-body window in [keepMedicalLines].
final _medSectionHeader = RegExp(
  r'^(?:final\s*)?(?:diagnosis|procedure|findings?|impression|conclusion|'
  r'opinion|advice|indication|hospital\s*course|treatment|chief\s*complaint|'
  r'operative(?:\s*(?:findings?|notes?|procedure))?|surgery|'
  r'condition\s*on\s*discharge|medications?\s*on\s*discharge|'
  r'comments?|interpretation|observation|protocol|technique|history|'
  r'specimen|macroscopic\s*description|microscopic\s*description|'
  r'investigation|result)\b\s*:?',
  caseSensitive: false,
);

/// Strong identity / letterhead cues that end a medical-section body window
/// (patient block resumed, address, org banner, reviewer/signature footer).
final _identityExit = RegExp(
  r'^(?:name|patient|age|sex|gender|address|phone|mobile|uhid|mrn|'
  r'referred|consultant|physician|signature|signed)\b'
  r'|\b(?:age|sex|gender)\s*[:/\-]'
  r'|\bpatient\s*(?:name)?\s*[:/\-]'
  r'|\b(?:reviewed|prepared|reported|verified)\s+by\b'
  r'|\belectronically\s+signed\b',
  caseSensitive: false,
);

/// Storage/disposal/legal footer prose, dropped whole before medical-section
/// exceptions can preserve it, since it often carries the hospital and location.
final _administrativeFooter = RegExp(
  r'\b(?:will\s+be\s+(?:stored|discarded|destroyed)|retained\s+for|'
  r'electronically\s+signed|end\s+of\s+report)\b'
  // Page and print footers carry the patient name on every page of a report,
  // and OCR mangles both the name and the word "of", so they are dropped by
  // shape rather than by spelling.
  r'|\bpage\s*\d+\s*(?:of|o[fl])?\s*\d+'
  r'|\b(?:printed|examined|generated)\s+on\b',
  caseSensitive: false,
);

/// Known imaging/procedure phrases (mirrors scan_service `_knownProcedures`).
final _procedure = RegExp(
  r'\b(?:pet[\s/-]?ct|pet\s*scan|ct\s*scan|computed\s*tomography|mri|'
  r'magnetic\s*resonance|x[\s-]?ray|ultrasound|ultrasonograph|sonograph|usg|'
  r'doppler|mammogra|echocardiogra|ecg|electrocardiogra|eeg|biopsy|histopath|'
  r'cytolog|culture|pyrosequencing|haemogram|hemogram)\b',
  caseSensitive: false,
);

/// A date next to collection or reporting context, which keeps the report date.
///
/// A bare "date" is deliberately not enough: OCR reads "Date of birth" as
/// "Date of blrth" often enough that the denylist cannot be relied on to catch
/// it afterwards, and an examination or admission date next to a name is the
/// patient block rather than the report.
final _reportDate = RegExp(
  r'(?:collect|receiv|report|releas|sample|drawn|registered|dated)\w*',
  caseSensitive: false,
);
final _anyDate = RegExp(r'\d{1,2}[\s./-][A-Za-z0-9]{2,}[\s./-]\d{2,4}');

/// Whether a line may ride an open medical-section window on its own.
///
/// Two shapes qualify. Clinical prose is written in sentences, so it always
/// carries a plain lowercase word. Clinical labels are Title Case but every
/// substantial word is known vocabulary, which "Placenta Posterior" and
/// "Maternal Serum Biochemistry" satisfy and "General Speciality" does not —
/// one vocabulary hit is not enough, since letterheads borrow words like
/// "general" and "heart".
///
/// Testing shape rather than spelling is what catches the fragments OCR has
/// mangled, which no keyword list can match.
bool _carriesInSection(String line) {
  final words = line
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((w) => w.length >= 3 && w.contains(RegExp(r'[A-Za-z]')))
      .toList();
  if (words.length < 2) return false;
  if (words.any((w) => w == w.toLowerCase() && w.contains(RegExp(r'[a-z]')))) {
    return true;
  }
  return words.every(isKnownClinicalToken);
}

/// Keeps only lines carrying a medical signal (value/unit, range, verdict,
/// section header, procedure, the report [title], or a report date), plus body
/// lines following a medical-section header until the next header or an identity
/// exit. That second rule is what lets a bare "Laparoscopic cholecystectomy"
/// through, since it has no keyword of its own.
///
/// Everything else is dropped. This is the primary barrier; [redactForCloud]
/// scrubs the survivors as layer two.
String keepMedicalLines(String ocr, {String? title}) {
  if (ocr.trim().isEmpty) return ocr;
  final t = title?.trim() ?? '';
  final titleRe = t.length >= 3
      ? RegExp(RegExp.escape(t), caseSensitive: false)
      : null;
  final kept = <String>[];
  var inMedSection = false;
  var blankRun = 0;
  for (final raw in ocr.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      blankRun++;
      // Two+ blank lines end a section body (page break / block gap).
      if (blankRun >= 2) inMedSection = false;
      continue;
    }
    blankRun = 0;
    if (_administrativeFooter.hasMatch(line)) {
      inMedSection = false;
      continue;
    }

    // Strong identity/letterhead → leave any open section and drop the line.
    final hasMedicalSignal =
        _valueUnit.hasMatch(line) ||
        _verdict.hasMatch(line) ||
        _medSection.hasMatch(line) ||
        _procedure.hasMatch(line);
    if ((_identityExit.hasMatch(line) ||
            _dropField.hasMatch(line) ||
            _patientLabel.hasMatch(line)) &&
        !hasMedicalSignal) {
      inMedSection = false;
      continue;
    }

    final isSectionHeader = _medSectionHeader.hasMatch(line);
    if (isSectionHeader) {
      inMedSection = true;
      kept.add(raw);
      continue;
    }

    final medical =
        _valueUnit.hasMatch(line) ||
        _verdict.hasMatch(line) ||
        _medSection.hasMatch(line) ||
        _procedure.hasMatch(line) ||
        (titleRe?.hasMatch(line) ?? false) ||
        (_reportDate.hasMatch(line) && _anyDate.hasMatch(line));
    if (medical || (inMedSection && _carriesInSection(line))) {
      // Org/address letterhead that somehow sits inside a section window —
      // still drop it so names don't ride along with clinical prose.
      if (inMedSection &&
          !medical &&
          (_dropWord.hasMatch(line) ||
              (_dropStem.hasMatch(line) && !_hospitalClinical.hasMatch(line)) ||
              _place.hasMatch(line) ||
              _dropIdNo.hasMatch(line))) {
        inMedSection = false;
        continue;
      }
      kept.add(raw);
    }
  }
  return kept.join('\n');
}

/// The cloud-bound transform for scan OCR: keep only medical lines, then scrub
/// any identifiers that survived. Two layers, applied only when the cloud engine
/// is active (on-device never calls this).
String medicalCloudText(String ocr, {String? title}) =>
    redactForCloud(keepMedicalLines(ocr, title: title));
