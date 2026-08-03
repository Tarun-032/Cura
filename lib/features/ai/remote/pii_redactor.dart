/// Cloud-only scrub for OCR text.
/// Aggressive, but not perfect.
/// Keep medical content; strip obvious identity.
library;

import '../../scan/receipt_parser.dart' show hasMoneyToken;
import 'clinical_vocabulary.dart';

// Inline scrubs.
final _email = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
final _url = RegExp(r'(https?://|www\.)\S+', caseSensitive: false);
// Catch phone-like runs, but not lab ranges.
final _phone = RegExp(
  r'\+\d[\d\s\-]{7,}\d'
  r'|(?<!\d)\d{10}(?!\d)'
  r'|(?<!\d)\d{5}[\s\-]\d{5}(?!\d)'
  r'|(?<!\d)\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4}(?!\d)',
);
// Catch long ID-like runs.
final _longId = RegExp(r'\b\d{8,}\b');
// Catch labeled IDs.
final _labeledIdValue = RegExp(
  r'\b(?:(?:mrn|uhid|passport|ssn|social\s*security|npi|abha|aadhaar|aadhar)'
  r'\s*(?:no\.?|number|id|#)?'
  r'|(?:patient\s*id|registration|accession|case|visit|encounter|invoice|'
  r'account|insurance|policy|member|subscriber|beneficiary|medicare|medicaid|'
  r'health\s*plan|provider|order|specimen|sample)\s*(?:no\.?|number|id|#))\s*'
  r'[:=#\-]?\s*[a-z0-9][a-z0-9/\-]{2,}',
  caseSensitive: false,
);

/// Catch street-style addresses.
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

/// Keep provider labels separate.
// Keep the label casing tight.
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

// Drop reviewer tails.
final _providerTail = RegExp(
  r'\b(?:reviewed|reported|verified|prepared|signed|interpreted|authorized)\s+by\b.*$',
  caseSensitive: false,
);

// Catch inline identity fields.
final _inlineIdentityField = RegExp(
  r'\b(?:patient\s*(?:name|id|number|no\.?)|name\s+of\s+(?:the\s+)?patient|'
  r'doctor|consultant|physician|provider|clinician|prescriber|'
  r'referring\s+doctor|ordering\s+provider)\s*[:=#\-]\s*'
  r'[^,;.!?\n]*[,;]?',
  caseSensitive: false,
);

// Catch facility names.
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

// Whole-word cues.
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

/// Keep patient identity labels only.
final _patientLabel = RegExp(
  r'\bpatient\s*(?:name|id|no\.?|details?)?\s*[:/\-]'
  r'|\bpatient\s*name\b'
  r'|\bname\s*of\s*(?:the\s*)?patient\b',
  caseSensitive: false,
);

/// Let clinical hospital uses survive.
final _hospitalClinical = RegExp(
  r'\bhospital\s*course\b|\bdischarged?\b|\badmission\b|'
  r'\b(?:in|to)\s*(?:the\s*)?hospital\b',
  caseSensitive: false,
);

/// Catch organisation stems.
final _dropStem = RegExp(
  r'\b(?:hospital|clinic|laborator|diagnostic|patholog|healthcare|radiolog|'
  r'imaging\s*(?:cent|clinic|lab|services|dept|department)|medical\s*cent)',
  caseSensitive: false,
);

/// Catch patient block fields.
final _dropField = RegExp(
  r'\b(?:age|sex|gender|marital|d\.?o\.?b|date\s*of\s*birth)\s*[:/\-]'
  r'|\b[sdwcb]/o\b', // s/o, d/o, w/o, c/o, b/o
  caseSensitive: false,
);

/// Catch record-style labels.
final _dropIdNo = RegExp(
  r'\b(?:order|adm|ex|op|ip|opd|ipd|reg|lab|acc|accession|sample|specimen|'
  r'bill|receipt|visit|ward|bed|room|mrn|uhid|passport|sid|srf|slide|'
  r'requisition|req)\.?\s*(?:no|id|#)\b',
  caseSensitive: false,
);

/// Catch place names.
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

/// Catch Indian PINs when they look like addresses.
final _spacedPin = RegExp(r'(?<!\d)\d{3}\s\d{3}(?!\d)');

// Name-run deletion.

/// One token, with apostrophes and hyphens kept.
final _nameWordToken = RegExp(r"[A-Za-z][A-Za-z'’\-]*");

/// Title-case shape for names.
final _titleCaseName = RegExp(r"^[A-Z][a-z'’]*(?:['’\-][A-Z]?[a-z'’]+)*$");

/// Minimum caps length for a name token.
const _minCapsNameToken = 4;

/// Skip tokens that look clinical.
bool _noClinicalPart(String token) {
  for (final part in token.toLowerCase().split(RegExp(r"[-'’]"))) {
    if (part.length >= 2 && isKnownClinicalToken(part)) return false;
  }
  return true;
}

/// Keep first-person contractions out of name runs.
final _firstPersonContraction = RegExp(r"^I['’]");

