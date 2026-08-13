import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/document_repository.dart';
import '../../core/data/providers.dart';
import '../ai/ai_providers.dart';
import '../ai/ai_service.dart';
import '../library/document.dart';
import 'document_shape.dart';
import 'scan_extraction.dart';

/// State values for `CuraDocument.summaryState`.
const kSummaryPending = 'pending';
const kSummaryRetry = 'retry';

/// Rewrite only untouched scraped summaries.
bool needsSummaryRewrite({
  required DocumentType type,
  required String extractedText,
  required String? note,
  String? deterministicNote,
}) {
  if (!isSummaryDocument(type, extractedText) &&
      type != DocumentType.prescription) {
    return false;
  }
  final text = note?.trim() ?? '';
  if (text.isEmpty) return false;
  if (deterministicNote != null && text != deterministicNote.trim()) {
    return false;
  }
  // One sentence is already fine.
  return text.length >= 120;
}

/// Validate one rewrite against its source.
String? acceptSummaryRewrite(String source, String? output) {
  var out = output?.trim() ?? '';
  if (out.isEmpty) return null;
  if (looksLikeModelRefusal(out)) return null;
  if (out.length > source.length * 1.5 + 200) return null;
  final trimmed = trimToLastSentence(out);
  if (trimmed == null) return null;
  out = trimmed;
  // Reject near-empty output.
  if (out.length < 60) return null;
  if (!numbersGrounded(source, out)) return null;
  return out;
}

/// Trim to last sentence end; null if none.
String? trimToLastSentence(String text) {
  if (text.isEmpty) return null;
  if (_sentenceEnders.contains(text[text.length - 1])) return text;
  for (var i = text.length - 1; i >= 0; i--) {
    if (_sentenceEnders.contains(text[i])) return text.substring(0, i + 1);
  }
  return null;
}

const _sentenceEnders = '.!?…';

/// One model call.
typedef SummaryRewriteRequest =
    Future<SummaryRewrite> Function(
      String summary, {
      required DocumentType type,
      String? title,
    });

/// Rewrite saved summaries in the background.
class SummaryRewriter {
  SummaryRewriter(this._repo, this._rewrite);

  final DocumentRepository _repo;
  final SummaryRewriteRequest _rewrite;

  bool _running = false;
  bool _again = false;

  /// Sweep pending documents.
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

  /// Stop when Ask preempts the rewrite.
  Future<bool> _rewriteOne(CuraDocument doc) async {
    final source = doc.resultsNote?.trim() ?? '';
    if (source.isEmpty) {
      // Nothing left to rewrite.
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
    // Retry once, then stop.
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
