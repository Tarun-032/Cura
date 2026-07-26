import '../library/document.dart';
import 'remote/pii_redactor.dart' show keepMedicalLines;

/// Lightweight, on-device keyword retrieval over the saved documents. No model
/// or network — it ranks documents by how well their text matches the question,
/// so the LLM only ever sees the few relevant ones. Effective because the scan
/// pipeline already stores clean, keyword-rich fields (test names, values, title).

/// Common words that carry no retrieval signal — including generic document
/// words ("report", "results") that otherwise match every saved document.
const _stopwords = {
  'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'is', 'are',
  'was',
  'were',
  'my',
  'me',
  'i',
  'what',
  'whats',
  'when',
  'how',
  'show',
  'tell',
  'do', 'did', 'does', 'have', 'has', 'had', 'with', 'about', 'it', 'this',
  'that', 'last', 'latest', 'recent', 'any', 'all', 'be', 'been', 'from',
  'report', 'reports', 'result', 'results', 'value', 'values', 'record',
  'records', 'document', 'documents', 'reading', 'readings', 'please', 'can',
  'you', 'give', 'explain',
  // Generic category words carry no signal and, via the +2 title boost, would
  // ground onto any doc whose title contains them. Specific terms still match.
  'test', 'tests', 'scan', 'scans', 'lab', 'labs', 'prescription',
  'prescriptions', 'medication', 'medications', 'summary', 'summarize',
  'summarise', 'level', 'levels', 'checkup', 'appointment', 'visit',
  // Generic pronouns / quantifiers that carry no retrieval signal — they must
  // never ground a follow-up like "the other one too" onto a random document.
  'other', 'another', 'one', 'ones', 'too', 'also', 'same', 'else', 'different',
};

class ScoredDoc {
  const ScoredDoc(this.document, this.score);
  final CuraDocument document;
  final int score;
}

/// Splits the question into meaningful lowercase terms.
List<String> _terms(String text) {
  return text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.length >= 3 && !_stopwords.contains(t))
      .toList();
}

const _monthNames = kMonthNames;

/// Lowercase full month names, January = index 0. Public so the query router can
/// echo a month back to the user ("reports from August").
const kMonthNames = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];
const _monthAbbr = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

String _ordinal(int n) {
  if (n >= 11 && n <= 13) return '${n}th';
  switch (n % 10) {
    case 1:
      return '${n}st';
    case 2:
      return '${n}nd';
    case 3:
      return '${n}rd';
    default:
      return '${n}th';
  }
}

/// Every plausible way to mention a date, so date questions retrieve the doc.
String _dateTokens(DateTime d) {
  final m = d.month;
  final day = d.day;
  return [
    _monthNames[m - 1],
    _monthAbbr[m - 1],
    '$m',
    m.toString().padLeft(2, '0'),
    '$day',
    day.toString().padLeft(2, '0'),
    _ordinal(day),
    '${d.year}',
  ].join(' ');
}

/// The lowercased, searchable haystack for a document.
String _haystack(CuraDocument d) {
  final b = StringBuffer()
    ..write(d.title)
    ..write(' ')
    ..write(d.type.label)
    ..write(' ')
    ..write(_dateTokens(d.date))
    ..write(' ')
    ..write(d.tags.join(' '))
    ..write(' ');
  for (final r in d.results) {
    b
      ..write(r.label)
      ..write(' ')
      ..write(r.value)
      ..write(r.unit ?? '')
      ..write(' ')
      ..write(r.range ?? '')
      ..write(' ');
  }
  b
    ..write(d.resultsNote ?? '')
    ..write(' ')
    ..write(d.extractedText);
  return b.toString().toLowerCase();
}

/// A date referenced in the question (any part may be null).
class QueryDate {
  const QueryDate(this.month, this.day, this.year);
  final int? month;
  final int? day;
  final int? year;
  bool get hasMonth => month != null;

  /// True when the question pinned down at least a month or a year — enough to
  /// filter documents by date.
  bool get hasAny => month != null || year != null;
}

/// Parses a date mention from the question, e.g. "september 3rd 2024". Public so
/// the query router reuses the exact same parser the retrieval ranking uses.
QueryDate parseQueryDate(String q) {
  final lower = q.toLowerCase();
  int? month;
  for (var i = 0; i < 12; i++) {
    if (lower.contains(_monthNames[i]) ||
        RegExp('\\b${_monthAbbr[i]}\\b').hasMatch(lower)) {
      month = i + 1;
      break;
    }
  }
  int? year;
  final ym = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(lower);
  if (ym != null) year = int.parse(ym.group(0)!);
  int? day;
  for (final m in RegExp(r'\b(\d{1,2})(?:st|nd|rd|th)?\b').allMatches(lower)) {
    final n = int.parse(m.group(1)!);
    if (n >= 1 && n <= 31) {
      day = n;
      break;
    }
  }
  return QueryDate(month, day, year);
}

