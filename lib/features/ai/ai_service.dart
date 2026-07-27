import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../library/document.dart';
import '../scan/scan_extraction.dart';
import '../scan/scan_service.dart';
import '../scan/table_parser.dart';
import 'ai_model_manager.dart';
import 'ai_models.dart';
import 'chat_format.dart';
import 'query_router.dart';
import 'remote/cloud_privacy_gate.dart';
import 'remote/remote_ai_config.dart';
import 'remote/remote_ai_store.dart';
import 'remote/remote_chat_backend.dart';
import 'retrieval.dart';

/// One update from [AiService.answerQuestionStream]. [text] grows token-by-token
/// and [done] marks the last event. [thinking] carries a reasoning model's
/// `<think>…</think>` chain, which fills first and freezes when the answer starts.
class AskChunk {
  const AskChunk(
    this.text, {
    this.thinking = '',
    this.source,
    this.sources = const [],
    this.sourceTotal = 0,
    this.done = false,
  });
  final String text;
  final String thinking;
  final CuraDocument? source;

  /// Source cards for a multi-match answer, newest first. Empty when [source]
  /// carries the single match. [sourceTotal] drives the "+N more" affordance.
  final List<CuraDocument> sources;
  final int sourceTotal;
  final bool done;
}

/// Result of splitting the raw model output into its reasoning and answer parts.
class _ParsedAnswer {
  const _ParsedAnswer(this.thinking, this.answer);
  final String thinking;
  final String answer;
}

enum ScanExtractionMode { metadata, receipt, tableRepair }

/// Stops a streaming backend: `stop()` locally, `close()` on the cloud client.
/// Attaching after a cancel fires at once, covering a stop during model load.
class GenerationCancellation {
  bool cancelled = false;
  void Function()? _stop;
  final _done = Completer<void>();

  /// Completes on [cancel]. See [untilCancelled].
  Future<void> get done => _done.future;

  void attach(void Function() stop) {
    _stop = stop;
    if (cancelled) stop();
  }

  void detach() => _stop = null;

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _stop?.call();
    _done.complete();
  }
}

/// Ends [source] on cancel: `LlamaController.stop()` leaves its token stream
/// open, so waiting for the backend to close it hangs forever.
Stream<T> untilCancelled<T>(
  Stream<T> source,
  GenerationCancellation? cancellation,
) {
  if (cancellation == null) return source;
  final out = StreamController<T>();
  final sub = source.listen(
    out.add,
    onError: out.addError,
    onDone: () {
      if (!out.isClosed) out.close();
    },
  );
  cancellation.done.whenComplete(() {
    if (!out.isClosed) out.close();
  });
  out.onCancel = sub.cancel;
  return out.stream;
}

/// Runs the model for Ask and for optional background refinement of a fresh scan
/// ([startDocumentRefinement]). Scans are filled deterministically first; the
/// model only fills declared gaps, and every repaired number is tied to an OCR
/// cell. The model loads once and stays warm; each request gets a fresh chat.
class AiService {
  AiService(
    this._manager,
    this._remote, {
    RemoteChatBackend Function(RemoteAiConfig config)? remoteBackendFactory,
  }) : _remoteBackendFactory =
           remoteBackendFactory ?? ((config) => RemoteChatBackend(config));

  final AiModelManager _manager;
  final RemoteAiStore _remote;
  final RemoteChatBackend Function(RemoteAiConfig config) _remoteBackendFactory;

  LlamaController? _ctrl;
  AiModel? _spec;
  int _layers = 0;

  // What sits in the warm KV cache, so a follow-up appends only its new turn.
  // Kept in lock-step with the native cache; any mismatch forces a rebuild.
  String? _kvSystem; // system prompt at the cache base (null = empty/dirty)
  String?
  _kvConvId; // chat/session id whose turns sit on top (null = base only)
  bool _kvOpenAnswer = false; // cache ends mid-answer (needs a close next turn)
  int _kvTokensEst = 0; // running token estimate, for the overflow guard

  /// Minimum answer room (tokens) to keep free before we'll reuse the cache
  /// rather than rebuild — so prompt + answer never overflow the window.
  static const _kAnswerHeadroom = 128;

  /// ~3.5 chars/token is a safe overestimate for English (errs toward headroom).
  int _estTokens(String s) => (s.length / 3.5).ceil();

  /// Clears the native KV cache AND resets the tracker together — the single
  /// choke point that keeps the two in sync. Resilient: never throws.
  Future<void> _clearKv() async {
    try {
      await _ctrl?.clearContext();
    } catch (_) {}
    _kvSystem = null;
    _kvConvId = null;
    _kvOpenAnswer = false;
    _kvTokensEst = 0;
  }

  /// Halts llama.cpp. Cancelling the Dart subscription alone would not.
  void _stopLocal() {
    final ctrl = _ctrl;
    if (ctrl != null) unawaited(ctrl.stop());
  }

  /// Drops the warm cache. Ask calls this after editing a question, since the
  /// cache still holds the turn that was removed.
  Future<void> resetConversationCache() => _clearKv();

  /// Answer ceiling for the cloud engine. No small context window to clamp
  /// against, and the provider still stops at the model's end-of-turn token.
  static const _remoteMaxTokens = 1024;

  // On-device system prompt. Lean on purpose: prefill cost scales with prompt
  // length on a phone CPU. The cloud model gets the fuller [_systemPromptRemote].
  static const _systemPrompt =
      'You are Cura, the user\'s on-device medical assistant. Answer briefly, in '
      'plain language, and only about health or the documents below — for anything '
      'unrelated, say you only help with medical topics. Use the documents, '
      'copying values and dates exactly; if a detail is not there, say you don\'t '
      'see it. You may use earlier messages. Keep answers to a sentence or two '
      'unless asked to explain in detail. For a pure greeting, greet warmly as '
      'Cura and invite the user to ask about their records. Never help with '
      'self-harm, violence, or drug misuse. You explain, not diagnose; this is '
      'not medical advice.';

