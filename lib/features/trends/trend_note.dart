import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_providers.dart';
import '../ai/ai_service.dart';
import '../library/document.dart';
import '../library/result_range.dart';
import '../scan/scan_extraction.dart';
import '../scan/summary_rewriter.dart';
import 'trend_series.dart';

const kTrendNotesKey = 'cura_trend_notes';

/// Bump to redo notes after prompt changes.
const _kPromptVersion = 4;

/// Model input: measure + readings (lowercase; no report titles).
String trendFacts(TrendSeries s) {
  final unit = s.unit?.trim() ?? '';
  final range = rangeText(s.latest.result);
  final out = StringBuffer('measure: ${s.label.trim().toLowerCase()}');
  if (unit.isNotEmpty) out.write('\nunit: $unit');
  if (range != null) out.write('\nnormal range: $range');
  out.write('\nreadings: ${s.points.length}, oldest first');
  for (final p in s.points) {
    final standing = _standing(p.result);
    // Keep each reading's own unit; never convert.
    final u = p.unit?.trim() ?? '';
    out.write(
      '\n${p.dateLabel.toLowerCase()}, ${p.date.year} = ${_printed(p)}',
    );
    if (u.isNotEmpty) out.write(' $u');
    if (standing != null) out.write(' ($standing)');
  }
  return out.toString();
}

/// Verdict, band, or in-range.
String? _standing(DocumentResult r) {
  final note = verdictNote(r);
  if (note != null) return note.toLowerCase();
  return verdictFor(r) == RangeVerdict.inRange ? 'in range' : null;
}

/// Number as the lab printed it.
String _printed(TrendPoint p) =>
    RegExp(r'^[\d,]+(?:\.\d+)?').firstMatch(p.result.value.trim())?[0] ??
    '${p.value}';

/// Longest note we keep.
const _kMaxChars = 900;

/// Shorter than this explains nothing.
const _kMinChars = 90;

/// Validate one note against its facts.
String? acceptTrendNote(String facts, String? output) {
  var out = output?.trim() ?? '';
  if (out.isEmpty || looksLikeModelRefusal(out)) return null;
  // Incomplete sentence → reject.
  final ended = _withoutClosers(out);
  if (trimToLastSentence(ended) != ended) return null;
  if (out.length > _kMaxChars) {
    final head = trimToLastSentence(out.substring(0, _kMaxChars));
    if (head == null) return null;
    out = head;
  }
  if (out.length < _kMinChars) return null;
  // A model may phrase, never renumber.
  if (!_grounded(facts, out)) return null;
  return out;
}

/// Strip trailing closers after a sentence end.
String _withoutClosers(String s) =>
    s.replaceFirst(RegExp('["\'”’)\\]]+\$'), '');

/// Every number in [note] must appear in [facts] (or be a reading count).
bool _grounded(String facts, String note) {
  final known = _numbersIn(facts);
  // Allow in-range counts ≤ reading count.
  final readings = _readingCount(facts);
  return _numbersIn(note).every(
    (n) => known.contains(n) || (n <= readings && n == n.roundToDouble()),
  );
}

int _readingCount(String facts) =>
    int.tryParse(RegExp(r'readings: (\d+)').firstMatch(facts)?[1] ?? '') ?? 0;

Set<double> _numbersIn(String text) => {
  for (final m in RegExp(r'\d[\d,]*(?:\.\d+)?').allMatches(text))
    ?double.tryParse(m[0]!.replaceAll(',', '')),
};

/// One model call.
typedef TrendNoteRequest = Future<SummaryRewrite> Function(String facts);

/// Provider refusal; show [message] as-is.
class TrendNoteFailure implements Exception {
  const TrendNoteFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Cache notes by facts + engine; regenerate on change.
class TrendNarrator {
  TrendNarrator(this._explain, this._engineTag);

  final TrendNoteRequest _explain;
  final Future<String> Function() _engineTag;

  Future<String?> noteFor({required String key, required String facts}) async {
    final prefs = await SharedPreferences.getInstance();
    final store = _read(prefs);
    final sig = '$_kPromptVersion|${await _engineTag()}|$facts';
    final hit = store[key];
    if (hit is Map && hit['sig'] == sig) return hit['text'] as String?;

    final result = await _explain(facts);
    // Provider refused — surface reason, don't hammer retry.
    if (result.error != null) throw TrendNoteFailure(result.error!);
    var kept = acceptTrendNote(facts, result.text);
    // One retry on bad answer; preempt stops.
    if (kept == null && !result.preempted) {
      final again = await _explain(facts);
      if (again.error != null) throw TrendNoteFailure(again.error!);
      kept = acceptTrendNote(facts, again.text);
    }
    // Rejected → uncached for next open.
    if (kept == null) return null;

    store[key] = {'sig': sig, 'text': kept};
    // ponytail: clears wholesale past 60 measures; per-key pruning if it bites.
    await prefs.setString(
      kTrendNotesKey,
      jsonEncode(store.length > 60 ? {key: store[key]} : store),
    );
    return kept;
  }

  Map<String, dynamic> _read(SharedPreferences prefs) {
    final raw = prefs.getString(kTrendNotesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }
}

final trendNarratorProvider = Provider<TrendNarrator>((ref) {
  final ai = ref.watch(aiServiceProvider);
  return TrendNarrator(ai.explainTrend, ai.engineTag);
});

/// Value-keyed so rebuilds reuse unchanged calls.
typedef TrendNoteKey = ({String key, String facts});

final trendNoteProvider = FutureProvider.autoDispose
    .family<String?, TrendNoteKey>(
      (ref, req) => ref
          .watch(trendNarratorProvider)
          .noteFor(key: req.key, facts: req.facts),
    );