/// Ranks documents by keyword overlap with [question] (highest first). When the
/// question names a specific date, the document with that date is boosted hard
/// so it wins the tie that common date words ("report", "2024") would create.
List<ScoredDoc> rankDocuments(String question, List<CuraDocument> docs) {
  final terms = _terms(question);
  final qd = parseQueryDate(question);
  final scored = <ScoredDoc>[];
  for (final d in docs) {
    final hay = _haystack(d);
    final title = d.title.toLowerCase();
    final labels = d.results.map((r) => r.label.toLowerCase()).join(' ');
    var score = 0;
    for (final t in terms) {
      // Plural tolerance: if the exact term isn't present, also try its singular
      // ("ultrasounds" → "ultrasound") so wording/plurality doesn't drop a match.
      final singular = t.length > 3 && t.endsWith('s')
          ? t.substring(0, t.length - 1)
          : null;
      bool has(String field) =>
          field.contains(t) || (singular != null && field.contains(singular));
      if (!has(hay)) continue;
      score += 1;
      if (has(title)) score += 2;
      if (has(labels)) score += 1;
    }
    // Strong, specific boost when the question's date matches this document's.
    if (qd.hasMonth && d.date.month == qd.month) {
      final yearOk = qd.year == null || d.date.year == qd.year;
      if (yearOk) {
        score += 3;
        if (qd.day != null && d.date.day == qd.day) score += 5;
      }
    }
    scored.add(ScoredDoc(d, score));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  return scored;
}

/// Picks the documents to hand the model: the best keyword matches within a
/// budget, or — when nothing matches (e.g. "summarize my records") — the most
/// recent ones.
List<CuraDocument> selectContext(
  String question,
  List<CuraDocument> docs, {
  int maxDocs = 4,
  int maxChars = 3200,
}) {
  if (docs.isEmpty) return const [];
  final ranked = rankDocuments(question, docs);
  final top = ranked.isEmpty ? 0 : ranked.first.score;
  List<CuraDocument> picked;
  if (top > 0) {
    // Keep only clearly-relevant docs (near the top score), so a specific
    // question doesn't drag in every weakly-matching document.
    final threshold = top <= 2 ? top : (top / 2).ceil();
    picked = ranked
        .where((s) => s.score >= threshold)
        .map((s) => s.document)
        .toList();
  } else {
    picked = [...docs]..sort((a, b) => b.date.compareTo(a.date));
  }

  final out = <CuraDocument>[];
  var chars = 0;
  for (final d in picked) {
    if (out.length >= maxDocs) break;
    final len = _docBlock(d, out.length + 1).length;
    if (out.isNotEmpty && chars + len > maxChars) break;
    out.add(d);
    chars += len;
  }
  return out;
}

/// Max chars of narrative OCR / medical excerpt attached when a doc has no
/// Results rows. Large enough for Findings/Impression; still bounded for prefill.
const kNarrativeContextChars = 2500;

/// Builds the model-facing context for [docs]. With [includeRawText] false
/// (cloud), only structured fields plus an allowlisted medical excerpt are sent
/// ([keepMedicalLines]); on-device keeps fuller OCR excerpts.
String buildContext(List<CuraDocument> docs, {bool includeRawText = true}) {
  final b = StringBuffer();
  for (var i = 0; i < docs.length; i++) {
    b.write(_docBlock(docs[i], i + 1, includeRawText: includeRawText));
  }
  return b.toString().trim();
}

/// A compact, complete index of saved records for the cloud model. It contains
/// structured metadata only: never raw OCR, page paths, or tags.
String buildRecordInventory(List<CuraDocument> docs) {
  final ordered = [...docs]..sort((a, b) => b.date.compareTo(a.date));
  final b = StringBuffer(
    'Complete record inventory (${ordered.length} total records):\n',
  );
  for (var i = 0; i < ordered.length; i++) {
    final d = ordered[i];
    b.writeln('[${i + 1}] ${d.title} — ${d.type.label} — ${d.dateLabel}');
  }
  return b.toString().trimRight();
}

String _docBlock(CuraDocument d, int index, {bool includeRawText = true}) {
  final b = StringBuffer()
    ..write('[$index] ')
    ..write(d.title)
    ..write(' — ')
    ..write(d.type.label)
    ..write(' — ')
    ..writeln(d.dateLabel);

  if (d.type == DocumentType.prescription) {
    if (d.resultsNote != null && d.resultsNote!.isNotEmpty) {
      b.writeln('Summary: ${d.resultsNote}');
    }
    if (d.results.isNotEmpty) {
      final medicines = d.results
          .map((r) => '${r.label}: ${r.valueWithUnit}')
          .join('; ');
      b.writeln('Medicines: $medicines');
    } else {
      // A summary-only prescription still needs its reliable medical excerpt
      // when Ask needs detail beyond the generated overview.
      final excerpt = includeRawText
          ? _truncate(d.extractedText, kNarrativeContextChars)
          : _truncate(
              keepMedicalLines(d.extractedText, title: d.title),
              kNarrativeContextChars,
            );
      if (excerpt.isNotEmpty) b.writeln('Text: $excerpt');
    }
  } else if (d.results.isNotEmpty) {
    // Lab / receipt: structured rows only — no full OCR dump.
    final parts = d.results
        .map((r) {
          final range = r.range != null ? ' (${r.range})' : '';
          return '${r.label}: ${r.valueWithUnit}$range';
        })
        .join('; ');
    b.writeln('Results: $parts');
    if (d.resultsNote != null && d.resultsNote!.isNotEmpty) {
      b.writeln('Notes: ${d.resultsNote}');
    }
  } else {
    // Imaging / discharge / empty-results: Notes + a longer medical excerpt so
    // Ask is not limited to a thin one-line summary.
    if (d.resultsNote != null && d.resultsNote!.isNotEmpty) {
      b.writeln('Notes: ${d.resultsNote}');
    }
    final excerpt = includeRawText
        ? _truncate(d.extractedText, kNarrativeContextChars)
        : _truncate(
            keepMedicalLines(d.extractedText, title: d.title),
            kNarrativeContextChars,
          );
    if (excerpt.isNotEmpty) b.writeln('Text: $excerpt');
  }
  b.writeln();
  return b.toString();
}

String _truncate(String text, int maxChars) {
  final t = text.trim();
  if (t.isEmpty) return '';
  if (t.length <= maxChars) return t;
  return '${t.substring(0, maxChars)}…';
}

// ─────────────────────────────────────────────────────────────────────────────
// Grounding: which document (if any) to hand the model, and why
// ─────────────────────────────────────────────────────────────────────────────

/// The document type a question refers to, or null when it names no specific
/// kind. Plural-tolerant. Shared by the query router and [groundingFor].
DocumentType? detectDocumentType(String q) {
  if (RegExp(r'\bprescriptions?\b').hasMatch(q) ||
      q.contains('medication') ||
      q.contains('medicine') ||
      q.contains('drug')) {
    return DocumentType.prescription;
  }
  if (RegExp(r'\breceipts?\b').hasMatch(q) ||
      q.contains('bill') ||
      q.contains('payment') ||
      q.contains('invoice')) {
    return DocumentType.receipt;
  }
  if (q.contains('discharge')) return DocumentType.discharge;
  if (RegExp(
    r'\b(pet[\s\-/]?ct|mris?|ct\s+scans?|x[\s\-]?rays?|ultrasounds?|'
    r'usg|sonograph\w*|imaging|radiology|mammograms?|echo)\b',
  ).hasMatch(q)) {
    return DocumentType.imaging;
  }
  if (RegExp(r'\blabs?\b').hasMatch(q) ||
      q.contains('blood test') ||
      q.contains('blood report') ||
      q.contains('bloodwork') ||
      q.contains('blood work') ||
      q.contains('lab report')) {
    return DocumentType.lab;
  }
  return null;
}

/// Keyword score at or above which a document is confidently the subject of the
/// question, so we attach and cite it.
const _groundThreshold = 2;

/// Generic words that signal the user is asking about their own records even when
/// no specific medical term matches (e.g. "summarize my latest report").
const _recordWords = {
  'report',
  'reports',
  'record',
  'records',
  'result',
  'results',
  'document',
  'documents',
  'scan',
  'scans',
  'prescription',
  'prescriptions',
  'lab',
  'labs',
  'test',
  'tests',
  'bloodwork',
  'summary',
  'summarize',
  'summarise',
  'reading',
  'readings',
  'level',
  'levels',
  'checkup',
  'appointment',
  'visit',
};

/// True when the question refers to the user's own records/health data — even
/// without a keyword hit. Greetings and general questions return false.
bool _mentionsRecords(String q) {
  for (final w in q.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
    if (_recordWords.contains(w)) return true;
  }
  return false;
}

/// A greeting with no attached question or request. This is checked before
/// conversational focus resolution so "hello" never inherits the last scan.
final _pureGreetingRe = RegExp(
  r'^(?:(?:hi|hello|hey|hiya|howdy|namaste)(?:\s+(?:there|cura))?|'
  r'good\s+(?:morning|afternoon|evening))(?:[!,.?]\s*)*$',
  caseSensitive: false,
);

bool isPureGreeting(String q) => _pureGreetingRe.hasMatch(q.trim());

// "what is/are X" is a definition; "what does the ultrasound say/show" is reading
// a document, not defining a term, so "does" is deliberately excluded.
final _definitionRe = RegExp(r'\bwhat\s+(is|are)\b');
final _personalRe = RegExp(r'\b(my|mine|me|i|was|were|had)\b');

/// A general "what is/are X" question with no personal framing — general
/// knowledge, not about the user's records ("what is a TB pyrosequencing test?").
/// "what is my cholesterol?" is personal → not a definition → still grounds.
bool _isDefinition(String q) {
  final l = q.toLowerCase();
  return _definitionRe.hasMatch(l) && !_personalRe.hasMatch(l);
}

/// Why (and whether) a document was attached. [focusResolve] means a follow-up
/// about sibling reports that can't be pinned deterministically: attach them all
/// and let the model pick among them.
enum GroundingKind {
  grounded,
  typeMatch,
  collection,
  recent,
  missingType,
  focusResolve,
  none,
}

/// What context to hand the model. [contextDocs] is what to attach, [source] the
/// document to cite, [missingLabel] the human name of something not on file, and
/// [otherReports] the same-kind reports to name but not attach.
class Grounding {
  const Grounding(
    this.kind, {
    this.contextDocs = const [],
    this.source,
    this.missingLabel,
    this.otherReports = const [],
  });
  final GroundingKind kind;
  final List<CuraDocument> contextDocs;
  final CuraDocument? source;
  final String? missingLabel;
  final List<CuraDocument> otherReports;
}

/// An imaging modality the user might name, with the synonyms that identify it
/// and the label to say back. MRI and ultrasound are both `DocumentType.imaging`,
/// so the modality is what tells them apart.
class _Modality {
  const _Modality(this.label, this.synonyms);
  final String label;
  final List<String> synonyms;
}

const _imagingModalities = <_Modality>[
  _Modality('MRI scan', ['mri', 'magnetic resonance']),
  _Modality('CT scan', [
    'ct scan',
    'computed tomography',
    'cect',
    'ncct',
    'pet ct',
    'pet-ct',
  ]),
  _Modality('ultrasound', ['ultrasound', 'usg', 'sonograph', 'doppler']),
  _Modality('X-ray', ['x-ray', 'x ray', 'xray', 'radiograph']),
  _Modality('mammogram', ['mammogram', 'mammograph']),
  _Modality('echocardiogram', ['echocardiogra', 'echo']),
];

/// The imaging modality [q] names (word-boundary match so "echo" doesn't fire on
/// "echoes" of nothing), or null when it uses only a generic imaging word.
_Modality? _namedImagingModality(String q) {
  final l = q.toLowerCase();
  for (final m in _imagingModalities) {
    for (final s in m.synonyms) {
      // Optional trailing "s" so a plural ("ultrasounds", "x-rays") matches too —
      // "how many ultrasounds" must resolve the modality, not just the singular.
      final pattern = RegExp('(?<![a-z])${RegExp.escape(s)}s?(?![a-z])');
      if (pattern.hasMatch(l)) return m;
    }
  }
  return null;
}

/// Whether [d]'s searchable text identifies it as modality [m].
bool _docMatchesModality(CuraDocument d, _Modality m) {
  final hay = _haystack(d);
  return m.synonyms.any(hay.contains);
}

/// The imaging modality named in [q] — "ultrasound", "MRI scan", "X-ray"… — or
/// null when it uses only a generic imaging word (or none). Public so the query
/// router can count/label by modality (an "ultrasound" is not every imaging doc).
String? namedImagingModalityLabel(String q) => _namedImagingModality(q)?.label;

/// Whether [d] is an imaging document of the modality named by [label] (as
/// returned by [namedImagingModalityLabel]). Shared with the router so counting
/// "ultrasounds" and grounding an ultrasound question agree on what counts.
bool documentMatchesModalityLabel(CuraDocument d, String label) {
  for (final m in _imagingModalities) {
    if (m.label == label) return _docMatchesModality(d, m);
  }
  return false;
}

/// "April 2, 2025" / "April 2025" / "April" / "2025" — a human date for the parts
/// the question pinned down (used in a "no X from …" message).
String _queryDateLabel(QueryDate qd) {
  final month = qd.month != null
      ? kMonthNames[qd.month! - 1][0].toUpperCase() +
            kMonthNames[qd.month! - 1].substring(1)
      : null;
  if (month != null && qd.day != null && qd.year != null) {
    return '$month ${qd.day}, ${qd.year}';
  }
  if (month != null && qd.day != null) return '$month ${qd.day}';
  if (month != null && qd.year != null) return '$month ${qd.year}';
  if (month != null) return month;
  return '${qd.year}';
}

/// True when [date] is consistent with every part [qd] pinned down.
bool _dateMatchesQuery(DateTime date, QueryDate qd) {
  if (qd.month != null && date.month != qd.month) return false;
  if (qd.year != null && date.year != qd.year) return false;
  if (qd.day != null && date.day != qd.day) return false;
  return true;
}

/// The question refers to a *different* document than the one(s) already shown
/// ("the other ultrasound", "my second scan") → exclude what's been cited.
final _otherRe = RegExp(
  r'\b(other|another|different|remaining|rest|second|2nd|next)\b',
);

/// A superlative that picks one of several same-kind reports by recency, so
/// "explain my latest ultrasound" (or a reply "latest one") never has to ask
/// which — the pick is deterministic and always the *actually* newest/oldest.
enum _Superlative { newest, oldest }

final _newestRe = RegExp(
  r'\b(latest|most recent|newest|newer|current|last|recent)\b',
);
final _oldestRe = RegExp(r'\b(oldest|earliest|older)\b');

/// The recency the question asks for, or null when it names none. Oldest is
/// tested first so "older"/"earliest" isn't shadowed by a stray "recent".
_Superlative? _superlativeOf(String q) {
  final l = q.toLowerCase();
  if (_oldestRe.hasMatch(l)) return _Superlative.oldest;
  if (_newestRe.hasMatch(l)) return _Superlative.newest;
  return null;
}

/// A plain demonstrative — "explain this", "tell me more" — that points back at the
/// *specific* report just shown rather than a different one.
final _demonstrativeRe = RegExp(
  r'\b(this|that|it|these|those|more|again|elaborate|detail|details)\b',
);

/// A broad "all my records / reports / history" ask — about the whole collection,
/// not one focused report, so focus resolution must defer to the recent/none paths.
final _broadScopeRe = RegExp(
  r'\b(all|every|everything|each|entire|records|reports|documents|'
  r'history)\b',
);

/// Explicit plural/group language. Unlike [_otherRe], this distinguishes "the
/// other one" (one sibling) from "the rest" / "them together" (a collection).
final _focusCollectionRe = RegExp(
  r'\b(remaining|rest|both|them|together|each)\b|'
  r'\ball\s+(?:of\s+)?(?:them|those|these|the\s+others?)\b',
);

final _typeCollectionWordRe = RegExp(
  r'\b(all|both|each|every|together|remaining|rest)\b',
);

/// Whether a named document kind was requested as a set rather than as one
/// report. Plural nouns count even without "all": "summarize my receipts" is a
/// collection request, while "explain my July receipt" is a single target.
bool _requestsTypeCollection(String q, DocumentType type) {
  final l = q.toLowerCase();
  if (_typeCollectionWordRe.hasMatch(l)) return true;
  return switch (type) {
    DocumentType.receipt => RegExp(
      r'\b(receipts|bills|invoices|payments)\b',
    ).hasMatch(l),
    DocumentType.prescription => RegExp(
      r'\b(prescriptions|medications|medicines|drugs)\b',
    ).hasMatch(l),
    DocumentType.imaging => RegExp(
      r'\b(scans|ultrasounds|mris|x-rays|xrays|mammograms)\b',
    ).hasMatch(l),
    DocumentType.lab => RegExp(
      r'\b(labs|blood\s+tests|lab\s+reports)\b',
    ).hasMatch(l),
    DocumentType.discharge => RegExp(
      r'\b(discharge\s+(?:summaries|reports))\b',
    ).hasMatch(l),
    DocumentType.visit => RegExp(r'\b(visits|visit\s+notes)\b').hasMatch(l),
  };
}

/// When the reply names a distinctive word from exactly one focused report's
/// title (e.g. "the supraclavicular one", "the jaw one"), that report — else null
/// (no match, or ambiguous because several titles share the word).
CuraDocument? _titleKeywordPick(String q, List<CuraDocument> pool) {
  final terms = _terms(q); // drops stopwords + generic document words
  if (terms.isEmpty) return null;
  CuraDocument? hit;
  for (final d in pool) {
    final title = d.title.toLowerCase();
    final matches = terms.any((t) {
      final singular = t.length > 3 && t.endsWith('s')
          ? t.substring(0, t.length - 1)
          : null;
      return title.contains(t) ||
          (singular != null && title.contains(singular));
    });
    if (matches) {
      if (hit != null) return null; // more than one title matches → ambiguous
      hit = d;
    }
  }
  return hit;
}

/// Resolves a follow-up reply against the reports in focus ([focusDocIds]).
/// A superlative, date, title keyword or "the other" narrows the pool to one
/// report; a demonstrative re-attaches a single focused one. Null when the
/// message doesn't read as a follow-up.
Grounding? _resolveFocus(
  String q,
  List<CuraDocument> docs,
  Set<String> focusDocIds,
  Set<String> shownSourceIds,
) {
  final focused = docs.where((d) => focusDocIds.contains(d.id)).toList();
  if (focused.isEmpty) return null;

  final l = q.toLowerCase();
  // A broad "all my records / reports" ask is about the whole collection, not one
  // focused report — let the recent/none paths handle it.
  if (_broadScopeRe.hasMatch(l)) return null;

  // Sibling pool: every report of the same kind as a focused one, so "the other
  // one" can reach a sibling never itself in focus. Imaging narrows to the
  // focused doc's modality, so an ultrasound's "other one" isn't an MRI.
  final types = focused.map((d) => d.type).toSet();
  var pool = docs.where((d) => types.contains(d.type)).toList();
  if (types.length == 1 && types.first == DocumentType.imaging) {
    final mods = <_Modality>{};
    for (final d in focused) {
      for (final m in _imagingModalities) {
        if (_docMatchesModality(d, m)) mods.add(m);
      }
    }
    if (mods.isNotEmpty) {
      pool = pool
          .where((d) => mods.any((m) => _docMatchesModality(d, m)))
          .toList();
    }
  }
  // Newest first, so a superlative or the default pick is deterministic.
  pool.sort((a, b) => b.date.compareTo(a.date));

  final qd = parseQueryDate(q);
  final sup = _superlativeOf(q);
  final other = _otherRe.hasMatch(l);
  final titlePick = _titleKeywordPick(q, pool);
  // Does the message point at a *different* report than the one shown (a date, a
  // superlative, "the other", or a distinct title word)? — vs. a plain "this".
  final refersElsewhere =
      other || sup != null || qd.hasAny || titlePick != null;

  // A resolved sibling is attached alone, with the other same-kind reports named
  // as [otherReports] so the model knows they exist.
  List<CuraDocument> others(CuraDocument target) =>
      pool.where((d) => d.id != target.id).toList();

  // Fast, exact path: when the reference is crisp, narrow deterministically so the
  // pick is instant and carries a precise source card.
  final context = {...shownSourceIds, ...focusDocIds};

  // "The rest", "both", or "summarize them together" asks for several sibling
  // reports, not one report to resolve. For rest/remaining, omit reports already
  // shown; for the other plural forms, attach the whole sibling set.
  if (_focusCollectionRe.hasMatch(l)) {
    var requested = pool;
    if (_otherRe.hasMatch(l) && context.isNotEmpty) {
      final remaining = pool.where((d) => !context.contains(d.id)).toList();
      if (remaining.isNotEmpty) requested = remaining;
    }
    if (requested.length > 1) {
      return Grounding(GroundingKind.collection, contextDocs: requested);
    }
  }

  var narrowed = pool;
  if (other && context.isNotEmpty) {
    final remaining = narrowed.where((d) => !context.contains(d.id)).toList();
    if (remaining.isNotEmpty) narrowed = remaining;
  }
  if (qd.hasAny) {
    final onDate = narrowed
        .where((d) => _dateMatchesQuery(d.date, qd))
        .toList();
    if (onDate.isNotEmpty) narrowed = onDate;
  }
  if (titlePick != null && narrowed.contains(titlePick)) narrowed = [titlePick];
  if (sup != null && narrowed.length > 1) {
    narrowed = [sup == _Superlative.newest ? narrowed.first : narrowed.last];
  }
  if (refersElsewhere && narrowed.length == 1) {
    final target = narrowed.first;
    return Grounding(
      GroundingKind.typeMatch,
      contextDocs: [target],
      source: target,
      otherReports: others(target),
    );
  }

  // A plain demonstrative that doesn't point elsewhere ("explain this", "tell me
  // more") → the specific report already shown.
  if (!refersElsewhere && _demonstrativeRe.hasMatch(l) && focused.length == 1) {
    final target = focused.first;
    return Grounding(
      GroundingKind.typeMatch,
      contextDocs: [target],
      source: target,
      otherReports: others(target),
    );
  }

  // Everything else: hand over the candidate reports and let the model resolve
  // the reference from the wording and chat history. It can only pick among them.
  final bounded = pool.take(4).toList();
  if (bounded.length == 1) {
    return Grounding(
      GroundingKind.typeMatch,
      contextDocs: bounded,
      source: bounded.first,
    );
  }
  return Grounding(GroundingKind.focusResolve, contextDocs: bounded);
}

/// Decides which document (if any) grounds [question]. Pure and deterministic,
/// unit-tested in test/grounding_test.dart.
///
/// A named type/modality resolves first, then any date, then already-shown docs
/// when the user says "other". None left means it isn't on file; one is attached
/// and cited; several pick one target and name the rest as
/// [Grounding.otherReports]. Otherwise a confident keyword match grounds, else
/// the most recent doc for a generic records question, else nothing.
///
/// [shownSourceIds] are documents already cited in this chat, used to resolve
/// "the other one". [focusDocIds] are the reports the conversation is about.
Grounding groundingFor(
  String question,
  List<CuraDocument> docs, {
  Set<String> shownSourceIds = const {},
  Set<String> focusDocIds = const {},
  List<String> orderedFocusDocIds = const [],
}) {
  final q = question.trim();
  if (q.isEmpty || docs.isEmpty) return const Grounding(GroundingKind.none);

  // A greeting is a new social turn, never an implicit reference to the last
  // cited report. Keep it context-free even when the conversation has focus.
  if (isPureGreeting(q)) return const Grounding(GroundingKind.none);

  // General "what is X?" (non-personal) → the model's own knowledge, no document.
  if (_isDefinition(q)) return const Grounding(GroundingKind.none);

  // Ordinals resolve before keyword ranking, or "first" matches OCR text in an
  // unrelated document ("First Medical" on a bill) and hijacks the follow-up.
  final ordinalIndex = _ordinalReferenceIndex(
    q.toLowerCase(),
    orderedFocusDocIds.length,
  );
  if (ordinalIndex != null) {
    final byId = {for (final d in docs) d.id: d};
    final ordered = [
      for (final id in orderedFocusDocIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (ordinalIndex < ordered.length) {
      final target = ordered[ordinalIndex];
      return Grounding(
        GroundingKind.typeMatch,
        contextDocs: [target],
        source: target,
        otherReports: ordered.where((d) => d.id != target.id).toList(),
      );
    }
  }

  // A named type resolves before the keyword match, so "ultrasound" considers
  // every ultrasound rather than grabbing whichever title contains the word.
  final type = detectDocumentType(q);
  if (type != null) {
    // Candidates of the named kind. For imaging, keep only the named modality
    // (an MRI request must never be answered from an ultrasound).
    var candidates = docs.where((d) => d.type == type).toList();
    var label = type.label;
    if (type == DocumentType.imaging) {
      final modality = _namedImagingModality(q);
      if (modality != null) {
        label = modality.label;
        candidates = candidates
            .where((d) => _docMatchesModality(d, modality))
            .toList();
      }
    }

    // Narrow by any date the question names ("the April 2nd ultrasound").
    final qd = parseQueryDate(q);
    if (qd.hasAny) {
      candidates = candidates
          .where((d) => _dateMatchesQuery(d.date, qd))
          .toList();
      label = '$label from ${_queryDateLabel(qd)}';
    }
    candidates.sort((a, b) => b.date.compareTo(a.date)); // newest first
    if (candidates.isEmpty) {
      // Asked about a kind/modality/date they don't have → attach nothing and flag
      // it, so the model says it isn't on file rather than using an unrelated doc.
      return Grounding(GroundingKind.missingType, missingLabel: label);
    }
    // A plural request attaches the structured contents of every match, so no
    // report reads as though its breakdown were unavailable.
    if (candidates.length > 1 && _requestsTypeCollection(q, type)) {
      var requested = candidates;
      final context = {...shownSourceIds, ...focusDocIds};
      if (_otherRe.hasMatch(q.toLowerCase()) && context.isNotEmpty) {
        final remaining = candidates
            .where((d) => !context.contains(d.id))
            .toList();
        if (remaining.isNotEmpty) requested = remaining;
      }
      return Grounding(GroundingKind.collection, contextDocs: requested);
    }

    // One report of the named kind → attach & cite it.
    if (candidates.length == 1) {
      return Grounding(
        GroundingKind.typeMatch,
        contextDocs: [candidates.first],
        source: candidates.first,
      );
    }
    // Several of the same kind: pick one target deterministically, never a
    // "which one?" placeholder. "The other" prefers one not yet discussed, a
    // superlative picks newest/oldest, anything else takes the newest. The rest
    // ride along as [otherReports].
    final context = {...shownSourceIds, ...focusDocIds};
    var pickable = candidates;
    if (_otherRe.hasMatch(q.toLowerCase()) && context.isNotEmpty) {
      final remaining = candidates
          .where((d) => !context.contains(d.id))
          .toList();
      if (remaining.isNotEmpty) pickable = remaining;
    }
    final sup = _superlativeOf(q);
    final target = sup == _Superlative.oldest ? pickable.last : pickable.first;
    return Grounding(
      GroundingKind.typeMatch,
      contextDocs: [target],
      source: target,
      otherReports: candidates.where((d) => d.id != target.id).toList(),
    );
  }

  // No type named — a specific keyword match → the best document, cited.
  final ranked = rankDocuments(q, docs);
  final top = ranked.isNotEmpty ? ranked.first : null;
  if (top != null && top.score >= _groundThreshold) {
    return Grounding(
      GroundingKind.grounded,
      contextDocs: selectContext(q, docs, maxDocs: 1, maxChars: 3200),
      source: top.document,
    );
  }

  // A follow-up reply resolving an earlier clarify, or continuing about the report
  // already shown ("latest one", "the other", "explain this") → the focused report.
  if (focusDocIds.isNotEmpty) {
    final focused = _resolveFocus(q, docs, focusDocIds, shownSourceIds);
    if (focused != null) return focused;
  }

  // Generic "about my records" (no specific type) → most recent document, no card.
  if (_mentionsRecords(q)) {
    final recent = ([...docs]..sort((a, b) => b.date.compareTo(a.date))).first;
    return Grounding(GroundingKind.recent, contextDocs: [recent]);
  }

  return const Grounding(GroundingKind.none);
}

/// Documents named in [text], in the order they appear, so the next turn can
/// resolve "the first one" against the list just displayed. Matches on the
/// normalized full title, never a shared word.
List<CuraDocument> mentionedDocumentsInOrder(
  String text,
  List<CuraDocument> docs,
) {
  final normalizedText = _normalizeReferenceText(text);
  final matches = <({int index, CuraDocument document})>[];
  for (final document in docs) {
    final title = _normalizeReferenceText(document.title).trim();
    if (title.length < 3) continue;
    final index = normalizedText.indexOf(title);
    if (index >= 0) matches.add((index: index, document: document));
  }
  matches.sort((a, b) => a.index.compareTo(b.index));
  return [for (final match in matches) match.document];
}

/// Saved documents explicitly identified in a collection answer, in display
/// order. Stricter than conversational focus: a complete normalized title is
/// required, and duplicate titles also need the date on the same line. An
/// ambiguous match shows no card. This is how a semantic cloud collection
/// ("TB-related", "kidney") maps back to local documents.
List<CuraDocument> explicitlyNamedDocumentsInOrder(
  String text,
  List<CuraDocument> docs,
) {
  if (text.trim().isEmpty || docs.isEmpty) return const [];

  final byTitle = <String, List<CuraDocument>>{};
  final byIdentity = <String, List<CuraDocument>>{};
  for (final document in docs) {
    final title = _normalizeReferenceText(document.title).trim();
    if (title.length < 3) continue;
    final date = _normalizeReferenceText(document.dateLabel).trim();
    byTitle.putIfAbsent(title, () => []).add(document);
    byIdentity.putIfAbsent('$title|$date', () => []).add(document);
  }

  final matches = <({int index, int end, CuraDocument document})>[];
  var lineOffset = 0;
  for (final rawLine in text.split('\n')) {
    final line = _normalizeReferenceText(rawLine).trim();
    if (line.isNotEmpty) {
      for (final entry in byTitle.entries) {
        final title = entry.key;
        final titleIndex = line.indexOf(title);
        if (titleIndex < 0) continue;

        CuraDocument? document;
        if (entry.value.length == 1) {
          document = entry.value.single;
        } else {
          // Repeated titles such as "Medical Stores invoice" are common. The
          // date printed beside the title is the stable discriminator.
          final dated = entry.value.where((candidate) {
            final date = _normalizeReferenceText(candidate.dateLabel).trim();
            return date.isNotEmpty && line.contains(date);
          }).toList();
          if (dated.length != 1) continue;
          final date = _normalizeReferenceText(dated.single.dateLabel).trim();
          if (byIdentity['$title|$date']?.length != 1) continue;
          document = dated.single;
        }

        matches.add((
          index: lineOffset + titleIndex,
          end: lineOffset + titleIndex + title.length,
          document: document,
        ));
      }
    }
    lineOffset += line.length + 1;
  }

  // If one stored title is a prefix of another, keep only the longest identity
  // at that occurrence. Distinct titles elsewhere on the same line still stay.
  matches.sort((a, b) {
    final byPosition = a.index.compareTo(b.index);
    if (byPosition != 0) return byPosition;
    return b.end.compareTo(a.end);
  });
  final ordered = <CuraDocument>[];
  final seenIds = <String>{};
  var coveredUntil = -1;
  for (final match in matches) {
    if (match.index < coveredUntil) continue;
    if (!seenIds.add(match.document.id)) continue;
    ordered.add(match.document);
    coveredUntil = match.end;
  }
  return ordered;
}

String _normalizeReferenceText(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ');

int? _ordinalReferenceIndex(String text, int itemCount) {
  if (itemCount < 2) return null;
  const ordinals = <List<String>>[
    ['first', '1st'],
    ['second', '2nd'],
    ['third', '3rd'],
    ['fourth', '4th'],
    ['fifth', '5th'],
    ['sixth', '6th'],
    ['seventh', '7th'],
    ['eighth', '8th'],
    ['ninth', '9th'],
    ['tenth', '10th'],
  ];
  for (var i = 0; i < ordinals.length && i < itemCount; i++) {
    if (ordinals[i].any(
      (word) => RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(text),
    )) {
      return i;
    }
  }
  if (RegExp(
    r'\b(last|final)\s+(one|report|record|result|item)\b',
  ).hasMatch(text)) {
    return itemCount - 1;
  }
  return null;
}
