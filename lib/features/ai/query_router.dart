import '../library/document.dart';
import '../library/result_range.dart';
import '../scan/receipt_parser.dart'
    show isFinalReceiptAmountLabel, isReceiptSummaryLabel;
import 'retrieval.dart';

/// A natural-language answer from structured documents.
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

  /// Matching source cards, newest first.
  final List<CuraDocument> sources;

  /// Total matching reports.
  final int sourceTotal;

  /// True when the sources are exact matches.
  final bool sourcesAreAuthoritative;

  /// Short answers use less room.
  int get rewriteMaxTokens => kind == RoutedAnswerKind.list ? 192 : 96;
}

/// Use the router only for local answers.
bool shouldUseQueryRouter({required bool cloudActive}) => !cloudActive;

/// Prompt for a plain rewrite.
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

/// Reject a rewrite that drops facts or adds numbers.
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

/// Answer from structured fields only.
RoutedAnswer? routeQuestion(String question, List<CuraDocument> docs) {
  if (docs.isEmpty) return null;
  final q = question.toLowerCase().trim();
  if (q.isEmpty) return null;

  final qd = parseQueryDate(question);
  final personal = _isPersonal(q) || qd.hasAny;

  // Send reasoning to the model.
  if (_needsReasoning(q)) return null;
  // Keep definitions off the fast path.
  if (!personal && _looksLikeDefinition(q)) return null;

  final type = detectDocumentType(q);
  // Keep imaging modality questions narrow.
  final modalityLabel = type == DocumentType.imaging
      ? namedImagingModalityLabel(q)
      : null;

  // Order matters for value and count questions.
  return _tryValueLookup(q, qd, docs) ??
      _tryReceiptAmount(q, qd, docs) ??
      _tryLatest(q, qd, type, modalityLabel, docs) ??
      _tryCount(q, qd, type, modalityLabel, docs) ??
      _tryListOrDateDoc(q, qd, type, modalityLabel, docs);
}

// ─────────────────────────────────────────────────────────────────────────────
// Guards
// ─────────────────────────────────────────────────────────────────────────────

/// Phrases that need reasoning.
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

/// A general definition request.
bool _looksLikeDefinition(String q) =>
    RegExp(r'\bwhat\s+(is|are|does)\b').hasMatch(q);

/// The question is about the user's records.
bool _isPersonal(String q) =>
    RegExp(r'\b(my|mine|me|i)\b').hasMatch(q) ||
    RegExp(r'\b(was|were|had)\b').hasMatch(q);

// ─────────────────────────────────────────────────────────────────────────────
// Document type
// ─────────────────────────────────────────────────────────────────────────────

// Shared with retrieval.dart.

// ─────────────────────────────────────────────────────────────────────────────
// Test-value lookup
// ─────────────────────────────────────────────────────────────────────────────

/// Synonym groups for the same measure.
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
  // Red cell indices and the differential.
  ['hematocrit', 'haematocrit', 'pcv', 'packed cell volume'],
  ['mcv'],
  ['mchc'],
  ['mch'],
  ['rdw'],
  ['neutrophil'],
  ['lymphocyte'],
  ['eosinophil'],
  ['monocyte'],
  ['basophil'],
  // Rest of the liver panel.
  ['ggt', 'gamma gt', 'gamma glutamyl'],
  ['ldh', 'lactate dehydrogenase'],
  // Iron studies.
  ['ferritin'],
  ['tibc', 'total iron binding'],
  ['iron'],
  // Thyroid, beyond TSH.
  ['ft3', 'free t3'],
  ['ft4', 'free t4'],
  ['t3', 'triiodothyronine'],
  ['t4', 'thyroxine'],
  // Lipids, beyond the three above.
  ['vldl'],
  ['non-hdl', 'non hdl'],
  // Kidney, beyond creatinine.
  ['egfr', 'gfr'],
  ['microalbumin'],
  ['phosphorus', 'phosphate'],
  ['magnesium'],
  ['amylase'],
  ['lipase'],
  ['crp', 'c reactive protein', 'c-reactive'],
  ['psa', 'prostate specific'],
  ['insulin'],
  ['homocysteine'],
  ['inr', 'prothrombin'],
  // Own measure (not haemoglobin).
  ['hbsag', 'hbs ag', 'hepatitis b surface'],
  ['blood pressure'],
  ['heart rate', 'pulse'],
  ['dose', 'dosage'],
  ['frequency'],
  ['duration'],
];

/// Label stopwords that alone do not match.
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

/// Matched (doc, result) with a canonical test key.
class _Hit {
  _Hit(this.doc, this.result, this.key);
  final CuraDocument doc;
  final DocumentResult result;
  final String key;
}

/// Drop dots so "S.G.P.T" matches "SGPT".
String _dedot(String s) => s.replaceAll('.', '');

/// Public alias-group lookup (e.g. Trends).
int aliasGroupOf(String label) => _groupOf(label.toLowerCase());

/// Stable canonical name for a group.
String aliasGroupName(int group) => _aliasGroups[group].first;

/// Alias-group index, or -1.
int _groupOf(String labelLower) => _bestGroup(_dedot(labelLower));

/// Word-boundary alias start; plurals still match.
bool _mentionsAlias(String dq, String alias) => _aliasAt(dq, alias) >= 0;

/// Alias start index in [dq], or -1.
int _aliasAt(String dq, String alias) =>
    RegExp('\\b${RegExp.escape(alias)}').firstMatch(dq)?.start ?? -1;