  // Cloud system prompt: fuller than the local one, since prefill cost is a
  // non-issue over the network. FORMATTING matches the app's small Markdown
  // renderer (bold, "### ", "- " bullets, no tables) — see ask_screen.
  static const _systemPromptRemote =
      'You are Cura — a warm, precise medical assistant that helps the user '
      'understand their own health records. You organize and explain; you do not '
      'diagnose or prescribe and are not a substitute for a clinician.\n\n'
      'GREETING: Only when the user\'s message is purely a greeting (e.g. "hi", '
      '"hello"), introduce yourself in one line — "I\'m Cura, your medical '
      'assistant" — and invite them to ask about their reports. For any real '
      'question, answer directly; never introduce yourself or open with "I\'m '
      'Cura".\n\n'
      'SCOPE: Answer only questions about health, medicine, and the user\'s '
      'documents. Politely decline anything unrelated (coding, trivia, opinions) '
      'in one line and steer back to their health.\n\n'
      'RECORDS: When records are supplied, rely on them and copy every title, '
      'value, date and result exactly as written — never rephrase or invent facts. '
      'Privacy-safe generic record titles may replace identifying facility, vendor, '
      'or person names; use the supplied safe title exactly. The '
      '"Complete record inventory" section is the exhaustive list of every record '
      'on file; use it for counting, listing, comparing, and latest/oldest '
      'questions. The "Relevant report details" section holds the fuller medical '
      'contents of the report being discussed. If something is not in the records, '
      'say so plainly.\n\n'
      'COUNTING: Treat every inventory entry as one distinct record. Never merge, '
      'skip, or double-count entries that share a date or a similar title. The '
      'count is exactly the number of matching entries — state that number, then '
      'list them. For a topical question (e.g. "TB-related", "kidney", "heart"), a '
      'report can be relevant through its findings even when its title does not '
      'name the topic — weigh each record\'s title and any supplied details. If '
      'you can only see titles and cannot confirm a report\'s contents, count what '
      'clearly matches and say the total may be approximate rather than guessing.\n\n'
      'CONSISTENCY: Your answers must be stable and evidence-based. If the user '
      'pushes back ("are you sure?", "that seems wrong"), re-check the Complete '
      'record inventory carefully before replying. If it confirms your answer, say '
      'it is correct and briefly show the entries you counted — do NOT raise or '
      'lower a count merely to agree with the user. Revise only when the records '
      'genuinely show otherwise, and then state plainly what you had missed. Never '
      'give two different counts for the same question in one conversation unless '
      'the records themselves changed.\n\n'
      'CONVERSATION: Resolve natural follow-ups such as "latest one", "the other '
      'one", and "explain this" from the prior messages and supplied records. '
      'Never describe internal context selection, claim a supplied report is '
      'unavailable, or say you cannot explain a report that is shown. Ask which '
      'report only when the reference is genuinely ambiguous.\n\n'
      'FORMATTING (the app renders a small Markdown subset — follow it exactly):\n'
      '- Open a list answer with a one-line summary (e.g. "You have 4 bills:"), '
      'then the list.\n'
      '- Use "- " bullet lines for any list. Start each bullet with the record\'s '
      'title in **bold**, then details separated by " — ", e.g. '
      '"- **Receipt** — Jan 21, 2026 — ₹1,956.00".\n'
      '- Use **bold** to highlight the key figure in a short answer (a value, a '
      'date, a count). You may open a longer answer with a "### " sub-heading.\n'
      '- NEVER use a Markdown table, "|" pipe characters, HTML, or images — they '
      'show up as raw text.\n\n'
      'LENGTH: Answer briefly by default (about 2–4 sentences or a short list). '
      'Give a longer, step-by-step explanation only when the user explicitly asks '
      'to explain in detail, elaborate, or go in depth.\n\n'
      'SAFETY: Never give instructions or encouragement for self-harm or suicide, '
      'violence or weapons, or misusing drugs. If the user expresses thoughts of '
      'self-harm, respond with empathy and urge them to contact a doctor or a '
      'local crisis line right away.';

  // Appended when the user has no saved documents, so the model says so itself.
  static const _noDocsNote =
      ' No documents are saved yet. If asked about their records, say there are '
      'none yet and to add a report and ask again; otherwise answer the health '
      'question normally.';

  /// Note appended when the user asks about a document they don't have on file,
  /// so the model says so instead of describing an unrelated one. [label] is the
  /// missing document's human name (from Grounding.missingLabel).
  static const _kNoThinkPrefill = '<think>\n\n</think>\n\n';

  static String _missingTypeNote(String label) =>
      ' Note: the user is asking about a ${label.toLowerCase()}, but no such '
      'document is in their records. Tell them it isn\'t on file; do not answer '
      'from an unrelated document.';

  /// Note appended when several real candidate reports are attached and the model
  /// must resolve which one the user means (GroundingKind.focusResolve). It can
  /// only pick among them, never merge them or call one "missing".
  static const _focusResolveNote =
      ' Note: several of the user\'s reports are shown below and ALL of them exist '
      'on file. Using the conversation so far, work out which single report they '
      'are referring to (e.g. "the other one", "the earlier scan") and answer about '
      'that one, naming its title and date. Never say any of the shown reports is '
      'missing or an error. If it is genuinely unclear, briefly ask which one.';

  /// A collection request is deliberately different from focus resolution: the
  /// user asked for several reports, so choosing one would silently omit data.
  static const _collectionNote =
      ' Note: the user requested the reports shown below as a group. Cover EVERY '
      'shown report and use the supplied details for each one. Keep their dates '
      'and contents distinct. Do not choose only one, and do not say a shown '
      'report\'s details are unavailable.';

  /// Note naming the same-kind reports that were not attached
  /// ([Grounding.otherReports]), so the model doesn't call a sibling it half
  /// remembers from the chat "missing" or "an error".
  static String _otherReportsNote(List<CuraDocument> others) {
    final items = others
        .map((d) => '"${d.title}" (${d.dateLabel})')
        .toList(growable: false);
    return ' Note: the user also has ${_naturalList(items)} on file — these reports '
        'DO exist and may already have been discussed. Answer about the report '
        'shown below (the one they asked for). Never say another of their reports '
        'is missing, unavailable, or an error; you may offer to explain the others.';
  }

  /// Infers which candidate a [GroundingKind.focusResolve] answer explained, for
  /// the source card only. Scores each candidate on how much of its title/date the
  /// answer echoes and needs a clear match (≥2); returns null when unsure.
  static CuraDocument? _sourceFromAnswer(
    String answer,
    List<CuraDocument> candidates,
  ) {
    if (candidates.isEmpty) return null;
    final a = answer.toLowerCase();
    CuraDocument? best;
    var bestScore = 0;
    for (final d in candidates) {
      var s = 0;
      final date = d.dateLabel.toLowerCase();
      if (date.isNotEmpty && a.contains(date)) s += 2;
      for (final tok in d.title.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
        if (tok.length >= 5 && a.contains(tok)) s += 1;
      }
      if (s > bestScore) {
        bestScore = s;
        best = d;
      }
    }
    return bestScore >= 2 ? best : null;
  }

  /// "a, b and c" — a natural list join.
  static String _naturalList(List<String> items) {
    if (items.length <= 1) return items.join();
    if (items.length == 2) return '${items[0]} and ${items[1]}';
    return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
  }

