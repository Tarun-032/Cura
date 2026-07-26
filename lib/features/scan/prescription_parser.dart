import '../library/document.dart';

/// Deterministic prescription medicines extractor, no model. Emits one
/// [DocumentResult] per medicine: `label` is the name with its strength
/// ("Tab. Amoxicillin 500mg"), `value` the printed directions ("1-0-1 x 5 days").
/// Verbatim from the OCR line, so a value can never be invented.
///
/// A line counts as a medicine only with a real prescription signal: a
/// dosage-form word, `1-0-1` notation, or a dose with a frequency. That gate is
/// what keeps lab values and vitals out.
///
/// Single-line detection only: directions that wrap parse as name-only.
List<DocumentResult> parsePrescriptionMedicines(String ocrText) {
  final seen = <String>{};
  final medicines = <DocumentResult>[];
  for (final raw in ocrText.split('\n')) {
    final line = raw.replaceFirst(_indexPrefix, '').trim();
    if (line.isEmpty || _wordCount(line) > 14) continue;

    final hasForm = _form.hasMatch(line);
    final hasSchedule = _schedule.hasMatch(line); // "1-0-1"
    final hasDose = _dose.hasMatch(line);
    final freq = _freq.firstMatch(line);
    final dur = _duration.firstMatch(line);

    // Medicine iff a strong signal (dosage form or 1-0-1 schedule), or a dose
    // paired with directions, or both frequency and duration present.
    final isMedicine =
        hasForm ||
        hasSchedule ||
        (hasDose && (freq != null || dur != null)) ||
        (freq != null && dur != null);
    if (!isMedicine) continue;

    // Directions begin at the first frequency/duration/schedule token; the
    // medicine name (with strength/form) is everything before it.
    final splitAt = _firstDirectionIndex(line);
    final label = (splitAt == null ? line : line.substring(0, splitAt))
        .replaceFirst(_trailingSep, '')
        .trim();
    final value = splitAt == null ? '' : line.substring(splitAt).trim();

    // A row needs a real name (letters), not a bare directions fragment.
    if (!_hasLetters.hasMatch(label)) continue;
    if (!seen.add('$label|$value')) continue; // drop exact duplicates
    medicines.add(DocumentResult(label, value));
  }
  return medicines;
}

/// Earliest position of a directions token (schedule / frequency / duration),
/// or null when the line has none (a form-only line like "Tab. Vitamin D3").
int? _firstDirectionIndex(String line) {
  var best = -1;
  for (final re in [_schedule, _freq, _duration]) {
    final m = re.firstMatch(line);
    if (m != null && (best < 0 || m.start < best)) best = m.start;
  }
  return best < 0 ? null : best;
}

int _wordCount(String s) =>
    s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

final _indexPrefix = RegExp(r'^\s*(?:\d+\s*[).\]:-]|[-*•·])\s*');
final _trailingSep = RegExp(r'[\s:,\-–]+$');
final _hasLetters = RegExp(r'[A-Za-z]{2,}');

/// Dosage-form words. A trailing period ("Tab.") is optional.
final _form = RegExp(
  r'\b(?:tabs?|tablets?|caps?|capsules?|syp|syr|syrup|inj|injection|oint|'
  r'ointment|cream|gel|drops?|susp|suspension|sachet|powder|lotion|spray|'
  r'soln?|solution|supp|suppository|pessary|patch|inhaler|nebuliser|neb|'
  r'elixir|mixt|mixture|lozenge)\b\.?',
  caseSensitive: false,
);

/// "N mg / ml / mcg …" strength token (shares the shape of receipt_parser's
/// _doseTokenRe and pii_redactor's _valueUnit).
final _dose = RegExp(
  r'\b\d+(?:\.\d+)?\s*(?:mg|mcg|ug|µg|gm|g|ml|iu|units?|%)\b',
  caseSensitive: false,
);

/// The "1-0-1" (morning-noon-night) dosing notation — a strong medicine signal
/// on its own. Single digits between boundaries, so it never matches a date.
final _schedule = RegExp(r'\b\d\s*-\s*\d\s*-\s*\d(?:\s*-\s*\d)?\b');

/// Frequency abbreviations and phrases (OD/BD/TDS/QID/…, "twice daily", …).
final _freq = RegExp(
  r'\b(?:od|bd|bid|tds|tid|qid|qds|hs|sos|stat|prn|q\d+h)\b'
  r'|\b(?:once|twice|thrice|\d+\s*times?)\s+(?:a\s+day|daily|per\s+day|'
  r'weekly|a\s+week|at\s+night|hourly|in\s+a\s+day)\b'
  r'|\bevery\s+\d+\s*(?:hours?|hrs?|h)\b',
  caseSensitive: false,
);

/// Duration ("x 5 days", "for 2 weeks", "/7", "/52").
final _duration = RegExp(
  r'\b(?:x|for)\s*\d+\s*(?:days?|d|weeks?|wks?|months?|/7|/52|/12)\b',
  caseSensitive: false,
);
