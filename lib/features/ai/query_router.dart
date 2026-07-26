import '../../core/util/range_status.dart';
import '../library/document.dart';
import '../scan/receipt_parser.dart'
    show isFinalReceiptAmountLabel, isReceiptSummaryLabel;
import 'retrieval.dart';

/// A natural-language answer built from the structured documents, no LLM. Only
/// returned when [routeQuestion] is confident it can be exact. [source] is the
/// document to show in the answer card.
enum RoutedAnswerKind { value, count, latest, list, notFound }

class RoutedAnswer {
  const RoutedAnswer(
    this.text, {
    required this.kind,
    required this.protectedFacts,
    this.source,
    this.sources = const [],
    this.sourceTotal = 0,
    this.sourcesAreAuthoritative = false,
  });
  final String text;
  final RoutedAnswerKind kind;
  final List<String> protectedFacts;
  final CuraDocument? source;

  /// For a multi-match answer, the complete matching set to show as source
  /// cards, newest first. Empty for single-source or non-collection answers
  /// ([source] carries those).
  final List<CuraDocument> sources;

  /// The true number of matching reports. Drives the "+N more" label while the
  /// complete [sources] set remains available after expansion. 0 when empty.
  final int sourceTotal;

  /// True when [sources] came from an exact type/modality/date scope rather
  /// than free-form topical keyword ranking. Cloud answers may use this set
  /// directly; semantic collections instead map the exact titles the model
  /// names back to saved documents after generation.
  final bool sourcesAreAuthoritative;

  /// A short factual answer needs very little generation. Lists get extra room
  /// because every displayed report must survive the rewrite unchanged.
  int get rewriteMaxTokens => kind == RoutedAnswerKind.list ? 192 : 96;
}

/// The instant sentence-builder is a local-model optimization only. A configured
/// cloud model must see every turn so it can use conversation history and the
/// complete sanitized inventory instead of returning a canned router sentence.
bool shouldUseQueryRouter({required bool cloudActive}) => !cloudActive;

/// Tiny prompt that makes an already-verified router answer sound conversational.
/// Carries no document context: the model is a wording layer, nothing more.
String buildVerifiedRewritePrompt(String question, RoutedAnswer answer) =>
    'Rewrite the verified answer below as a natural, direct reply to the user. '
    'Keep every count, value, unit, date, range, status, and report identity '
    'exactly unchanged. Do not omit a listed item. Do not add medical facts or '
    'advice. Use one short sentence unless the verified answer is a list.\n\n'
    'User question: $question\n'
    'Verified answer: ${answer.text}\n'
    'Reply:';