  /// Answers [question] grounded in [docs], streaming the reply token-by-token.
  /// Source is chosen by retrieval (the best-matching document), not the model,
  /// so it's known before generation and carried on every chunk. Reuses the warm
  /// model. Emits a single graceful chunk on empty input or any failure.
  ///
  /// The router computes exact factual/value/date/list answers locally. In local
  /// mode a tiny buffered model pass rewrites that verified answer naturally; an
  /// invalid rewrite falls back to the exact text. Cloud bypasses the router.
  ///
  /// [history] is the prior conversation (oldest→newest), giving the session
  /// memory for follow-ups. Only a bounded slice is used — see [_boundedHistory].
  ///
  /// [cancellation] stops the answer mid-flight; the partial still arrives.
  Stream<AskChunk> answerQuestionStream(
    String question,
    List<CuraDocument> docs, {
    List<({String role, String text})> history = const [],
    String? conversationId,
    Set<String> shownSourceIds = const {},
    Set<String> focusDocIds = const {},
    List<String> orderedFocusDocIds = const [],
    GenerationCancellation? cancellation,
  }) async* {
    final q = question.trim();
    if (q.isEmpty) {
      yield const AskChunk('', done: true);
      return;
    }

    // Which engine answers: the opt-in cloud model, or the on-device one.
    final useRemote = await _remote.remoteActive();

    // The router exists to make tiny on-device models fast and exact. A cloud
    // model handles every turn itself, so it skips the router entirely.
    RoutedAnswer? routed;
    if (shouldUseQueryRouter(cloudActive: useRemote)) {
      routed = routeQuestion(q, docs);
      if (routed != null) {
        debugPrint(
          '[Cura.ai] routed kind=${routed.kind.name} '
          'hasSource=${routed.source != null}',
        );
      }
    }

    // A model is needed from here on. The cloud engine needs no local download;
    // the local one does, so say that plainly rather than failing generically.
    if (!useRemote && await _manager.installedModel() == null) {
      if (routed != null) {
        yield AskChunk(
          routed.text,
          source: routed.source,
          sources: routed.sources,
          sourceTotal: routed.sourceTotal,
          done: true,
        );
        return;
      }
      yield const AskChunk(
        'Set up a model first. Open Settings to download a model or connect a '
        'cloud model, then I can answer general questions too.',
        done: true,
      );
      return;
    }

    // Shared prompt shaping, engine-independent: [groundingFor] decides which
    // document (if any) grounds this question, and flags a named type that isn't
    // on file so the model says so rather than using an unrelated document.
    final g = routed == null
        ? groundingFor(
            q,
            docs,
            shownSourceIds: shownSourceIds,
            focusDocIds: focusDocIds,
            orderedFocusDocIds: orderedFocusDocIds,
          )
        : const Grounding(GroundingKind.none);

    // Grounding trace: kind, cited source, focus context and candidates, so a
    // wrong pick is diagnosable from one logcat line.
    if (routed == null) {
      debugPrint(
        '[Cura.ai] grounding kind=${g.kind.name} '
        'hasSource=${g.source != null} '
        'missing=${g.missingLabel ?? '-'} focus=$focusDocIds '
        'orderedFocus=$orderedFocusDocIds '
        'shown=$shownSourceIds '
        'candidates=${g.contextDocs.length}',
      );
    }

    final contextDocs = g.contextDocs;
    final source = routed?.source ?? g.source;
    // focusResolve lets the model pick among the attached reports, so the cited
    // source is inferred from the finished answer. Empty on every other path.
    final resolveCandidates = g.kind == GroundingKind.focusResolve
        ? contextDocs
        : const <CuraDocument>[];

    // Cloud gets minimized context: structured fields plus an allowlisted medical
    // excerpt, then [redactForCloud]. On-device sends a fuller OCR excerpt.
    const privacyGate = CloudPrivacyGate();
    final cloudIdentityTerms = useRemote
        ? privacyGate.identityTermsForDocuments(docs)
        : const <String>{};
    final detailedContext = contextDocs.isEmpty
        ? ''
        : (useRemote
              ? privacyGate.buildContext(contextDocs).text
              : buildContext(contextDocs));
    // A cloud record question also gets the safe inventory, for the global view
    // needed to count and compare. Both sections go through the PII scrubber.
    final inventory = useRemote && g.kind != GroundingKind.none
        ? privacyGate.buildInventory(docs).text
        : '';
    final safeQuestion = useRemote
        ? privacyGate
              .userMessage(q, knownIdentityTerms: cloudIdentityTerms)
              .content
        : q;
    final remoteQuestion = safeQuestion.isNotEmpty
        ? safeQuestion
        : 'Answer the health-record question using the supplied records. If the '
              'removed identifying details were essential, ask the user to rephrase '
              'without them.';
    final contextParts = <String>[
      if (inventory.isNotEmpty) inventory,
      if (detailedContext.isNotEmpty)
        'Relevant report details:\n$detailedContext',
    ];
    final userContent = routed != null
        ? buildVerifiedRewritePrompt(q, routed)
        : contextParts.isEmpty
        ? remoteQuestion
        : '${contextParts.join('\n\n')}\n\nQuestion: $remoteQuestion';
    // Different brief per engine: cloud takes the fuller scope/safety prompt,
    // on-device stays lean for prefill speed.
    final enginePrompt = useRemote ? _systemPromptRemote : _systemPrompt;
    // One note per grounding case: no documents, a kind that isn't on file,
    // several reports to resolve, or unattached same-kind siblings to name.
    final basePrompt = docs.isEmpty
        ? '$enginePrompt$_noDocsNote'
        : g.missingLabel != null
        ? '$enginePrompt${_missingTypeNote(g.missingLabel!)}'
        : g.kind == GroundingKind.collection
        ? '$enginePrompt$_collectionNote'
        : g.kind == GroundingKind.focusResolve
        ? '$enginePrompt$_focusResolveNote'
        : !useRemote && g.otherReports.isNotEmpty
        ? '$enginePrompt${_otherReportsNote(g.otherReports)}'
        : enginePrompt;
    // Session memory: a bounded text-only slice of prior turns, with documents
    // never re-attached. Widened only for summary/recall questions.
    final wantsRecall = routed == null && _recallRe.hasMatch(q.toLowerCase());
    final priorTurns = _boundedHistory(
      history,
      maxChars: wantsRecall
          ? 1600
          : routed != null
          ? 400
          : 600,
      maxTurns: wantsRecall ? 12 : 4,
    );

    // Cloud engine → stream over HTTP, no local model needed.
    if (useRemote) {
      final safePriorTurns = <({String role, String text})>[];
      for (final turn in priorTurns) {
        // Assistant turns can quote report text, so they take the middle policy.
        // Re-applied in _answerRemote; both policies are idempotent.
        final safeText =
            (turn.role == 'assistant'
                    ? privacyGate.assistantMessage(
                        turn.text,
                        knownIdentityTerms: cloudIdentityTerms,
                      )
                    : privacyGate.userMessage(
                        turn.text,
                        role: turn.role,
                        knownIdentityTerms: cloudIdentityTerms,
                      ))
                .content;
        if (safeText.isNotEmpty) {
          safePriorTurns.add((role: turn.role, text: safeText));
        }
      }
      // Exact type/modality/date collections carry their local set. Free-form
      // topical ones ("TB-related", "kidney") instead map the exact titles the
      // answer printed back to local documents, inside _answerRemote.
      final cardRoute = routeQuestion(q, docs);
      final isCollectionRoute =
          cardRoute?.kind == RoutedAnswerKind.count ||
          cardRoute?.kind == RoutedAnswerKind.list;
      final routeCardsAreAuthoritative =
          isCollectionRoute && cardRoute!.sourcesAreAuthoritative;
      final groundedCollectionSources = g.kind == GroundingKind.collection
          ? contextDocs
          : const <CuraDocument>[];
      final cardSources = routeCardsAreAuthoritative
          ? cardRoute.sources
          : groundedCollectionSources;
      final cardTotal = routeCardsAreAuthoritative
          ? cardRoute.sourceTotal
          : groundedCollectionSources.length;
      final cardCandidates =
          isCollectionRoute &&
              !routeCardsAreAuthoritative &&
              groundedCollectionSources.isEmpty
          ? docs
          : const <CuraDocument>[];
      yield* _answerRemote(
        source,
        resolveCandidates,
        basePrompt,
        safePriorTurns,
        userContent,
        knownIdentityTerms: cloudIdentityTerms,
        cardSources: cardSources,
        cardTotal: cardTotal,
        cardCandidates: cardCandidates,
        cancellation: cancellation,
      );
      return;
    }

    // On-device engine.
    try {
      final sw = Stopwatch()..start();
      await _ensureLoaded();
      final loadMs = sw.elapsedMilliseconds;

      // Reasoning models answer without thinking unless "Think harder" is on.
      // Thinking is disabled by prefilling a closed `<think></think>` after the
      // assistant marker (see _kNoThinkPrefill): Qwen3 ignores the /no_think text
      // switch but cannot reason past an already-closed block.
      final thinkMode =
          routed == null && _spec!.canThink && await _manager.thinkHarder();
      final systemContent = basePrompt;
      final noThink = _spec!.canThink && !thinkMode;

      // KV reuse applies only to the plain ChatML fast path; "Think harder" and
      // non-chatml models take the full-rebuild path.
      if (_spec!.template != 'chatml' || thinkMode) {
        yield* _answerLocalFresh(
          systemContent,
          priorTurns,
          userContent,
          source,
          resolveCandidates,
          routed,
          thinkMode,
          sw,
          loadMs,
          cancellation,
        );
        return;
      }

      // ---- ChatML fast path: reuse the warm KV cache when it is safe to. ----
      // Three shapes, cheapest first:
      //  * follow-up — this same chat's turns are already cached; append only the
      //                new user turn onto the open answer.
      //  * warm base — only the (matching) system prompt is cached (pre-warm, or a
      //                just-finished rebuild); append history + the new user turn.
      //  * rebuild   — anything else: clear, then prefill system + history + user.
      // Any doubt → rebuild. See chat_format.dart + its tests.
      final user = (role: 'user', text: userContent);
      final sameSystem = _kvSystem == systemContent;
      String? feed;
      var reuse = false;

      if (sameSystem && conversationId != null && _kvConvId == conversationId) {
        // Follow-up in the same chat: only the new turn needs prefilling.
        final s = chatmlUserTurn(userContent, closePrev: _kvOpenAnswer);
        if (_kvTokensEst + _estTokens(s) + _kAnswerHeadroom <=
            _spec!.contextSize) {
          feed = s;
          reuse = true;
        }
      } else if (sameSystem && _kvConvId == null && !_kvOpenAnswer) {
        // Only the system prompt is cached and cleanly closed: append any prior
        // turns plus the new user turn onto it.
        final s = chatmlFull([...priorTurns, user]);
        if (_kvTokensEst + _estTokens(s) + _kAnswerHeadroom <=
            _spec!.contextSize) {
          feed = s;
          _kvConvId = conversationId;
          reuse = true;
        }
      }
      if (feed == null) {
        // Rebuild: clear and prefill the whole prompt (system + history + user).
        await _clearKv();
        feed = chatmlFull([
          (role: 'system', text: systemContent),
          ...priorTurns,
          user,
        ]);
        _kvSystem = systemContent;
        _kvConvId = conversationId;
      }

      // Seed a closed reasoning block so the model continues after it and cannot
      // reason. The tags live in the prompt, not the output.
      if (noThink) feed = '$feed$_kNoThinkPrefill';

      // Budget against the *total* cache after this turn, so prompt + answer never
      // overflow the window and evict the system prompt.
      final promptTokensEst = _kvTokensEst + _estTokens(feed);
      final ceiling = routed?.rewriteMaxTokens ?? _spec!.maxOutputTokens;
      final headroom = _spec!.contextSize - promptTokensEst - 48;
      final maxTokens = headroom < ceiling
          ? (headroom < 96 ? 96 : headroom)
          : ceiling;

      final buf = StringBuffer();
      var tokens = 0;
      var ttftMs = -1;
      cancellation?.attach(_stopLocal);
      try {
        await for (final tok in untilCancelled(
          _ctrl!.generate(
            prompt: feed,
            temperature: routed != null ? 0.1 : 0.2,
            topK: 40,
            topP: 0.95,
            maxTokens: maxTokens,
          ),
          cancellation,
        )) {
          if (ttftMs < 0) ttftMs = sw.elapsedMilliseconds - loadMs;
          tokens++;
          buf.write(tok);
          if (routed == null) {
            final p = _split(buf.toString());
            yield AskChunk(p.answer, thinking: p.thinking, source: source);
          }
          if (cancellation?.cancelled ?? false) break;
        }
      } finally {
        cancellation?.detach();
      }

      // The answer sits open in the cache (no trailing <|im_end|>), so record it
      // for the next turn to stitch onto and grow the token estimate. A stop
      // cuts it where the estimate cannot see, so that cache goes.
      if (cancellation?.cancelled ?? false) {
        await _clearKv();
      } else {
        _kvOpenAnswer = true;
        _kvTokensEst = promptTokensEst + tokens;
      }

      final genMs = sw.elapsedMilliseconds - loadMs - (ttftMs < 0 ? 0 : ttftMs);
      final tps = genMs > 0 ? (tokens * 1000 / genMs).toStringAsFixed(1) : '0';
      debugPrint(
        '[Cura.ai] model=${_spec!.id} reuse=$reuse baseTok=$_kvTokensEst '
        'promptTok=$promptTokensEst layers=$_layers maxTok=$maxTokens '
        'loadMs=$loadMs ttftMs=$ttftMs genMs=$genMs tokens=$tokens tok/s=$tps',
      );
      final parsed = _split(buf.toString());
      if (routed != null) {
        final valid = isValidVerifiedRewrite(parsed.answer, routed);
        debugPrint(
          '[Cura.ai] localRewrite kind=${routed.kind.name} '
          'promptChars=${userContent.length} maxTok=$maxTokens valid=$valid',
        );
        if (!valid) {
          // The cache holds the rejected wording but history persists the
          // fallback, so clear it and rebuild from what the user saw.
          await _clearKv();
          yield AskChunk(
            routed.text,
            source: routed.source,
            sources: routed.sources,
            sourceTotal: routed.sourceTotal,
            done: true,
          );
        } else {
          yield AskChunk(
            verifiedRewriteOrFallback(parsed.answer, routed),
            source: routed.source,
            sources: routed.sources,
            sourceTotal: routed.sourceTotal,
            done: true,
          );
        }
        return;
      }
      // Salvage a blank answer: surface the <think> content so the bubble is
      // never empty. Only ever rescues a malformed reply.
      yield _finalLocalChunk(parsed, source, candidates: resolveCandidates);
    } catch (_) {
      // Cache state is now uncertain — invalidate so the next question rebuilds.
      await _clearKv();
      // A stop is not a failure: the caller keeps what it already streamed.
      if (cancellation?.cancelled ?? false) return;
      if (routed != null) {
        yield AskChunk(
          routed.text,
          source: routed.source,
          sources: routed.sources,
          sourceTotal: routed.sourceTotal,
          done: true,
        );
      } else {
        yield const AskChunk(
          'I couldn\'t answer that just now. Please try again.',
          done: true,
        );
      }
    }
  }