/// Earliest alias group; longest alias wins ties.
int _bestGroup(String dedotted) {
  var best = -1;
  var bestAt = 1 << 30;
  var bestLen = 0;
  for (var i = 0; i < _aliasGroups.length; i++) {
    for (final t in _aliasGroups[i]) {
      final at = _aliasAt(dedotted, t);
      if (at < 0) continue;
      if (at < bestAt || (at == bestAt && t.length > bestLen)) {
        best = i;
        bestAt = at;
        bestLen = t.length;
      }
    }
  }
  return best;
}

bool _questionTouchesGroup(String q, int group) {
  if (group < 0) return false;
  final dq = _dedot(q);
  return _aliasGroups[group].any((a) => _mentionsAlias(dq, a));
}

/// Best alias group for the question, or null.
int? _firstTouchedGroup(String q) {
  final group = _bestGroup(_dedot(q));
  return group < 0 ? null : group;
}

/// Echo the user's longest typed alias.
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
        // Whole-word label token in q.
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
    // Known test, no reading — say so.
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

  // Multiple tests → model.
  final keys = hits.map((h) => h.key).toSet();
  if (keys.length != 1) return null;

  // Filter to named date.
  List<_Hit> scoped = hits;
  if (qd.hasAny) {
    final onDate = hits.where((h) => _dateMatches(h.doc.date, qd)).toList();
    if (onDate.isEmpty) {
      // Have the test, not that date.
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

  // Newest first; dedupe date+value.
  scoped.sort((a, b) => b.doc.date.compareTo(a.doc.date));
  final seen = <String>{};
  final unique = <_Hit>[];
  for (final h in scoped) {
    final sig = '${h.doc.date.toIso8601String()}|${h.result.valueWithUnit}';
    if (seen.add(sig)) unique.add(h);
  }

  final primary = unique.first;
  final label = _inSentence(primary.result.label);

  // Single/latest → one sentence.
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

  // Several → list, newest first.
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

/// Free-form collection scope; unknown qualifier → no match.
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

  // Prefer queryTerms so stopwords aren't qualifiers.
  final terms = queryTerms(q)
      .where(
        (t) =>
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
  // Must be about a report, not a stray "last".
  if (!RegExp(
        r'\b(report|reports|document|documents|record|records|results?|'
        r'test|tests|scan|scans|prescription|prescriptions|receipt|'
        r'receipts|visit|visits)\b',
      ).hasMatch(q) &&
      type == null) {
    return null;
  }

  final scope = _collectionScope(q, qd, type, modalityLabel, docs);
  // Copy: empty const list from a miss can't be sorted.
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

/// Money ask: payment/bill word + amount ask.
final _moneyVerbRe = RegExp(
  r'\b(pay|paid|spend|spent|cost|costs?|charged?|charges?|price)\b',
);
final _moneyNounRe = RegExp(r'\b(bills?|receipts?|invoices?|payments?)\b');
final _amountAskRe = RegExp(
  r'\bhow much\b|\btotal\b|\bamount\b|\bwhat (was|is|did)\b',
);

/// Receipt total (or best summary row); null if none.
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

  // Date window; keyword-narrow only on hits.
  var pool = _filter(docs, DocumentType.receipt, qd);
  if (pool.isEmpty) {
    return RoutedAnswer(
      'I don\'t see any receipts${_dateSuffix(qd)} in your records yet.',
      kind: RoutedAnswerKind.notFound,
      protectedFacts: ['receipts', if (qd.hasAny) _queryDateLabel(qd)],
    );
  }
  // Rank without money words as vendor keywords.
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
  // No parsed amount → model.
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

  // List amounts; sum if aggregate + same currency.
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

/// "3360.00" → "3,360.00".
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
  // Matching reports, newest first.
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
  // Plural list needs a type/modality.
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

  // One clear match → show it.
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
    // Narrow imaging by modality.
    if (modalityLabel != null &&
        !documentMatchesModalityLabel(d, modalityLabel)) {
      return false;
    }
    if (qd != null && qd.hasAny && !_dateMatches(d.date, qd)) return false;
    return true;
  }).toList();
}

/// [date] matches every pinned date part.
bool _dateMatches(DateTime date, QueryDate qd) {
  if (qd.month != null && date.month != qd.month) return false;
  if (qd.year != null && date.year != qd.year) return false;
  if (qd.day != null && date.day != qd.day) return false;
  return true;
}

/// Sentence-case label; leave acronyms alone.
String _inSentence(String label) {
  if (label.isEmpty) return label;
  final hasInnerUpper = label.substring(1).contains(RegExp(r'[A-Z]'));
  if (label == label.toUpperCase() || hasInnerUpper) return label;
  return label[0].toLowerCase() + label.substring(1);
}

/// Range clause; never guess a judgment.
String _rangeClause(DocumentResult r) {
  final range = r.range;
  if (range == null || range.trim().isEmpty) return '';
  // Prefer band name over long interval.
  final band = bandFor(r);
  final shown = band?.name ?? rangeText(r) ?? range;
  final phrase = _rangeStatusPhrase(r);
  if (phrase != null) return ', $phrase ($shown)';
  if (band != null) return ' ($shown)';
  return ' (reference range: $shown)';
}

String? _rangeStatusPhrase(DocumentResult r) {
  if (r.range == null || r.range!.trim().isEmpty) return null;
  return switch (verdictFor(r)) {
    RangeVerdict.inRange => 'within the normal range',
    RangeVerdict.high => 'above the normal range',
    RangeVerdict.low => 'below the normal range',
    RangeVerdict.unknown => null,
  };
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

/// Type noun; [modalityLabel] wins if set.
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

/// Human date from pinned parts.
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

/// "a, b and c".
String _joinList(List<String> items) {
  if (items.length <= 1) return items.join();
  if (items.length == 2) return '${items[0]} and ${items[1]}';
  return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}