bool _nameRunEligible(String token) {
  if (_firstPersonContraction.hasMatch(token)) return false;
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

/// Delete name-shaped runs.
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

// Known-identity denylist.

/// Exact identity values.
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

/// Facility letterhead pattern.
final _facilityLine = RegExp(
  r'\b(?:hospital|clinic|institute|laborator(?:y|ies)|diagnostics?|'
  r'nursing\s+home|medical\s+(?:centre|center|college)|health\s+care|'
  r'health\s+system|medical\s+(?:group|practice)|pharmac(?:y|ies)|'
  r'imaging\s+(?:centre|center)|polyclinic|pathlab|path\s+lab)\b',
  caseSensitive: false,
);

/// Keep these words from being stripped alone.
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

/// Pull exact identity strings from OCR.
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

/// Remove exact identity terms and their words.
String stripKnownIdentity(String text, Set<String> terms) {
  if (text.isEmpty || terms.isEmpty) return text;
  var out = text;
  final phrases = terms.toList()..sort((a, b) => b.length.compareTo(a.length));
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

/// Flag obvious identity context.
bool containsIdentityContext(String text) =>
    _dropWord.hasMatch(text) ||
    _dropStem.hasMatch(text) ||
    _place.hasMatch(text) ||
    _patientLabel.hasMatch(text);

/// Flag place-like text.
bool containsPlaceName(String text) =>
    _place.hasMatch(text) || _spacedPin.hasMatch(text);

/// Mark identity-style result rows.
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

/// Check identity row labels.
bool isIdentityRowLabel(String label) => _identityRowLabel.hasMatch(
  label.trim().replaceAll(RegExp(r'[\s:\-#=.]+$'), ''),
);

/// Keep demographic labels.
final _keptDemographicLabel = RegExp(
  r'^(?:(?:maternal|gestational|patient)?\s*age(?:\s*at\s*\w+)?'
  r'|sex|gender)$',
  caseSensitive: false,
);

/// Check retained demographic rows.
bool isKeptDemographicRowLabel(String label) => _keptDemographicLabel.hasMatch(
  label.trim().replaceAll(RegExp(r'[\s:\-#=.]+$'), ''),
);

/// Final hard-risk stop.
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

/// Strip identity from cloud text.
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

/// Scrub chat text without dropping the whole question.
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

// Bill allowlist.

/// Billing words that keep a line.
final _billWord = RegExp(
  r'sub\s*-?\s*total|\btotal\b|\bnet\b|\bgross\b|\bgrand\b|\bgst\b|\bcgst\b|'
  r'\bsgst\b|\bigst\b|\btax\b|discount|\bamount\b|\bqty\b|quantity|\bmrp\b|'
  r'\brate\b|\bitem\b|product|service|description|particulars|consultation|'
  r'charge|\bpaid\b|payment|balance|payable|\bbill\b|\binv\b|invoice|'
  r'\breceipt\b|cash\s*(bill|memo)|tariff',
  caseSensitive: false,
);

/// Veto identity-heavy bill lines.
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

/// Keep bill lines with signal.
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

/// Build the cloud bill payload.
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

// Medical allowlist.

/// Match result-style values.
final _valueUnit = RegExp(
  r'\d\s*(?:%|mg|mcg|ug|µg|ng|pg|kg|dl|ml|iu|miu|meq|mmol|umol|nmol|pmol|mol|'
  r'mm|cm|fl|sec|ratio|cells|cumm|cmm|hpf|lpf|/\s*(?:u?l|µl|cu\s?mm|hpf|lpf|ml)|'
  r'\s?x\s?10)'
  r'|\d+(?:\.\d+)?\s*[-–]\s*\d+(?:\.\d+)?'
  r'|\d\s*(?:g|u)/',
  caseSensitive: false,
);

/// Match verdict-style words.
final _verdict = RegExp(
  r'\b(?:not\s+detected|detected|non[\s-]?reactive|reactive|positive|negative|'
  r'abnormal|normal|present|absent|nil|no\s+growth|growth|isolated|'
  r'susceptible|resistant|sensitive|borderline|deficient|high|low|'
  r'stable|unremarkable|uneventful)\b',
  caseSensitive: false,
);

/// Match medical section words.
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

/// Match medical section headers.
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

/// Stop the medical window at identity cues.
final _identityExit = RegExp(
  r'^(?:name|patient|age|sex|gender|address|phone|mobile|uhid|mrn|'
  r'referred|consultant|physician|signature|signed)\b'
  r'|\b(?:age|sex|gender)\s*[:/\-]'
  r'|\bpatient\s*(?:name)?\s*[:/\-]'
  r'|\b(?:reviewed|prepared|reported|verified)\s+by\b'
  r'|\belectronically\s+signed\b',
  caseSensitive: false,
);

/// Drop footer prose.
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

/// Match procedure phrases.
final _procedure = RegExp(
  r'\b(?:pet[\s/-]?ct|pet\s*scan|ct\s*scan|computed\s*tomography|mri|'
  r'magnetic\s*resonance|x[\s-]?ray|ultrasound|ultrasonograph|sonograph|usg|'
  r'doppler|mammogra|echocardiogra|ecg|electrocardiogra|eeg|biopsy|histopath|'
  r'cytolog|culture|pyrosequencing|haemogram|hemogram)\b',
  caseSensitive: false,
);

/// Match report-like dates.
final _reportDate = RegExp(
  r'(?:collect|receiv|report|releas|sample|drawn|registered|dated)\w*',
  caseSensitive: false,
);
final _anyDate = RegExp(r'\d{1,2}[\s./-][A-Za-z0-9]{2,}[\s./-]\d{2,4}');

/// Decide whether a line can ride the medical window.
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

/// Keep only medical lines and body text.
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

/// Cloud OCR transform.
String medicalCloudText(String ocr, {String? title}) =>
    redactForCloud(keepMedicalLines(ocr, title: title));