  /// Fallback on-device generation: the full-rebuild path via generateChat, used
  /// when KV reuse doesn't apply — a reasoning model in "Think harder" mode, or
  /// any non-chatml model. Clears the cache first; no incremental reuse.
  Stream<AskChunk> _answerLocalFresh(
    String systemContent,
    List<({String role, String text})> priorTurns,
    String userContent,
    CuraDocument? source,
    List<CuraDocument> resolveCandidates,
    RoutedAnswer? routed,
    bool thinkMode,
    Stopwatch sw,
    int loadMs,
    GenerationCancellation? cancellation,
  ) async* {
    final messages = [
      ChatMessage(role: 'system', content: systemContent),
      for (final t in priorTurns) ChatMessage(role: t.role, content: t.text),
      ChatMessage(role: 'user', content: userContent),
    ];
    // Clear via _clearKv so the reuse tracker knows the cache was reset.
    await _clearKv();

    final ceiling = routed != null
        ? routed.rewriteMaxTokens
        : thinkMode
        ? _spec!.thinkingMaxTokens
        : _spec!.maxOutputTokens;
    final promptChars =
        systemContent.length +
        priorTurns.fold<int>(0, (n, t) => n + t.text.length) +
        userContent.length;
    final headroom = _spec!.contextSize - (promptChars / 3.5).ceil() - 48;
    final maxTokens = headroom < ceiling
        ? (headroom < 96 ? 96 : headroom)
        : ceiling;

    final buf = StringBuffer();
    var tokens = 0;
    var ttftMs = -1;
    cancellation?.attach(_stopLocal);
    try {
      await for (final tok in untilCancelled(
        _ctrl!.generateChat(
          messages: messages,
          template: _spec!.template,
          temperature: routed != null ? 0.1 : 0.2,
          topK: 40,
          topP: 0.95,
          maxTokens: maxTokens,
        ),
        cancellation,
      )) {
        if (ttftMs < 0) ttftMs = sw.elapsedMilliseconds - loadMs;
        tokens++;
        buf.write(tok);
        if (routed == null) {
          final p = _split(buf.toString());
          yield AskChunk(p.answer, thinking: p.thinking, source: source);
        }
        if (cancellation?.cancelled ?? false) break;
      }
    } finally {
      cancellation?.detach();
    }
    final genMs = sw.elapsedMilliseconds - loadMs - (ttftMs < 0 ? 0 : ttftMs);
    final tps = genMs > 0 ? (tokens * 1000 / genMs).toStringAsFixed(1) : '0';
    debugPrint(
      '[Cura.ai] model=${_spec!.id} think=$thinkMode reuse=false '
      'histTurns=${priorTurns.length} promptChars=${userContent.length} '
      'layers=$_layers maxTok=$maxTokens loadMs=$loadMs ttftMs=$ttftMs '
      'genMs=$genMs tokens=$tokens tok/s=$tps',
    );
    final parsed = _split(buf.toString());
    if (routed != null) {
      final valid = isValidVerifiedRewrite(parsed.answer, routed);
      debugPrint(
        '[Cura.ai] localRewrite kind=${routed.kind.name} '
        'promptChars=${userContent.length} maxTok=$maxTokens valid=$valid',
      );
      yield AskChunk(
        verifiedRewriteOrFallback(parsed.answer, routed),
        source: routed.source,
        done: true,
      );
      return;
    }
    // Salvage a blank answer unless the user asked to think (then the think panel
    // is intentional and an empty answer would be surfaced separately).
    yield _finalLocalChunk(
      parsed,
      source,
      salvage: !thinkMode,
      candidates: resolveCandidates,
    );
  }

