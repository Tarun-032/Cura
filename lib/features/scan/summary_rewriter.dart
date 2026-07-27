import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/document_repository.dart';
import '../../core/data/providers.dart';
import '../ai/ai_providers.dart';
import '../ai/ai_service.dart';
import '../library/document.dart';
import 'scan_extraction.dart';

/// State values for `CuraDocument.summaryState`.
const kSummaryPending = 'pending';
const kSummaryRetry = 'retry';

/// Only the scraped narrative summaries read like a dump, and only while they
/// are still exactly what the scan produced: a summary the user rewrote by hand
/// is theirs. [deterministicNote] is what the scan proposed, when known.
bool needsSummaryRewrite({
  required DocumentType type,
  required String? note,
  String? deterministicNote,
}) {
  if (!type.isSummaryShaped && type != DocumentType.prescription) return false;
  final text = note?.trim() ?? '';
  if (text.isEmpty) return false;
  if (deterministicNote != null && text != deterministicNote.trim()) {
    return false;
  }
  // One sentence is already readable; rewriting it only risks losing a word.
  return text.length >= 120;
}

/// Validates one rewrite against the summary it came from, returning the text
/// to keep or null to discard. The model may rephrase, never renumber, and
/// never pad: an output much longer than its source has added something.
String? acceptSummaryRewrite(String source, String? output) {
  var out = output?.trim() ?? '';
  if (out.isEmpty) return null;
  if (looksLikeModelRefusal(out)) return null;
  if (out.length > source.length * 1.5 + 200) return null;
  // Neither backend reports hitting the token cap, so the text is the only
  // evidence. Anything past the last sentence ending was cut off mid-thought.
  if (!_sentenceEnders.contains(out[out.length - 1])) {
    final cut = _lastSentenceEnd(out);
    if (cut < 0) return null;
    out = out.substring(0, cut + 1);
  }
  // A condensed summary is meant to be far shorter than its source, so this is
  // an absolute floor, not a ratio: only a near-empty result is refused.
  if (out.length < 60) return null;
  if (!numbersGrounded(source, out)) return null;
  return out;
}

const _sentenceEnders = '.!?…';

int _lastSentenceEnd(String text) {
  for (var i = text.length - 1; i >= 0; i--) {
    if (_sentenceEnders.contains(text[i])) return i;
  }
  return -1;
}

/// One call to the model, taken as a function so the queue can be tested
/// without one. [AiService.rewriteSummary] is the only implementation.
typedef SummaryRewriteRequest =
    Future<SummaryRewrite> Function(
      String summary, {
      required DocumentType type,
      String? title,
    });

/// Rewrites saved summaries in the background, one at a time. Every document it
/// touches already has a readable deterministic summary, so failing is always
/// an option: the row simply keeps what it has.
class SummaryRewriter {
  SummaryRewriter(this._repo, this._rewrite);

  final DocumentRepository _repo;
  final SummaryRewriteRequest _rewrite;

  bool _running = false;
  bool _again = false;

  /// Works through every pending document. Cheap to call: a sweep already
  /// running just goes round once more when it finishes.
  Future<void> sweep() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      final tried = <String>{};
      while (true) {
        final doc = await _repo.nextPendingSummary(excluding: tried);
        if (doc == null) break;
        tried.add(doc.id);
        if (!await _rewriteOne(doc)) break;
      }
    } finally {
      _running = false;
    }
    if (_again) {
      _again = false;
      await sweep();
    }
  }

  /// False when Ask took the model back, which ends the sweep and leaves the
  /// row pending for the next one.
  Future<bool> _rewriteOne(CuraDocument doc) async {
    final source = doc.resultsNote?.trim() ?? '';
    if (source.isEmpty) {
      // Nothing left to rewrite: the summary was emptied after it was queued.
      await _repo.setSummaryRewrite(doc.id);
      return true;
    }
    final result = await _rewrite(source, type: doc.type, title: doc.title);
    if (result.preempted) return false;
    final kept = acceptSummaryRewrite(source, result.text);
    if (kept != null) {
      await _repo.setSummaryRewrite(doc.id, text: kept);
      return true;
    }
    // A first failure is worth one retry on the next launch; a second is not.
    debugPrint(
      '[Cura.ai] rewrite rejected id=${doc.id} state=${doc.summaryState}',
    );
    await _repo.setSummaryRewrite(
      doc.id,
      state: doc.summaryState == kSummaryPending ? kSummaryRetry : null,
    );
    return true;
  }
}

final summaryRewriterProvider = Provider<SummaryRewriter>((ref) {
  return SummaryRewriter(
    ref.watch(documentRepositoryProvider),
    ref.watch(aiServiceProvider).rewriteSummary,
  );
});