String _normalizeVerifiedFact(String text) => text
    .toLowerCase()
    .replaceAll('×', 'x')
    .replaceAll(RegExp(r'[–—−]'), '-')
    .replaceAll(RegExp(r'[^a-z0-9.<>=/%+\-]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Rejects a local rewrite that dropped a protected fact or introduced a new
/// number. A failed rewrite is never shown; the exact router sentence wins.
bool isValidVerifiedRewrite(String rewrite, RoutedAnswer answer) {
  final normalized = _normalizeVerifiedFact(rewrite);
  if (normalized.isEmpty) return false;
  for (final fact in answer.protectedFacts) {
    final protected = _normalizeVerifiedFact(fact);
    if (protected.isNotEmpty && !normalized.contains(protected)) return false;
  }

  final numberRe = RegExp(r'\d+(?:\.\d+)?');
  final verifiedNumbers = numberRe
      .allMatches(_normalizeVerifiedFact(answer.text))
      .map((m) => m.group(0)!)
      .toSet();
  final rewriteNumbers = numberRe
      .allMatches(normalized)
      .map((m) => m.group(0)!)
      .toSet();
  if (!verifiedNumbers.containsAll(rewriteNumbers)) return false;

  if (answer.kind == RoutedAnswerKind.notFound &&
      !RegExp(
        r'\b(no|not|don\s*t|doesn\s*t|cannot|can\s*t)\b',
      ).hasMatch(normalized)) {
    return false;
  }
  return true;
}

String verifiedRewriteOrFallback(String rewrite, RoutedAnswer answer) =>
    isValidVerifiedRewrite(rewrite, answer) ? rewrite.trim() : answer.text;

/// Answers [question] instantly from the structured fields of [docs], skipping
/// the model. Returns null unless fully confident, so the caller falls back to
/// the LLM and a miss is only ever slower, never wrong. Pure: no model or I/O.
RoutedAnswer? routeQuestion(String question, List<CuraDocument> docs) {
  if (docs.isEmpty) return null;
  final q = question.toLowerCase().trim();
  if (q.isEmpty) return null;

  final qd = parseQueryDate(question);
  final personal = _isPersonal(q) || qd.hasAny;

  // Anything that needs reasoning, interpretation, or general knowledge goes to
  // the model. This is the main "no gaps" guard.
  if (_needsReasoning(q)) return null;
  // "What is cholesterol?" (a definition) — only block when it's NOT about the
  // user's own data. "What is my cholesterol?" stays on the fast path.
  if (!personal && _looksLikeDefinition(q)) return null;

  final type = detectDocumentType(q);
  // Imaging questions usually name a modality, which is narrower than the type,
  // so "how many ultrasounds" must not count every imaging report.
  final modalityLabel = type == DocumentType.imaging
      ? namedImagingModalityLabel(q)
      : null;

  // Order matters: a recognised test name is a value question even if it also
  // says "latest"; money questions outrank latest/count so "how much was my
  // last bill" answers with the amount, not the document identity.
  return _tryValueLookup(q, qd, docs) ??
      _tryReceiptAmount(q, qd, docs) ??
      _tryLatest(q, qd, type, modalityLabel, docs) ??
      _tryCount(q, qd, type, modalityLabel, docs) ??
      _tryListOrDateDoc(q, qd, type, modalityLabel, docs);
}

// ─────────────────────────────────────────────────────────────────────────────
// Guards
// ─────────────────────────────────────────────────────────────────────────────

/// Verbs/phrases that mean the user wants prose, interpretation or advice — the
/// model's job, not a template's.
const _reasoningTriggers = [
  'explain',
  'summarize',
  'summarise',
  'summary',
  'why',
  'interpret',
  'tell me about',
  'describe',
  'compare',
  'difference between',
  'what does',
  'what do they',
  'mean',
  'meaning',
  'should i',
  'advice',
  'recommend',
  'is it normal',
  'is this normal',
  'are these normal',
  'normal',
  'abnormal',
  'elevated',
  'healthy',
  'dangerous',
  'serious',
  'worry',
  'worried',
  'concern',
  'concerned',
  'too high',
  'too low',
  'is it high',
  'is it low',
  'good or bad',
];

bool _needsReasoning(String q) {
  for (final t in _reasoningTriggers) {
    if (q.contains(t)) return true;
  }
  return false;
}

/// "what is/are/does ..." with no personal framing → a definition request.
bool _looksLikeDefinition(String q) =>
    RegExp(r'\bwhat\s+(is|are|does)\b').hasMatch(q);

/// The question is about the user's own records (vs. a general definition).
bool _isPersonal(String q) =>
    RegExp(r'\b(my|mine|me|i)\b').hasMatch(q) ||
    RegExp(r'\b(was|were|had)\b').hasMatch(q);

// ─────────────────────────────────────────────────────────────────────────────
// Document type
// ─────────────────────────────────────────────────────────────────────────────

// detectDocumentType lives in retrieval.dart (imported above) so the router and
// the LLM grounding path share one detector.

// ─────────────────────────────────────────────────────────────────────────────
// Test-value lookup
// ─────────────────────────────────────────────────────────────────────────────

/// Groups of synonyms for the same clinical measure. A document result and a
/// question "share a test" when both touch the same group.
const _aliasGroups = <List<String>>[
  ['hemoglobin', 'haemoglobin', 'hb', 'hgb'],
  ['hba1c', 'a1c', 'glycated'],
  ['glucose', 'blood sugar', 'sugar', 'fasting glucose', 'fbs'],
  ['white blood cell', 'white blood cells', 'wbc', 'leukocyte'],
  ['red blood cell', 'red blood cells', 'rbc'],
  ['platelet', 'platelets'],
  ['total cholesterol', 'cholesterol'],
  ['ldl'],
  ['hdl'],
  ['triglyceride', 'triglycerides'],
  ['creatinine'],
  ['urea', 'bun'],
  ['uric acid'],
  ['tsh', 'thyroid'],
  ['vitamin d', 'vit d', '25-hydroxy'],
  ['vitamin b12', 'b12'],
  // Liver function panel.
  ['alkaline phosphatase', 'alkaline phosphate', 'alk phos', 'alp'],
  ['bilirubin'],
  ['sgpt', 'alt'],
  ['sgot', 'ast'],
  ['total protein', 'total proteins'],
  ['albumin'],
  ['globulin'],
  ['a/g ratio', 'ag ratio'],
  // Kidney / electrolytes.
  ['potassium'],
  ['sodium'],
  ['chloride'],
  ['calcium'],
  ['esr'],
  ['blood pressure'],
  ['heart rate', 'pulse'],
  ['dose', 'dosage'],
  ['frequency'],
  ['duration'],
];

/// Generic words inside a result label that must not, on their own, count as a
/// match (otherwise "blood" would match every blood-test row).
const _nonSpecific = {
  'blood',
  'cell',
  'cells',
  'count',
  'total',
  'test',
  'tests',
  'level',
  'levels',
  'serum',
  'plasma',
  'value',
  'values',
  'result',
  'results',
  'rate',
};

const _matchStopwords = {
  'the',
  'a',
  'an',
  'and',
  'or',
  'of',
  'to',
  'in',
  'on',
  'for',
  'is',
  'are',
  'was',
  'were',
  'my',
  'me',
  'what',
  'whats',
  'when',
  'show',
  'tell',
  'how',
  'did',
  'does',
  'have',
  'has',
  'with',
  'about',
  'this',
  'that',
  'from',
};

/// One (document, result) pair the question refers to, tagged with a canonical
/// key so that the *same* test across documents groups together, while different
/// tests stay distinct.
class _Hit {
  _Hit(this.doc, this.result, this.key);
  final CuraDocument doc;
  final DocumentResult result;
  final String key;
}

/// Strips periods so dotted acronyms match their plain form ("S.G.P.T" → "sgpt").
/// The alias groups are stored dotless, so normalizing both sides here lets a
/// user search "SGPT" and hit a result labelled "S.G.P.T" (and vice-versa).
String _dedot(String s) => s.replaceAll('.', '');

/// The alias-group index a label belongs to (a trigger is a substring of the
/// label), or -1.
int _groupOf(String labelLower) {
  final label = _dedot(labelLower);
  for (var i = 0; i < _aliasGroups.length; i++) {
    for (final t in _aliasGroups[i]) {
      if (label.contains(t)) return i;
    }
  }
  return -1;
}

/// An alias counts only when it starts at a word boundary: "last" must not
/// touch the "ast" alias. The end stays open so plurals keep matching
/// ("triglycerides" → "triglyceride").
bool _mentionsAlias(String dq, String alias) =>
    RegExp('\\b${RegExp.escape(alias)}').hasMatch(dq);

bool _questionTouchesGroup(String q, int group) {
  if (group < 0) return false;
  final dq = _dedot(q);
  return _aliasGroups[group].any((a) => _mentionsAlias(dq, a));
}

/// The first alias group the question mentions, or null.
int? _firstTouchedGroup(String q) {
  final dq = _dedot(q);
  for (var i = 0; i < _aliasGroups.length; i++) {
    if (_aliasGroups[i].any((a) => _mentionsAlias(dq, a))) return i;
  }
  return null;
}

/// How to name a test back to the user: the longest alias they actually typed
/// (echoing their wording), upper-cased if it's a short acronym.
String _displayTestFor(int group, String q) {
  final present =
      _aliasGroups[group].where((a) => _mentionsAlias(q, a)).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  final term = present.isNotEmpty ? present.first : _aliasGroups[group].first;
  return (term.length <= 4 && RegExp(r'^[a-z]+$').hasMatch(term))
      ? term.toUpperCase()
      : term;
}

List<_Hit> _referencedResults(String q, List<CuraDocument> docs) {
  final hits = <_Hit>[];
  for (final d in docs) {
    for (final r in d.results) {
      if (r.needsReview) continue;
      final label = r.label.toLowerCase();
      final group = _groupOf(label);
      var matched = false;
      String key;
      if (group >= 0 && _questionTouchesGroup(q, group)) {
        matched = true;
        key = 'g$group';
      } else {
        key = label;
        // Direct, specific token of the label appearing as a whole word in q.
        for (final tok in label.split(RegExp(r'[^a-z0-9]+'))) {
          if (tok.length < 4 ||
              _matchStopwords.contains(tok) ||
              _nonSpecific.contains(tok)) {
            continue;
          }
          if (RegExp('\\b$tok\\b').hasMatch(q)) {
            matched = true;
            break;
          }
        }
      }
      if (matched) hits.add(_Hit(d, r, key));
    }
  }
  return hits;
}

RoutedAnswer? _tryValueLookup(String q, QueryDate qd, List<CuraDocument> docs) {
  final hits = _referencedResults(q, docs);
  if (hits.isEmpty) {
    // A recognised test with no reading on file: say so plainly rather than let
    // the model invent a number.
    final group = _firstTouchedGroup(q);
    if (group != null) {
      final test = _displayTestFor(group, q);
      return RoutedAnswer(
        'I don\'t see a reading for $test in your records.',
        kind: RoutedAnswerKind.notFound,
        protectedFacts: [test],
      );
    }
    return null;
  }

  // More than one distinct test referenced → ambiguous; let the model handle it.
  final keys = hits.map((h) => h.key).toSet();
  if (keys.length != 1) return null;

  // If the question named a date, keep only readings from that date.
  List<_Hit> scoped = hits;
  if (qd.hasAny) {
    final onDate = hits.where((h) => _dateMatches(h.doc.date, qd)).toList();
    if (onDate.isEmpty) {
      // We do have this test, just not from that date — say so precisely.
      final label = _inSentence(hits.first.result.label);
      final date = _queryDateLabel(qd);
      return RoutedAnswer(
        'I don\'t see a $label reading from $date in your records.',
        kind: RoutedAnswerKind.notFound,
        protectedFacts: [label, date],
      );
    }
    scoped = onDate;
  }

  // Newest first; de-duplicate identical (date,value) readings.
  scoped.sort((a, b) => b.doc.date.compareTo(a.doc.date));
  final seen = <String>{};
  final unique = <_Hit>[];
  for (final h in scoped) {
    final sig = '${h.doc.date.toIso8601String()}|${h.result.valueWithUnit}';
    if (seen.add(sig)) unique.add(h);
  }

  final primary = unique.first;
  final label = _inSentence(primary.result.label);

  // A single reading, or the user asked for the latest one → one clean sentence.
  final wantsSingle = unique.length == 1 || _hasLatest(q) || qd.day != null;
  if (wantsSingle) {
    final clause = _rangeClause(primary.result);
    final protectedRange = primary.result.range?.trim();
    final protectedStatus = _rangeStatusPhrase(primary.result);
    return RoutedAnswer(
      'Your $label on ${primary.doc.dateLabel} was ${primary.result.valueWithUnit}'
      '$clause.',
      kind: RoutedAnswerKind.value,
      protectedFacts: [
        label,
        primary.doc.dateLabel,
        primary.result.valueWithUnit,
        ?protectedRange,
        ?protectedStatus,
      ],
      source: primary.doc,
    );
  }

  // Several readings → a natural enumeration, newest first.
  final shown = unique.take(5).toList();
  final parts = shown
      .map((h) => '${h.result.valueWithUnit} (${h.doc.dateLabel})')
      .toList();
  final more = unique.length > shown.length
      ? ' (and ${unique.length - shown.length} older)'
      : '';
  return RoutedAnswer(
    'Your $label readings, most recent first: ${_joinList(parts)}$more.',
    kind: RoutedAnswerKind.value,
    protectedFacts: [
      label,
      for (final h in shown) ...[h.result.valueWithUnit, h.doc.dateLabel],
      if (unique.length > shown.length) '${unique.length - shown.length}',
    ],
    source: primary.doc,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Latest report
// ─────────────────────────────────────────────────────────────────────────────

bool _hasLatest(String q) =>
    RegExp(r'\b(latest|most recent|recent|last|newest|current)\b').hasMatch(q);

const _collectionIntentWords = {
  'how',
  'many',
  'number',
  'of',
  'do',
  'does',
  'did',
  'i',
  'my',
  'me',
  'have',
  'has',
  'list',
  'show',
  'which',
  'what',
  'all',
  'any',
  'the',
  'a',
  'an',
  'from',
  'in',
  'on',
  'latest',
  'last',
  'newest',
  'recent',
  'most',
  'current',
  'report',
  'reports',
  'record',
  'records',
  'document',
  'documents',
  'test',
  'tests',
  'scan',
  'scans',
  'result',
  'results',
  'function',
};

class _CollectionScope {
  const _CollectionScope(this.docs, {required this.specific});
  final List<CuraDocument> docs;
  final bool specific;
}

/// Matches free-form collections such as "liver function tests" without asking
/// the small model to count. An unknown qualifier deliberately yields no matches
/// instead of silently widening to every saved document.
_CollectionScope _collectionScope(
  String q,
  QueryDate? qd,
  DocumentType? type,
  String? modalityLabel,
  List<CuraDocument> docs,
) {
  final base = _filter(docs, type, qd, modalityLabel: modalityLabel);
  if (type != null || modalityLabel != null) {
    return _CollectionScope(base, specific: false);
  }

  final terms = q
      .split(RegExp(r'[^a-z0-9]+'))
      .where(
        (t) =>
            t.length >= 3 &&
            !_collectionIntentWords.contains(t) &&
            !RegExp(r'^\d+$').hasMatch(t) &&
            !kMonthNames.contains(t),
      )
      .toSet();
  if (terms.isEmpty) return _CollectionScope(base, specific: false);

  final ranked = rankDocuments(q, base);
  final top = ranked.isEmpty ? 0 : ranked.first.score;
  if (top <= 0) return const _CollectionScope([], specific: true);
  final threshold = top <= 2 ? top : (top / 2).ceil();
  return _CollectionScope(
    ranked
        .where((s) => s.score > 0 && s.score >= threshold)
        .map((s) => s.document)
        .toList(),
    specific: true,
  );
}

RoutedAnswer? _tryLatest(
  String q,
  QueryDate qd,
  DocumentType? type,
  String? modalityLabel,
  List<CuraDocument> docs,
) {
  if (!_hasLatest(q)) return null;
  // Needs to be about a document/report/results, not a stray "last" elsewhere.
  if (!RegExp(
        r'\b(report|reports|document|documents|record|records|results?|'
        r'test|tests|scan|scans|prescription|prescriptions|receipt|'
        r'receipts|visit|visits)\b',
      ).hasMatch(q) &&
      type == null) {
    return null;
  }

  final scope = _collectionScope(q, qd, type, modalityLabel, docs);
  // _collectionScope returns a const empty list when a free-form qualifier has
  // no match, so copy before sorting or a miss throws instead of falling through.
  final pool = [...scope.docs]..sort((a, b) => b.date.compareTo(a.date));
  if (pool.isEmpty) {
    final noun = scope.specific
        ? 'matching records'
        : _typeNoun(type, 2, modalityLabel: modalityLabel);
    return RoutedAnswer(
      'I don\'t see any $noun in your records yet.',
      kind: RoutedAnswerKind.notFound,
      protectedFacts: [if (!scope.specific) noun],
    );
  }
  final d = pool.first;
  final results = d.results.isNotEmpty
      ? ' It shows ${_resultsInline(d.results)}.'
      : '';
  return RoutedAnswer(
    'Your most recent ${_typeNoun(type, 1, modalityLabel: modalityLabel)} is '
    '"${d.title}", from ${d.dateLabel}.$results',
    kind: RoutedAnswerKind.latest,
    protectedFacts: [
      d.title,
      d.dateLabel,
      for (final r in d.results.where((r) => !r.needsReview).take(4)) ...[
        r.label,
        r.valueWithUnit,
      ],
    ],
    source: d,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Receipt amounts ("how much did I pay at Meadowlark?")
// ─────────────────────────────────────────────────────────────────────────────

/// A money question needs a payment verb or a bill noun *and* an amount ask,
/// so "show my receipts" still lists and "how much is my hemoglobin" (already
/// consumed by the value lookup) can never reach here by accident.
final _moneyVerbRe = RegExp(
  r'\b(pay|paid|spend|spent|cost|costs?|charged?|charges?|price)\b',
);
final _moneyNounRe = RegExp(r'\b(bills?|receipts?|invoices?|payments?)\b');
final _amountAskRe = RegExp(
  r'\bhow much\b|\btotal\b|\bamount\b|\bwhat (was|is|did)\b',
);

/// The stored breakdown's total: the parser writes it last as "Total"; a
/// hand-edited record may only have some other summary row, which still beats
/// answering nothing. Null when the receipt has no usable amount.
String? _receiptTotal(CuraDocument d) {
  for (final r in d.results.reversed) {
    if (r.needsReview) continue;
    if (isFinalReceiptAmountLabel(r.label)) return r.value;
  }
  for (final r in d.results.reversed) {
    if (r.needsReview) continue;
    if (isReceiptSummaryLabel(r.label)) return r.value;
  }
  return null;
}

RoutedAnswer? _tryReceiptAmount(
  String q,
  QueryDate qd,
  List<CuraDocument> docs,
) {
  if (!_moneyVerbRe.hasMatch(q) && !_moneyNounRe.hasMatch(q)) return null;
  if (!_amountAskRe.hasMatch(q)) return null;

  // Receipts in the asked date window, keyword-narrowed only when the words
  // match something; an unmatched qualifier keeps the full pool.
  var pool = _filter(docs, DocumentType.receipt, qd);
  if (pool.isEmpty) {
    return RoutedAnswer(
      'I don\'t see any receipts${_dateSuffix(qd)} in your records yet.',
      kind: RoutedAnswerKind.notFound,
      protectedFacts: ['receipts', if (qd.hasAny) _queryDateLabel(qd)],
    );
  }
  // Rank on the question minus its money wording, so a generic "bill" can't
  // masquerade as a vendor keyword.
  final rq = q.replaceAll(_moneyNounRe, ' ').replaceAll(_moneyVerbRe, ' ');
  final ranked = rankDocuments(rq, pool);
  if (ranked.isNotEmpty && ranked.first.score > 0) {
    final top = ranked.first.score;
    final threshold = top <= 2 ? top : (top / 2).ceil();
    pool = ranked
        .where((s) => s.score >= threshold)
        .map((s) => s.document)
        .toList();
  }
  pool.sort((a, b) => b.date.compareTo(a.date));

  final priced = [
    for (final d in pool)
      if (_receiptTotal(d) != null) d,
  ];
  // Receipts exist but none carry a parsed amount → the model, with the full
  // document text, is the safer answerer.
  if (priced.isEmpty) return null;

  final wantsLatestOnly = _hasLatest(q);
  if (priced.length == 1 || wantsLatestOnly) {
    final d = priced.first;
    final total = _receiptTotal(d)!;
    return RoutedAnswer(
      'You paid $total for "${d.title}" on ${d.dateLabel}.',
      kind: RoutedAnswerKind.value,
      protectedFacts: [total, d.title, d.dateLabel],
      source: d,
    );
  }

  // Several bills: list each amount, and add the sum when the question sounds
  // aggregate and every amount parses in the same currency style.
  const cap = 6;
  final shown = priced.take(cap).toList();
  final lines = shown
      .map((d) => '• ${d.title}, ${d.dateLabel}: ${_receiptTotal(d)!}')
      .join('\n');
  final more = priced.length > cap ? '\n…and ${priced.length - cap} more.' : '';
  var sumLine = '';
  String? sumText;
  if (RegExp(r'\btotal\b|\baltogether\b|\bin all\b|\boverall\b').hasMatch(q)) {
    final symbols = <String>{};
    var sum = 0.0;
    var parsedAll = true;
    for (final d in priced) {
      final raw = _receiptTotal(d)!;
      final v = double.tryParse(raw.replaceAll(RegExp(r'[^\d.]'), ''));
      if (v == null) {
        parsedAll = false;
        break;
      }
      sum += v;
      symbols.add(raw.startsWith(RegExp(r'[\d.,]')) ? '' : raw[0]);
    }
    if (parsedAll && symbols.length == 1) {
      sumText = '${symbols.first}${_groupThousands(sum.toStringAsFixed(2))}';
      sumLine = '\nAltogether that is $sumText.';
    }
  }
  return RoutedAnswer(
    'You paid for ${priced.length} receipts${_dateSuffix(qd)}:\n'
    '$lines$more$sumLine',
    kind: RoutedAnswerKind.list,
    protectedFacts: [
      '${priced.length}',
      for (final d in shown) ...[d.title, d.dateLabel, _receiptTotal(d)!],
      ?sumText,
    ],
  );
}

/// "3360.00" → "3,360.00" (western grouping — a display nicety only).
String _groupThousands(String fixed) {
  final parts = fixed.split('.');
  final digits = parts[0];
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
    b.write(digits[i]);
  }
  return '$b.${parts[1]}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Count
// ─────────────────────────────────────────────────────────────────────────────

RoutedAnswer? _tryCount(
  String q,
  QueryDate qd,
  DocumentType? type,
  String? modalityLabel,
  List<CuraDocument> docs,
) {
  if (!RegExp(r'\bhow many\b|\bnumber of\b').hasMatch(q)) return null;
  final scope = _collectionScope(q, qd, type, modalityLabel, docs);
  final pool = scope.docs;
  final n = pool.length;
  final noun = scope.specific
      ? (n == 1 ? 'matching record' : 'matching records')
      : _typeNoun(type, n, modalityLabel: modalityLabel);
  // The matching reports, newest first, for the source cards. The set is exact:
  // an unscopable qualifier already yielded an empty pool above.
  final ordered = [...pool]..sort((a, b) => b.date.compareTo(a.date));
  final cards = ordered;
  return RoutedAnswer(
    'You have $n $noun${_dateSuffix(qd)}.',
    kind: RoutedAnswerKind.count,
    protectedFacts: [
      '$n',
      if (!scope.specific) noun,
      if (qd.hasAny) _queryDateLabel(qd),
    ],
    source: cards.isNotEmpty ? cards.first : null,
    sources: cards,
    sourceTotal: n,
    sourcesAreAuthoritative: !scope.specific,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// List / date-specific document
// ─────────────────────────────────────────────────────────────────────────────

const _listKeywords = [
  'list',
  'show me',
  'show my',
  'show all',
  'which',
  'all my',
  'do i have',
  'what do i have',
  'what documents',
  'what reports',
];

RoutedAnswer? _tryListOrDateDoc(
  String q,
  QueryDate qd,
  DocumentType? type,
  String? modalityLabel,
  List<CuraDocument> docs,
) {
  final pluralCollection = RegExp(
    r'\b(prescriptions|receipts|reports|documents|records|medications|'
    r'tests|scans|results|labs)\b',
  ).hasMatch(q);
  // A bare plural is a list request only when a type or modality is named too;
  // vague "my results" falls through to the model.
  final wantsList =
      _listKeywords.any(q.contains) ||
      qd.hasAny ||
      (pluralCollection && type != null) ||
      modalityLabel != null;
  if (!wantsList) return null;

  final scope = _collectionScope(q, qd, type, modalityLabel, docs);
  final pool = scope.docs..sort((a, b) => b.date.compareTo(a.date));

  if (pool.isEmpty) {
    final noun = scope.specific
        ? 'matching records'
        : _typeNoun(type, 2, modalityLabel: modalityLabel);
    return RoutedAnswer(
      'I don\'t see any $noun${_dateSuffix(qd)} in your records.',
      kind: RoutedAnswerKind.notFound,
      protectedFacts: [
        if (!scope.specific) noun,
        if (qd.hasAny) _queryDateLabel(qd),
      ],
    );
  }

  // A single match the user is clearly after (a specific day, or a singular
  // "report") → show that document with its contents.
  final singularAsked =
      qd.day != null ||
      RegExp(
        r'\b(report|document|record|prescription|receipt|summary)\b',
      ).hasMatch(q);
  if (pool.length == 1 && singularAsked) {
    final d = pool.first;
    final results = d.results.isNotEmpty
        ? ' It shows ${_resultsInline(d.results)}.'
        : '';
    return RoutedAnswer(
      'Your ${_typeNoun(type, 1, modalityLabel: modalityLabel)} from '
      '${d.dateLabel} is "${d.title}".$results',
      kind: RoutedAnswerKind.latest,
      protectedFacts: [
        d.title,
        d.dateLabel,
        for (final r in d.results.where((r) => !r.needsReview).take(4)) ...[
          r.label,
          r.valueWithUnit,
        ],
      ],
      source: d,
    );
  }

  const cap = 8;
  final shown = pool.take(cap);
  final lines = shown.map((d) => '• ${d.title}, ${d.dateLabel}').join('\n');
  final more = pool.length > cap ? '\n…and ${pool.length - cap} more.' : '';
  return RoutedAnswer(
    'You have ${pool.length} '
    '${_typeNoun(type, pool.length, modalityLabel: modalityLabel)}'
    '${_dateSuffix(qd)}:\n$lines$more',
    kind: RoutedAnswerKind.list,
    protectedFacts: [
      '${pool.length}',
      for (final d in shown) ...[d.title, d.dateLabel],
      if (pool.length > cap) '${pool.length - cap}',
    ],
    source: pool.isEmpty ? null : pool.first,
    sources: pool,
    sourceTotal: pool.length,
    sourcesAreAuthoritative: !scope.specific,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

List<CuraDocument> _filter(
  List<CuraDocument> docs,
  DocumentType? type,
  QueryDate? qd, {
  String? modalityLabel,
}) {
  return docs.where((d) {
    if (type != null && d.type != type) return false;
    // A named imaging modality ("ultrasound") narrows within the imaging type, so
    // "how many ultrasounds" doesn't count every imaging report.
    if (modalityLabel != null &&
        !documentMatchesModalityLabel(d, modalityLabel)) {
      return false;
    }
    if (qd != null && qd.hasAny && !_dateMatches(d.date, qd)) return false;
    return true;
  }).toList();
}

/// True when [date] is consistent with every part the question pinned down.
bool _dateMatches(DateTime date, QueryDate qd) {
  if (qd.month != null && date.month != qd.month) return false;
  if (qd.year != null && date.year != qd.year) return false;
  if (qd.day != null && date.day != qd.day) return false;
  return true;
}

/// Lowercases a label's first letter for mid-sentence use, but leaves acronyms
/// (LDL, TSH) and mixed-case names (HbA1c) untouched.
String _inSentence(String label) {
  if (label.isEmpty) return label;
  final hasInnerUpper = label.substring(1).contains(RegExp(r'[A-Z]'));
  if (label == label.toUpperCase() || hasInnerUpper) return label;
  return label[0].toLowerCase() + label.substring(1);
}

/// ", within/above/below the normal range (…)" when the range can be parsed,
/// else a neutral "(reference range: …)" — never a guessed judgment.
String _rangeClause(DocumentResult r) {
  final range = r.range;
  if (range == null || range.trim().isEmpty) return '';
  switch (rangeStatus(r.value, range)) {
    case 'within':
      return ', within the normal range ($range)';
    case 'above':
      return ', above the normal range ($range)';
    case 'below':
      return ', below the normal range ($range)';
    default:
      return ' (reference range: $range)';
  }
}

String? _rangeStatusPhrase(DocumentResult r) {
  final range = r.range;
  if (range == null || range.trim().isEmpty) return null;
  switch (rangeStatus(r.value, range)) {
    case 'within':
      return 'within the normal range';
    case 'above':
      return 'above the normal range';
    case 'below':
      return 'below the normal range';
    default:
      return null;
  }
}

/// "Hemoglobin 14.2 g/dL, White blood cells 6.1 ×10⁹/L, …"
String _resultsInline(List<DocumentResult> results, {int cap = 4}) {
  final take = results
      .where((r) => !r.needsReview)
      .take(cap)
      .map((r) => '${r.label} ${r.valueWithUnit}')
      .join(', ');
  return results.length > cap ? '$take, …' : take;
}

/// Singular or plural noun for a document type. A [modalityLabel] wins over the
/// generic noun, so the answer reads "2 ultrasounds", not "2 imaging reports".
String _typeNoun(DocumentType? type, int n, {String? modalityLabel}) {
  final singular = n == 1;
  if (modalityLabel != null) {
    return singular ? modalityLabel : '${modalityLabel}s';
  }
  switch (type) {
    case DocumentType.lab:
      return singular ? 'lab report' : 'lab reports';
    case DocumentType.prescription:
      return singular ? 'prescription' : 'prescriptions';
    case DocumentType.receipt:
      return singular ? 'receipt' : 'receipts';
    case DocumentType.discharge:
      return singular ? 'discharge summary' : 'discharge summaries';
    case DocumentType.imaging:
      return singular ? 'imaging report' : 'imaging reports';
    case DocumentType.visit:
      return singular ? 'visit note' : 'visit notes';
    case null:
      return singular ? 'document' : 'documents';
  }
}

String _dateSuffix(QueryDate qd) =>
    qd.hasAny ? ' from ${_queryDateLabel(qd)}' : '';

const _monthTitles = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "September 3, 2024" / "September 2024" / "September" / "2024".
String _queryDateLabel(QueryDate qd) {
  final month = qd.month != null ? _monthTitles[qd.month! - 1] : null;
  if (month != null && qd.day != null && qd.year != null) {
    return '$month ${qd.day}, ${qd.year}';
  }
  if (month != null && qd.day != null) return '$month ${qd.day}';
  if (month != null && qd.year != null) return '$month ${qd.year}';
  if (month != null) return month;
  return '${qd.year}';
}

/// "a, b and c" — natural list join.
String _joinList(List<String> items) {
  if (items.length <= 1) return items.join();
  if (items.length == 2) return '${items[0]} and ${items[1]}';
  return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}