  /// Builds the final on-device chunk, showing `<think>` content as the answer
  /// when the answer itself came back empty. [salvage] is false in "Think harder"
  /// mode, where the separate think panel is intentional.
  AskChunk _finalLocalChunk(
    _ParsedAnswer p,
    CuraDocument? source, {
    bool salvage = true,
    List<CuraDocument> candidates = const [],
  }) {
    // When the model resolved among several attached reports, infer which one it
    // explained so the answer still shows a source card.
    final cited = source ?? _sourceFromAnswer(p.answer, candidates);
    if (salvage && p.answer.isEmpty && p.thinking.isNotEmpty) {
      return AskChunk(p.thinking, source: cited, done: true);
    }
    return AskChunk(p.answer, thinking: p.thinking, source: cited, done: true);
  }

  /// Streams an Ask answer from the cloud engine. Same prompt shape as the local
  /// path (system + bounded history + user turn); only the token source differs.
  /// A [RemoteAiException] carries a user-ready reason (bad key, offline, …),
  /// which is surfaced instead of the generic failure line.
  Stream<AskChunk> _answerRemote(
    CuraDocument? source,
    List<CuraDocument> resolveCandidates,
    String systemPrompt,
    List<({String role, String text})> priorTurns,
    String userContent, {
    Set<String> knownIdentityTerms = const {},
    List<CuraDocument> cardSources = const [],
    int cardTotal = 0,
    List<CuraDocument> cardCandidates = const [],
    GenerationCancellation? cancellation,
  }) async* {
    const privacyGate = CloudPrivacyGate();
    final messages = [
      CloudSafeMessage.developerLiteral(role: 'system', content: systemPrompt),
      for (final t in priorTurns)
        if (t.role == 'assistant')
          privacyGate.assistantMessage(
            t.text,
            knownIdentityTerms: knownIdentityTerms,
          )
        else
          privacyGate.userMessage(
            t.text,
            role: t.role,
            knownIdentityTerms: knownIdentityTerms,
          ),
      privacyGate.documentMessage(
        userContent,
        knownIdentityTerms: knownIdentityTerms,
      ),
    ];
    final cfg = await _remote.config();
    final backend = _remoteBackendFactory(cfg);
    final sw = Stopwatch()..start();
    final buf = StringBuffer();
    var tokens = 0;
    var ttftMs = -1;
    // Closing the client tears down the SSE response mid-flight.
    cancellation?.attach(backend.close);
    try {
      await for (final tok in untilCancelled(
        backend.generate(
          messages: messages,
          temperature: 0.2,
          maxTokens: _remoteMaxTokens,
        ),
        cancellation,
      )) {
        if (ttftMs < 0) ttftMs = sw.elapsedMilliseconds;
        tokens++;
        buf.write(tok);
        final partial = _split(buf.toString());
        yield AskChunk(
          privacyGate.responseText(
            partial.answer,
            knownIdentityTerms: knownIdentityTerms,
          ),
          thinking: privacyGate.responseText(
            partial.thinking,
            knownIdentityTerms: knownIdentityTerms,
          ),
          source: source,
          sources: cardSources,
          sourceTotal: cardTotal,
        );
        if (cancellation?.cancelled ?? false) break;
      }
    } on RemoteAiException catch (e) {
      // A stop closes the client, which lands here as a broken read.
      if (!(cancellation?.cancelled ?? false)) {
        yield AskChunk(e.message, done: true);
        return;
      }
    } catch (_) {
      if (!(cancellation?.cancelled ?? false)) {
        yield const AskChunk(
          'I couldn\'t answer that just now. Please try again.',
          done: true,
        );
        return;
      }
    } finally {
      cancellation?.detach();
      backend.close();
    }
    debugPrint(
      '[Cura.ai] remote model=${cfg.modelId} promptChars=${userContent.length} '
      'ttftMs=$ttftMs totalMs=${sw.elapsedMilliseconds} tokens=$tokens',
    );
    final raw = _split(buf.toString());
    final p = _ParsedAnswer(
      privacyGate.responseText(
        raw.thinking,
        knownIdentityTerms: knownIdentityTerms,
      ),
      privacyGate.responseText(
        raw.answer,
        knownIdentityTerms: knownIdentityTerms,
      ),
    );
    // Infer the cited report when the model resolved among several attached ones.
    final inferredCards = cardCandidates.isEmpty
        ? const <CuraDocument>[]
        : explicitlyNamedDocumentsInOrder(p.answer, cardCandidates);
    final finalCards = cardSources.isNotEmpty ? cardSources : inferredCards;
    final finalCardTotal = cardSources.isNotEmpty
        ? cardTotal
        : inferredCards.length;
    final cited = finalCards.isNotEmpty
        ? finalCards.first
        : source ?? _sourceFromAnswer(p.answer, resolveCandidates);
    if (cardCandidates.isNotEmpty) {
      debugPrint(
        '[Cura.ai] collection sources candidates=${cardCandidates.length} '
        'named=${inferredCards.length}',
      );
    }
    yield AskChunk(
      p.answer,
      thinking: p.thinking,
      source: cited,
      sources: finalCards,
      sourceTotal: finalCardTotal,
      done: true,
    );
  }

  // Scan refinement uses small purpose-specific contracts, so the model is never
  // asked for summaries the review screen discards.
  static const _metadataExtractionPrompt =
      'Read the minimized OCR and return ONLY one JSON object with any grounded '
      'metadata you can find: {"title":string,"type":"lab"|"receipt"|'
      '"discharge"|"imaging","date":string}. Omit missing keys. Copy the exact '
      'printed report heading, abbreviation, and date; never invent or '
      'paraphrase them. A title must describe the report, not a patient, doctor, '
      'hospital, or laboratory. Type rules: lab = clinical/pathology test; '
      'receipt = bill/invoice; discharge = discharge summary; imaging = PET, '
      'MRI, CT, X-ray, ultrasound, echo, or radiology. Do not return results, '
      'notes, summaries, patient details, identifiers, or prose.';

  static const _receiptExtractionPrompt =
      'Read the minimized receipt OCR and return ONLY one JSON object: '
      '{"title":string,"note":string}. Omit missing keys. title must be a short, '
      'useful bill title grounded in the printed service or product words, for '
      'example "Consultation bill" or "Hair medicines invoice"; use a vendor '
      'only when it is clearly printed as the heading. note must be one short '
      'sentence saying what the bill was for, using only printed service or '
      'product words. Never include an amount, identifier, address, phone '
      'number, or person name. Do not return type, date, items, results, or '
      'prose.';

  static const _repairTablePrompt =
      'A sanitized OCR table grid follows. Return ONLY one JSON object with '
      'optional grounded metadata {"title":string,"type":"lab","date":string} '
      'and tableRows:[{"labelCell":"cell id","valueCell":"cell id",'
      '"unitCell":"cell id or null","rangeCells":["cell ids"]}]. Reconcile the '
      'whole table, including shifted or missed rows. Section subtitles are '
      'headings, not results. Use only supplied opaque cell IDs; never copy or '
      'invent medical text. Map each observed-value cell once, preserve printed '
      'row order, and keep every cell for one row within the same OCR pass. Do '
      'not return a note, summary, result values, patient details, or prose.';

  @visibleForTesting
  static String scanExtractionSystemPrompt(ScanExtractionMode mode) =>
      switch (mode) {
        ScanExtractionMode.metadata => _metadataExtractionPrompt,
        ScanExtractionMode.receipt => _receiptExtractionPrompt,
        ScanExtractionMode.tableRepair => _repairTablePrompt,
      };

  /// Starts one cancellable request and returns its field targets immediately.
  /// Null means this document/engine combination is entirely deterministic.
  ScanRefinementJob? startDocumentRefinement(
    String ocrText, {
    required DocumentType draftType,
    required bool useRemote,
    String? title,
    TableRepairEvidence tableEvidence = const TableRepairEvidence([]),
  }) {
    final fields = scanRefinementFields(
      draftType: draftType,
      useRemote: useRemote,
      title: title,
      tableEvidence: tableEvidence,
    );
    if (fields.isEmpty) return null;
    final cancellation = GenerationCancellation();
    return ScanRefinementJob(
      fields: fields,
      result: _extractDocumentFields(
        ocrText,
        draftType: draftType,
        useRemote: useRemote,
        title: title,
        tableEvidence: tableEvidence,
        fields: fields,
        cancellation: cancellation,
      ),
      onCancel: cancellation.cancel,
    );
  }

  @visibleForTesting
  static Set<ScanRefinementField> scanRefinementFields({
    required DocumentType draftType,
    required bool useRemote,
    String? title,
    TableRepairEvidence tableEvidence = const TableRepairEvidence([]),
  }) {
    if (draftType == DocumentType.prescription ||
        draftType == DocumentType.visit ||
        (!useRemote && draftType != DocumentType.receipt)) {
      return const {};
    }
    // Bills already have deterministic type/date and geometry-derived amounts, so
    // the model fills only the two semantic fields Review shows.
    if (draftType == DocumentType.receipt) {
      return const {ScanRefinementField.title, ScanRefinementField.receiptNote};
    }
    return {
      ScanRefinementField.type,
      ScanRefinementField.date,
      ScanRefinementField.title,
      if (useRemote &&
          draftType == DocumentType.lab &&
          tableEvidence.canReconcile &&
          tableEvidence.requiresReconciliation)
        ScanRefinementField.results,
    };
  }

  Future<ScanExtraction?> _extractDocumentFields(
    String ocrText, {
    required DocumentType draftType,
    required bool useRemote,
    required Set<ScanRefinementField> fields,
    required GenerationCancellation cancellation,
    String? title,
    TableRepairEvidence tableEvidence = const TableRepairEvidence([]),
  }) async {
    final text = ocrText.trim();
    if (text.isEmpty) return null;
    if (!useRemote && await _manager.installedModel() == null) return null;
    if (cancellation.cancelled) return null;
    try {
      final sw = Stopwatch()..start();
      // Raw JSON from whichever engine is active; validation is identical after.
      // Cloud sees only the allowlisted medical lines, while parseScanExtraction
      // validates against the full unredacted [text].
      final wantsRepair =
          useRemote &&
          fields.contains(ScanRefinementField.results) &&
          tableEvidence.canReconcile &&
          tableEvidence.requiresReconciliation;
      final gate = const CloudPrivacyGate();
      // Bills route through the bill allowlist (money/billing lines only);
      // everything else keeps the medical-line policy.
      final cloudOcr = gate.scanText(text, title: title, type: draftType).text;
      final safeEvidence = wantsRepair
          ? gate.tableText('${title ?? ''}\n${tableEvidence.gridText}').text
          : '';
      // Fail closed when minimization strips the whole candidate row: extract
      // metadata only and leave the row for review. Receipt breakdowns stay
      // geometry-only on both engines.
      final repairRequested = wantsRepair && safeEvidence.isNotEmpty;
      final mode = repairRequested
          ? ScanExtractionMode.tableRepair
          : draftType == DocumentType.receipt
          ? ScanExtractionMode.receipt
          : ScanExtractionMode.metadata;
      // Repair requests are table-only, never another upload of the narrative.
      // A safe title rides along so metadata refinement stays useful.
      final remoteInput = repairRequested
          ? 'TABLE ROW EVIDENCE:\n$safeEvidence'
          : cloudOcr;
      final localInput = selectBillOcrForExtraction(text);
      final out = useRemote
          ? await _extractRemote(
              remoteInput,
              mode: mode,
              cancellation: cancellation,
            )
          : await _extractLocal(
              localInput,
              mode: mode,
              cancellation: cancellation,
            );
      if (cancellation.cancelled) return null;
      // parseScanExtraction re-checks every value against the OCR, so an invented
      // number is dropped on either engine.
      var ext = parseScanExtraction(out, text, parseDate: _scan.extractDate);
      if (repairRequested) {
        final safeCells = tableEvidence.cellsPresentIn(safeEvidence);
        final reconciled = parseTableCellReconciliation(out, safeCells);
        if (reconciled.isNotEmpty) {
          ext = ScanExtraction(
            title: ext?.title,
            type: ext?.type ?? DocumentType.lab,
            date: ext?.date,
            results: reconciled,
            verifiedTableRepair: true,
          );
        } else if (ext != null) {
          ext = ScanExtraction(
            title: ext.title,
            type: ext.type,
            date: ext.date,
          );
        }
      }
      final allowed = repairRequested
          ? fields
          : ({...fields}..remove(ScanRefinementField.results));
      ext = ext?.only(allowed);
      if (ext?.isEmpty ?? false) ext = null;
      final promptChars =
          scanExtractionSystemPrompt(mode).length +
          (useRemote ? remoteInput.length : localInput.length) +
          24;
      debugPrint(
        '[Cura.ai] extract engine=${useRemote ? 'remote' : 'local'} '
        'mode=${mode.name} ms=${sw.elapsedMilliseconds} '
        'promptChars=$promptChars outputChars=${out.length} ok=${ext != null} '
        'results=${ext?.results.length ?? 0} repair=$repairRequested '
        'verified=${ext?.verifiedTableRepair ?? false}',
      );
      return ext;
    } catch (_) {
      return null;
    }
  }

  /// On-device scan extraction: JSON out of the warm local model.
  Future<String> _extractLocal(
    String selectedOcr, {
    required ScanExtractionMode mode,
    required GenerationCancellation cancellation,
  }) async {
    if (cancellation.cancelled) return '';
    await _ensureLoaded();
    if (cancellation.cancelled) return '';
    cancellation.attach(() {
      final ctrl = _ctrl;
      if (ctrl != null) unawaited(ctrl.stop());
    });
    final extractionPrompt = scanExtractionSystemPrompt(mode);
    final system = _spec!.canThink
        ? '$extractionPrompt /no_think'
        : extractionPrompt;
    final messages = [
      ChatMessage(role: 'system', content: system),
      ChatMessage(role: 'user', content: 'OCR text:\n$selectedOcr\n\nJSON:'),
    ];
    // Clear via _clearKv so the Ask reuse tracker knows this scan wiped the cache.
    await _clearKv();

    final promptChars = system.length + selectedOcr.length + 24;
    final headroom = _spec!.contextSize - (promptChars / 3.5).ceil() - 48;
    final modeCeiling = _scanMaxTokens(mode);
    final ceiling = _spec!.maxOutputTokens < modeCeiling
        ? _spec!.maxOutputTokens
        : modeCeiling;
    final maxTokens = headroom < ceiling
        ? (headroom < 96 ? 96 : headroom)
        : ceiling;

    final buf = StringBuffer();
    var stoppedAtJson = false;
    try {
      await for (final tok in _ctrl!.generateChat(
        messages: messages,
        template: _spec!.template,
        temperature: 0.0,
        topK: 40,
        topP: 0.95,
        maxTokens: maxTokens,
      )) {
        if (cancellation.cancelled) break;
        buf.write(tok);
        final answer = _split(buf.toString()).answer;
        if (firstCompleteJsonObject(answer) != null) {
          stoppedAtJson = true;
          break;
        }
      }
      if (stoppedAtJson) await _ctrl!.stop();
    } finally {
      cancellation.detach();
    }
    return _split(buf.toString()).answer;
  }

  /// Cloud scan extraction: JSON out of the configured provider.
  Future<String> _extractRemote(
    String selectedOcr, {
    required ScanExtractionMode mode,
    required GenerationCancellation cancellation,
  }) async {
    if (cancellation.cancelled) return '';
    final backend = RemoteChatBackend(await _remote.config());
    cancellation.attach(backend.close);
    if (cancellation.cancelled) return '';
    final systemPrompt = scanExtractionSystemPrompt(mode);
    final buf = StringBuffer();
    try {
      await for (final tok in backend.generate(
        messages: [
          CloudSafeMessage.developerLiteral(
            role: 'system',
            content: systemPrompt,
          ),
          const CloudPrivacyGate().documentMessage(
            'OCR text:\n$selectedOcr\n\nJSON:',
            role: 'user',
          ),
        ],
        temperature: 0.0,
        maxTokens: _scanMaxTokens(mode),
      )) {
        if (cancellation.cancelled) break;
        buf.write(tok);
        final answer = _split(buf.toString()).answer;
        if (firstCompleteJsonObject(answer) != null) break;
      }
    } finally {
      cancellation.detach();
      backend.close();
    }
    return _split(buf.toString()).answer;
  }

  static int _scanMaxTokens(ScanExtractionMode mode) => switch (mode) {
    ScanExtractionMode.metadata => 128,
    ScanExtractionMode.receipt => 128,
    ScanExtractionMode.tableRepair => _remoteMaxTokens,
  };

  final ScanService _scan = ScanService();

  /// Detects "summarize/recall the conversation" questions, which need a wider
  /// history window than an ordinary follow-up.
  static final _recallRe = RegExp(
    r'\b(summar(y|ize|ise)|recap|so far|this (chat|session|conversation)|'
    r'earlier|we (talk|talked|discuss|discussed|said)|what did (we|i|you))\b',
  );

  /// Trims [history] to the newest turns that fit the budget, capping both chars
  /// and turn count, then restores chronological order. The window is small by
  /// default for fast prefill and wider for summary/recall questions.
  List<({String role, String text})> _boundedHistory(
    List<({String role, String text})> history, {
    required int maxChars,
    required int maxTurns,
  }) {
    final kept = <({String role, String text})>[];
    var chars = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      final t = history[i];
      final text = t.text.trim();
      if (text.isEmpty) continue;
      if (kept.length >= maxTurns) break;
      if (kept.isNotEmpty && chars + text.length > maxChars) break;
      kept.add((role: t.role, text: text));
      chars += text.length;
    }
    return kept.reversed.toList();
  }

  /// Splits raw model output into (reasoning, answer) on `<think>…</think>`.
  /// Until the closing tag arrives everything is in-progress reasoning; output
  /// with no think tags is all answer.
  _ParsedAnswer _split(String raw) {
    var text = raw
        .replaceAll('\\n', '\n')
        .replaceAll('\\t', '\t')
        .replaceAll('\\"', '"')
        .replaceAll('\\\\', '\\');

    var thinking = '';
    final close = text.indexOf('</think>');
    if (close != -1) {
      var think = text.substring(0, close);
      final open = think.indexOf('<think>');
      if (open != -1) think = think.substring(open + '<think>'.length);
      thinking = think.trim();
      text = text.substring(close + '</think>'.length);
    } else {
      final open = text.indexOf('<think>');
      if (open != -1) {
        // Still reasoning — no answer yet.
        thinking = text.substring(open + '<think>'.length).trim();
        text = '';
      }
    }

    // Strip any stray trailing "SOURCE: …" line the model may append.
    text = text.replaceAll(
      RegExp(r'\n?\s*SOURCE\s*:.*$', caseSensitive: false, dotAll: true),
      '',
    );
    return _ParsedAnswer(thinking, text.trim());
  }

  Future<void> _ensureLoaded() async {
    if (_ctrl != null) return;
    final spec = await _manager.installedModel() ?? kDefaultModel;
    _spec = spec;
    final path = await _manager.modelPath(spec);

    // Vulkan offload only when the plugin's detector recommends it: mid-range
    // Mali GPUs are often no faster than the CPU at this model size. A failed GPU
    // load falls back to CPU; the layer count is in the [Cura.ai] timing line.
    var layers = 0;
    final probe = LlamaController();
    try {
      final gpu = await probe.detectGpu();
      debugPrint(
        '[Cura.ai] gpu name=${gpu.gpuName} vulkan=${gpu.vulkanSupported} '
        'rec=${gpu.recommendedGpuLayers} '
        'freeRamMB=${gpu.freeRamBytes ~/ (1024 * 1024)}',
      );
      if (gpu.vulkanSupported && gpu.recommendedGpuLayers > 0) {
        layers = gpu.recommendedGpuLayers;
      }
    } catch (e) {
      debugPrint('[Cura.ai] gpu detect failed: $e');
    }

    // 6 threads: prefill is the bottleneck, so use the big cores plus a couple
    // more without over-subscribing the little ones.
    try {
      await probe.loadModel(
        modelPath: path,
        threads: 6,
        contextSize: spec.contextSize,
        gpuLayers: layers,
      );
      _ctrl = probe;
    } catch (e) {
      if (layers == 0) rethrow;
      // GPU init can fail on some drivers — retry on the CPU so Ask still works.
      debugPrint('[Cura.ai] gpu load failed ($e); falling back to CPU');
      layers = 0;
      final cpu = LlamaController();
      await cpu.loadModel(
        modelPath: path,
        threads: 6,
        contextSize: spec.contextSize,
        gpuLayers: 0,
      );
      _ctrl = cpu;
    }
    _layers = layers;

    // Pre-warm the cache with the common-case system prompt so the first question
    // doesn't pay to prefill it. maxTokens:0 prefills without generating.
    if (spec.template == 'chatml') {
      // The system prompt is stable across think on/off (the /no_think switch
      // lives on the user turn), so the plain prompt pre-warms every model.
      final warmSys = _systemPrompt;
      final block = chatmlSystemBlock(warmSys);
      try {
        await _ctrl!
            .generate(prompt: block, maxTokens: 0, temperature: 0.2)
            .drain<void>();
        _kvSystem = warmSys;
        _kvConvId = null;
        _kvOpenAnswer = false;
        _kvTokensEst = _estTokens(block);
      } catch (_) {
        await _clearKv();
      }
    }
  }

  /// Releases the warm model (called when the provider is disposed).
  Future<void> dispose() async {
    await _ctrl?.dispose();
    _ctrl = null;
    _kvSystem = null;
    _kvConvId = null;
    _kvOpenAnswer = false;
    _kvTokensEst = 0;
  }
}
