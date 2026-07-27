import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/data/providers.dart';
import '../../core/widgets/cura_spark.dart';
import '../ai/ai_models.dart';
import '../ai/ai_providers.dart';
import '../ai/ai_service.dart';
import '../ai/query_router.dart';
import '../ai/remote/remote_ai_store.dart';
import '../ai/retrieval.dart';
import '../ai/widgets/model_download_sheet.dart';
import '../library/document.dart';
import 'ask_prompt_rotation.dart';
import 'chat_models.dart';
import 'voice_input_controller.dart';
import 'voice_model_sheet.dart';

/// Voice-input UI phase for the composer mic.
enum _VoiceState { idle, recording, transcribing }

/// One message in the Ask thread. [emphasis] is a substring of [text] rendered
/// in the accent color; [source] (when set) renders a cited source-document card.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.emphasis,
    this.source,
    this.sources = const [],
    this.sourceTotal = 0,
    this.thinking,
    this.thinkingActive = false,
    this.thinkingSeconds,
  });

  final ChatRole role;
  final String text;
  final String? emphasis;

  /// The primary cited document (newest, for single-card answers and for
  /// follow-up focus). Kept even when [sources] is populated.
  final CuraDocument? source;

  /// For a multi-match answer (a count over several reports), the reports to
  /// show as source cards — newest first. Empty for single-source answers.
  final List<CuraDocument> sources;

  /// Complete validated match count behind [sources] — the "+N more".
  final int sourceTotal;

  /// A reasoning model's hidden chain, shown live in a collapsible panel above
  /// the answer. Null/empty for non-reasoning replies.
  final String? thinking;

  /// True while the reasoning is still streaming (before the answer begins).
  final bool thinkingActive;

  /// How long the model reasoned, in seconds — shown once reasoning is done
  /// ("Thought for Xs").
  final int? thinkingSeconds;

  ChatMessage copyWith({
    String? text,
    CuraDocument? source,
    List<CuraDocument>? sources,
    int? sourceTotal,
    String? thinking,
    bool? thinkingActive,
    int? thinkingSeconds,
  }) {
    return ChatMessage(
      role: role,
      text: text ?? this.text,
      emphasis: emphasis,
      source: source ?? this.source,
      sources: sources ?? this.sources,
      sourceTotal: sourceTotal ?? this.sourceTotal,
      thinking: thinking ?? this.thinking,
      thinkingActive: thinkingActive ?? this.thinkingActive,
      thinkingSeconds: thinkingSeconds ?? this.thinkingSeconds,
    );
  }
}

/// Plain-language Q&A over the user's own documents. Pushed full-screen with its
/// own input bar (no bottom nav).
///
/// Answers come from the on-device model grounded in the user's saved documents
/// (keyword retrieval → LLM → cited source). Fully offline.
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({
    super.key,
    required this.prompts,
    required this.onOpenDocument,
    required this.onOpenSettings,
  });

  final AskPromptSet prompts;
  final ValueChanged<CuraDocument> onOpenDocument;

  /// Opens the Settings tab (Ask is a pushed screen over Home) so the user can
  /// set up an on-device or cloud model when none is ready yet.
  final VoidCallback onOpenSettings;

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  // On-device voice input (Whisper.cpp). Records → transcribes → fills the
  // composer for review; never auto-sends. Nothing leaves the device.
  final _voice = VoiceInputController();
  _VoiceState _voiceState = _VoiceState.idle;
  // Live mic level for the recording waveform, created once per session so the
  // waveform subscribes to a single stream (not a new one on every rebuild).
  Stream<double>? _amplitude;

  final List<ChatMessage> _messages = [];
  String? _sessionId; // null = fresh, unsaved conversation
  bool _showSuggestions = true;
  bool _busy = false;

  // Halts the model itself, not just the reveal.
  GenerationCancellation? _cancel;

  // Bumped per question and by a stop. An answer that no longer holds the
  // latest number writes nothing, even if its stream never ends.
  int _sendSeq = 0;

  // Message being re-asked, or null. The thread waits until it is sent.
  int? _editingIndex;
  final _inputFocus = FocusNode();

  // Typewriter reveal. The model emits words in bursts, so the streamed text is
  // buffered in [_streamTarget] and revealed a few characters per frame.
  Timer? _typer;
  Completer<void>? _typerDone;
  String _streamTarget = '';
  int _revealed = 0;
  bool _streamDone = false;
  CuraDocument? _streamSource;
  // Multi-report cards for a streamed (cloud) count answer — applied when the
  // typewriter finishes. Empty for single-source answers ([_streamSource]).
  List<CuraDocument> _streamSources = const [];
  int _streamSourceTotal = 0;

  // True while a cloud answer streams. Cloud returns everything almost at once,
  // so the reveal is capped to a readable pace (see [_kCloudRevealStep]).
  bool _streamRemote = false;

  // Max chars revealed per 22 ms tick for a cloud answer → ~135 chars/s, a
  // readable typing speed regardless of how fast the tokens actually arrived.
  static const _kCloudRevealStep = 3;

  // Reasoning stream (reasoning models only): the hidden chain, shown live in the
  // collapsible thinking panel. Not typewritten — it updates raw as it grows.
  String _streamThinking = '';
  bool _thinkingActive = false;
  DateTime? _thinkingStart;
  int? _thinkingSeconds;

  @override
  void initState() {
    super.initState();
    // Start a fresh chat each time Ask is opened; past chats live in History.
    // The active model shown in the header comes from aiModelStateProvider
    // (watched in build), so it stays in sync with Settings automatically.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _ensureAiReady();
    });
  }

  @override
  void dispose() {
    // Leaving mid-answer must not leave the model generating.
    _cancel?.cancel();
    _cancelTyper();
    _voice.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // True when an engine can actually answer: the cloud engine is the active
  // (configured) one, or an on-device model is installed. Cloud-only users have
  // no local model, so Ask must never gate on the on-device model alone.
  Future<bool> _aiReady() async {
    final engine = await ref.read(activeEngineProvider.future);
    if (engine.isRemote) return true;
    return await ref.read(aiModelManagerProvider).installedModel() != null;
  }

  // Ask needs an engine, so on entry point the user to Settings when neither is
  // set up, and return Home if they decline.
  Future<void> _ensureAiReady() async {
    if (await _aiReady()) return;
    if (!mounted) return;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set up an AI model'),
        content: const Text(
          'To ask questions about your records, set up an AI model. Use the '
          'downloaded model or connect a cloud model. You can choose either in '
          'Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    // Either way we leave Ask (it's unusable without an engine); on "Open
    // Settings" we also switch Home to the Settings tab.
    Navigator.of(context).maybePop();
    if (openSettings == true) widget.onOpenSettings();
  }

  CuraDocument? _docById(List<CuraDocument> docs, String id) {
    for (final d in docs) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Rebuilds a persisted message, decoding its cited source(s). A multi-source
  /// count restores its card list; a single id restores one card (legacy rows
  /// too). Ids that no longer resolve (deleted docs) are dropped.
  ChatMessage _restoreMessage(StoredMessage s, List<CuraDocument> docs) {
    if (s.sourceDocId == null) {
      return ChatMessage(role: s.role, text: s.text);
    }
    final ref = decodeSourceRef(s.sourceDocId!);
    final resolved = [for (final id in ref.ids) ?_docById(docs, id)];
    return ChatMessage(
      role: s.role,
      text: s.text,
      source: resolved.isEmpty ? null : resolved.first,
      sources: resolved.length > 1 ? resolved : const [],
      // Deleted reports are deliberately absent after restore. The visible set
      // is now the complete valid set, so never preserve a phantom "+N more".
      sourceTotal: resolved.length > 1 ? resolved.length : 0,
    );
  }

  String _titleFor(String text) =>
      text.length > 40 ? '${text.substring(0, 40).trim()}…' : text;

  Future<void> _send(String raw) async {
    // A transcription in flight owns the composer; let it finish first.
    if (_voiceState == _VoiceState.transcribing) return;
    if (_voiceState == _VoiceState.recording) {
      await _voice.cancelRecording();
      if (mounted) {
        setState(() {
          _amplitude = null;
          _voiceState = _VoiceState.idle;
        });
      }
    }
    final text = raw.trim();
    if (text.isEmpty || _busy) return;

    final repo = ref.read(chatRepositoryProvider);

    // Re-asking an edited question: clear its old turn out of the thread first.
    final editing = _editingIndex;
    if (editing != null && _sessionId != null) {
      // ponytail: rows align with _messages by ordinal, not id. Counting from
      // the rows self-corrects if an answer never reached the database.
      final stored = await repo.loadMessages(_sessionId!);
      await repo.deleteTrailingMessages(_sessionId!, stored.length - editing);
      // The warm cache still holds the turns just removed.
      await ref.read(aiServiceProvider).resetConversationCache();
      if (!mounted) return;
      setState(() => _messages.removeRange(editing, _messages.length));
    }
    _editingIndex = null;

    // This answer's claim on the thread; a stop or a new question takes it.
    final seq = ++_sendSeq;

    setState(() {
      _showSuggestions = false;
      _busy = true;
      _messages.add(ChatMessage(role: ChatRole.user, text: text));
    });
    _input.clear();
    _scrollToEnd();

    _sessionId ??= (await repo.createSession(_titleFor(text))).id;
    await repo.addMessage(_sessionId!, ChatRole.user, text);

    // Make sure an engine is available before we try to answer — but skip the
    // check when the question can be answered locally (no model needed). Cloud
    // counts as ready, so this only blocks when nothing is set up at all.
    final docs = ref.read(documentsProvider).value ?? const [];
    final needsModel = routeQuestion(text, docs) == null;
    if (needsModel && docs.isNotEmpty && !await _aiReady()) {
      const reply =
          'Set up an AI model first from Settings. Choose a downloaded model or '
          'a cloud model, then I can answer questions about '
          'your records.';
      await repo.addMessage(_sessionId!, ChatRole.assistant, reply);
      if (!mounted || seq != _sendSeq) return;
      setState(() {
        _busy = false;
        _messages.add(const ChatMessage(role: ChatRole.assistant, text: reply));
      });
      _scrollToEnd();
      return;
    }

    // Capture the session id up front so a mid-answer "new chat" can't null it.
    final sid = _sessionId!;

    // Stream the answer. A verified local-router rewrite arrives as one buffered
    // done chunk; an ordinary model answer streams and is revealed with the smooth
    // typewriter so bursty word-at-a-time tokens read as continuous typing.
    _streamTarget = '';
    _revealed = 0;
    _streamDone = false;
    _streamSource = null;
    _streamSources = const [];
    _streamSourceTotal = 0;
    _streamThinking = '';
    _thinkingActive = false;
    _thinkingStart = null;
    _thinkingSeconds = null;
    // Pace the reveal for whichever engine is answering (cloud lands all at once).
    _streamRemote = ref.read(activeEngineProvider).value?.isRemote ?? false;
    int? idx;
    var finalText = '';
    CuraDocument? source;
    var sources = const <CuraDocument>[];
    var sourceTotal = 0;
    var first = true;
    // Session memory: the prior turns (everything before the user message we just
    // added), text-only, so the model can follow up and summarize the session.
    // The service bounds history aggressively so local rewrite prefill stays tiny.
    final history = [
      for (final m in _messages.sublist(0, _messages.length - 1))
        if (m.text.trim().isNotEmpty)
          (role: m.role == ChatRole.user ? 'user' : 'assistant', text: m.text),
    ];
    // Documents already cited in this chat, so "the other ultrasound" resolves to
    // the one not yet shown.
    final shownSourceIds = {
      for (final m in _messages)
        if (m.role == ChatRole.assistant && m.source != null) m.source!.id,
    };
    // The reports the conversation is about: titles from the preceding answer in
    // displayed order, so "the first one" means the item the user just saw.
    // Falls back to the most recent source card.
    var orderedFocusDocIds = const <String>[];
    String? lastSourceId;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role == ChatRole.assistant) {
        // The reports shown as cards are the focus set, in display order, so
        // "the second one" means the second card the user just saw.
        if (m.sources.length > 1) {
          orderedFocusDocIds = [for (final d in m.sources) d.id];
          break;
        }
        final mentioned = mentionedDocumentsInOrder(m.text, docs);
        if (mentioned.isNotEmpty) {
          orderedFocusDocIds = [for (final d in mentioned) d.id];
          break;
        }
        if (m.source != null) {
          lastSourceId = m.source!.id;
          break;
        }
      }
    }
    final focusDocIds = orderedFocusDocIds.isNotEmpty
        ? orderedFocusDocIds.toSet()
        : lastSourceId == null
        ? const <String>{}
        : {lastSourceId};
    final cancel = GenerationCancellation();
    _cancel = cancel;
    await for (final chunk
        in ref
            .read(aiServiceProvider)
            .answerQuestionStream(
              text,
              docs,
              history: history,
              conversationId: sid,
              shownSourceIds: shownSourceIds,
              focusDocIds: focusDocIds,
              orderedFocusDocIds: orderedFocusDocIds,
              cancellation: cancel,
            )) {
      // Stopped or overtaken: leaving the loop also unsubscribes.
      if (!mounted || seq != _sendSeq) return;
      finalText = chunk.text;
      source = chunk.source;
      sources = chunk.sources;
      sourceTotal = chunk.sourceTotal;
      final thinkingText = chunk.thinking;
      if (first && chunk.done) {
        // Instant answer — no typewriter, just show it.
        setState(
          () => _messages.add(
            ChatMessage(
              role: ChatRole.assistant,
              text: finalText,
              source: source,
              sources: sources,
              sourceTotal: sourceTotal,
            ),
          ),
        );
        _scrollToEnd();
        break;
      }
      first = false;
      _streamTarget = finalText;
      _streamSource = source;
      _streamSources = sources;
      _streamSourceTotal = sourceTotal;
      if (chunk.done) _streamDone = true;

      // Track the reasoning phase: it's active while reasoning is streaming but
      // the answer hasn't started. Time it so we can show "Thought for Xs".
      if (thinkingText.isNotEmpty && _thinkingStart == null) {
        _thinkingStart = DateTime.now();
      }
      final reasoningNow =
          thinkingText.isNotEmpty && finalText.isEmpty && !chunk.done;
      if (!reasoningNow && _thinkingStart != null && _thinkingSeconds == null) {
        _thinkingSeconds = DateTime.now().difference(_thinkingStart!).inSeconds;
      }
      _streamThinking = thinkingText;
      _thinkingActive = reasoningNow;

      // Show the bubble once we have anything — reasoning OR answer. Until then
      // (model still loading/prefill) keep the "Cura is thinking…" bubble.
      if (idx == null &&
          thinkingText.isEmpty &&
          finalText.isEmpty &&
          !chunk.done) {
        continue;
      }
      if (idx == null) {
        setState(() {
          _messages.add(const ChatMessage(role: ChatRole.assistant, text: ''));
          idx = _messages.length - 1;
        });
      }
      // Reasoning is shown raw (not typewritten); push it to the message now.
      setState(
        () => _messages[idx!] = _messages[idx!].copyWith(
          thinking: _streamThinking,
          thinkingActive: _thinkingActive,
          thinkingSeconds: _thinkingSeconds,
        ),
      );
      // The answer streams through the typewriter (only once it has content).
      if (finalText.isNotEmpty) _ensureTyper(idx!);
      _scrollToEndGentle();
    }

    // If we streamed, let the typewriter finish revealing before we save.
    if (idx != null) {
      _streamDone = true;
      await _typerDone?.future;
    }

    if (!mounted || seq != _sendSeq) return;
    _cancel = null;
    await repo.addMessage(
      sid,
      ChatRole.assistant,
      finalText,
      sourceDocId: sources.isNotEmpty
          ? encodeSourceRef(sources, sourceTotal)
          : source?.id,
    );
    if (!mounted || seq != _sendSeq) return;
    setState(() => _busy = false);
  }

  /// Stops the model, freezes the reveal, saves the partial and restores the
  /// send button. Never waits on the stream: a stopped backend may not end it.
  Future<void> _stopAnswer() async {
    if (!_busy) return;
    // Takes the thread from the running answer.
    _sendSeq++;
    _cancel?.cancel();
    _cancel = null;

    final sid = _sessionId;
    final target = _streamTarget;
    _revealed = target.length;
    final idx = _messages.length - 1;
    // Stopped before the first token: nothing shown, so nothing saved.
    final hasAnswer =
        target.isNotEmpty &&
        idx >= 0 &&
        _messages[idx].role == ChatRole.assistant;
    if (hasAnswer) {
      setState(
        () => _messages[idx] = _messages[idx].copyWith(
          text: target,
          source: _streamSource,
          sources: _streamSources,
          sourceTotal: _streamSourceTotal,
          thinkingActive: false,
        ),
      );
    }
    _finishTyper();
    setState(() => _busy = false);

    if (hasAnswer && sid != null) {
      await ref
          .read(chatRepositoryProvider)
          .addMessage(
            sid,
            ChatRole.assistant,
            target,
            sourceDocId: _streamSources.isNotEmpty
                ? encodeSourceRef(_streamSources, _streamSourceTotal)
                : _streamSource?.id,
          );
    }
  }

  void _newChat() {
    unawaited(_stopAnswer());
    _cancelTyper();
    setState(() {
      _sessionId = null;
      _messages.clear();
      _showSuggestions = true;
      _editingIndex = null;
    });
    _input.clear();
  }

  Future<void> _loadSession(ChatSession session) async {
    unawaited(_stopAnswer());
    _cancelTyper();
    final repo = ref.read(chatRepositoryProvider);
    final stored = await repo.loadMessages(session.id);
    final docs = ref.read(documentsProvider).value ?? const [];
    if (!mounted) return;
    setState(() {
      _sessionId = session.id;
      _messages
        ..clear()
        ..addAll(stored.map((s) => _restoreMessage(s, docs)));
      _showSuggestions = false;
      _editingIndex = null;
    });
    _input.clear();
    _scrollToEnd();
  }

  /// Loads the last question back into the composer. Backing out costs nothing.
  void _editLastQuestion(int index) {
    setState(() => _editingIndex = index);
    _input.text = _messages[index].text;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _inputFocus.requestFocus();
  }

  void _cancelEditing() {
    setState(() => _editingIndex = null);
    _input.clear();
  }

  /// The last question, the only editable one. Null while an answer streams.
  int? get _editableIndex {
    if (_busy) return null;
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == ChatRole.user) return i;
    }
    return null;
  }

  void _openHistory() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _HistorySheet(
        currentId: _sessionId,
        onOpen: (s) {
          Navigator.of(context).pop();
          _loadSession(s);
        },
        onDelete: (s) async {
          await ref.read(chatRepositoryProvider).deleteSession(s.id);
          if (s.id == _sessionId && mounted) _newChat();
        },
      ),
    );
  }

  // Opens the model switcher so the user can change the active model without
  // leaving the chat. The switcher invalidates aiModelStateProvider on any
  // change, so the header (which watches it) refreshes on its own.
  Future<void> _openModelSwitcher() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => const _ModelSwitcherSheet(),
    );
  }

  /// Flips the "Think harder" preference from the composer toggle. The service
  /// reads the pref per question, so there's nothing to reload.
  Future<void> _setThinkHarder(bool value) async {
    await ref.read(aiModelManagerProvider).setThinkHarder(value);
    ref.invalidate(thinkHarderProvider);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Pins to the bottom without an animation, so rapid typewriter ticks don't
  // stack up competing 300ms scrolls (which is what makes streaming feel janky).
  void _scrollToEndGentle() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// Starts the character-by-character reveal for the streaming assistant message
  /// at [idx]. Idempotent — the loop feeds [_streamTarget]; this drains it.
  void _ensureTyper(int idx) {
    if (_typer != null) return;
    _typerDone = Completer<void>();
    _typer = Timer.periodic(const Duration(milliseconds: 22), (t) {
      if (!mounted || idx >= _messages.length) {
        _finishTyper();
        return;
      }
      final target = _streamTarget;
      if (_revealed >= target.length) {
        // Caught up. If the stream is finished, attach the source card and stop;
        // otherwise idle until more text arrives. copyWith preserves the thinking
        // panel fields the stream loop set on this message.
        if (_streamDone) {
          setState(
            () => _messages[idx] = _messages[idx].copyWith(
              text: target,
              source: _streamSource,
              sources: _streamSources,
              sourceTotal: _streamSourceTotal,
              thinkingActive: false,
            ),
          );
          _finishTyper();
        }
        return;
      }
      // Ease toward the target: faster when far behind, ~1 char/tick once caught
      // up. A cloud answer is fully buffered, so its step is capped.
      final catchUp = math.max(1, ((target.length - _revealed) / 8).ceil());
      final step = _streamRemote
          ? math.min(catchUp, _kCloudRevealStep)
          : catchUp;
      _revealed = math.min(target.length, _revealed + step);
      setState(
        () => _messages[idx] = _messages[idx].copyWith(
          text: target.substring(0, _revealed),
        ),
      );
      _scrollToEndGentle();
    });
  }

  void _finishTyper() {
    _typer?.cancel();
    _typer = null;
    if (_typerDone != null && !_typerDone!.isCompleted) _typerDone!.complete();
  }

  void _cancelTyper() {
    _finishTyper();
    _streamTarget = '';
    _revealed = 0;
    _streamDone = false;
    _streamSource = null;
    _streamSources = const [];
    _streamSourceTotal = 0;
    _streamThinking = '';
    _thinkingActive = false;
    _thinkingStart = null;
    _thinkingSeconds = null;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  // Starts voice input: mic permission → one-time model download → record.
  // The composer morphs into the "Listening…" waveform bar once recording runs.
  Future<void> _startVoice() async {
    if (_voiceState != _VoiceState.idle) return;
    if (!await _voice.hasMicPermission()) {
      if (mounted) _toast('Microphone access is needed for voice input.');
      return;
    }
    if (!await _voice.isModelReady()) {
      if (!mounted) return;
      final ok = await VoiceModelSheet.show(context, _voice) ?? false;
      if (!ok) return;
      // Let Settings (always mounted in the nav stack) notice the new model.
      ref.invalidate(voiceModelReadyProvider);
    }
    try {
      await _voice.startRecording();
      if (mounted) {
        setState(() {
          _amplitude = _voice.amplitudeStream();
          _voiceState = _VoiceState.recording;
        });
      }
    } catch (_) {
      if (mounted) _toast("Couldn't start recording.");
    }
  }

  // The ✓ control: stop recording and transcribe on-device, dropping the text
  // into the composer for the user to review. Never auto-sends.
  Future<void> _stopVoice() async {
    if (_voiceState != _VoiceState.recording) return;
    setState(() => _voiceState = _VoiceState.transcribing);
    try {
      final text = await _voice.stopAndTranscribe();
      if (!mounted) return;
      if (text == null) {
        _toast("Didn't catch that. Try again.");
      } else {
        // Review, never auto-send: append to whatever is already typed.
        final existing = _input.text.trim();
        final combined = existing.isEmpty ? text : '$existing $text';
        _input.text = combined;
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      }
    } catch (_) {
      if (mounted) _toast('Voice input failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() {
          _amplitude = null;
          _voiceState = _VoiceState.idle;
        });
      }
    }
  }

  // The ✕ control: discard the in-progress recording, back to the composer.
  Future<void> _cancelVoice() async {
    if (_voiceState != _VoiceState.recording) return;
    await _voice.cancelRecording();
    if (mounted) {
      setState(() {
        _amplitude = null;
        _voiceState = _VoiceState.idle;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Active model comes from the shared reactive provider, so switching it here
    // or in Settings keeps this header label in sync.
    final activeModel = ref.watch(aiModelStateProvider).value?.active;
    // Which engine is actually answering (on-device or the opt-in cloud model) —
    // the header label reflects this so the user always knows what they're using.
    final engine = ref.watch(activeEngineProvider).value;
    final onRemote = engine?.isRemote ?? false;
    // Think-harder pref drives the reasoning toggle in the composer, shown only
    // for reasoning-capable on-device models (e.g. Qwen3); never for cloud.
    final thinking = ref.watch(thinkHarderProvider).value ?? false;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.canvas,
      ),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // Top bar.
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                      color: AppColors.ink,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const CuraSpark(size: 32),
                    const SizedBox(width: 8),
                    // Expanded (not Flexible + Spacer) so the title line claims
                    // the leftover width and shows "Ask your records" in full,
                    // with the tappable model selector on the line beneath it.
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ask your records',
                            style: textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          _ModelSelectorLabel(
                            label:
                                engine?.label ??
                                activeModel?.displayName ??
                                'No model',
                            onTap: _busy ? null : _openModelSwitcher,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.history, size: 22),
                      color: AppColors.secondary,
                      tooltip: 'Chat history',
                      onPressed: _openHistory,
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_comment_outlined, size: 22),
                      color: AppColors.secondary,
                      tooltip: 'New chat',
                      onPressed: _newChat,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.hairline),

              // Thread.
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  children: [
                    if (_messages.isEmpty)
                      _MessageBubble(
                        message: ChatMessage(
                          role: ChatRole.assistant,
                          text: widget.prompts.welcome,
                        ),
                        onViewSource: widget.onOpenDocument,
                      ),
                    for (var i = 0; i < _messages.length; i++)
                      _MessageBubble(
                        message: _messages[i],
                        onViewSource: widget.onOpenDocument,
                        // Only the last question offers Edit.
                        onEdit: i == _editableIndex && _editingIndex == null
                            ? () => _editLastQuestion(i)
                            : null,
                      ),
                    // Only while waiting for the first token; once the assistant
                    // bubble exists it grows in place instead.
                    if (_busy &&
                        (_messages.isEmpty ||
                            _messages.last.role == ChatRole.user))
                      const _TypingBubble(),
                    if (_showSuggestions)
                      _Suggestions(
                        items: widget.prompts.suggestions,
                        onTap: _send,
                      ),
                  ],
                ),
              ),

              // Footer: disclaimer + input bar.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Text(
                  'Organizes and explains your documents. Not medical advice.',
                  textAlign: TextAlign.center,
                  style: textTheme.labelSmall,
                ),
              ),
              _InputBar(
                controller: _input,
                focusNode: _inputFocus,
                onSend: () => _send(_input.text),
                busy: _busy,
                onStop: _stopAnswer,
                editing: _editingIndex != null,
                onCancelEdit: _cancelEditing,
                onStartVoice: _startVoice,
                onStopVoice: _stopVoice,
                onCancelVoice: _cancelVoice,
                voiceState: _voiceState,
                amplitude: _amplitude,
                // Reasoning toggle lives in the composer, but only for models
                // that support thinking (e.g. Qwen3) — otherwise the pill stays
                // clean. The model itself is switched from the header selector.
                showThink: !onRemote && (activeModel?.canThink ?? false),
                thinking: thinking,
                onToggleThink: _busy ? null : () => _setThinkHarder(!thinking),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the long-press menu on a message offers.
enum _MessageAction { copy, edit }

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.onViewSource,
    this.onEdit,
  });

  final ChatMessage message;
  final ValueChanged<CuraDocument> onViewSource;

  /// Set only on the message that can be re-asked.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final child = isUser ? _userBubble(context) : _assistant(context);
    return GestureDetector(
          // The press position anchors the menu beside its message.
          onLongPressStart: (details) =>
              _openMenu(context, details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Align(
              alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
              child: child,
            ),
          ),
        )
        .animate()
        .fadeIn(duration: 300.ms)
        .slideY(begin: 0.1, curve: Curves.easeOutCubic);
  }

  Future<void> _openMenu(BuildContext context, Offset at) async {
    if (message.text.trim().isEmpty) return;
    unawaited(HapticFeedback.selectionClick());
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<_MessageAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        at.dx,
        at.dy,
        overlay.size.width - at.dx,
        overlay.size.height - at.dy,
      ),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.hairline),
      ),
      items: [
        _menuItem(_MessageAction.copy, Icons.copy_rounded, 'Copy'),
        if (onEdit != null)
          _menuItem(_MessageAction.edit, Icons.edit_outlined, 'Edit message'),
      ],
    );
    switch (action) {
      case null:
        return;
      case _MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: message.text));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Copied'),
              behavior: SnackBarBehavior.floating,
            ),
          );
      case _MessageAction.edit:
        onEdit?.call();
    }
  }

  PopupMenuItem<_MessageAction> _menuItem(
    _MessageAction value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<_MessageAction>(
      value: value,
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 19, color: AppColors.ink),
          const SizedBox(width: 14),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 14.5,
              color: AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _userBubble(BuildContext context) {
    final width = MediaQuery.of(context).size.width * 0.78;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: const BoxDecoration(
          color: AppColors.mint,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Text(
          message.text,
          style: const TextStyle(
            fontFamily: 'PlusJakartaSans',
            fontSize: 14.5,
            height: 1.4,
            color: AppColors.userBubbleText,
          ),
        ),
      ),
    );
  }

  Widget _assistant(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final width = MediaQuery.of(context).size.width * 0.86;
    final hasThinking =
        message.thinking != null && message.thinking!.isNotEmpty;
    // Hide the answer card only while reasoning is still streaming (no answer
    // yet); otherwise always show it so a normal reply never flickers.
    final showAnswer = message.text.isNotEmpty || !message.thinkingActive;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasThinking) ...[
            _ThinkingPanel(
              text: message.thinking!,
              active: message.thinkingActive,
              seconds: message.thinkingSeconds,
            ),
            if (showAnswer) const SizedBox(height: 8),
          ],
          if (showAnswer)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const CuraSpark(size: 24),
                      const SizedBox(width: 6),
                      Text(
                        'Cura',
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.secondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _answerText(textTheme),
                ],
              ),
            ),
          // Cited reports. A count over several reports carries [sources]; every
          // other cited answer carries a single [source]. Both render as cards.
          if (message.sources.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SourceCardList(sources: message.sources, onView: onViewSource),
          ] else if (message.source != null) ...[
            const SizedBox(height: 8),
            _SourceCard(
              document: message.source!,
              onView: () => onViewSource(message.source!),
            ),
          ],
        ],
      ),
    );
  }

  Widget _answerText(TextTheme textTheme) {
    final base = textTheme.bodyMedium?.copyWith(height: 1.5);
    const boldStyle = TextStyle(
      fontWeight: FontWeight.w600,
      fontVariations: [FontVariation('wght', 600)],
      color: AppColors.accent,
    );
    final headingStyle = base?.copyWith(
      fontWeight: FontWeight.w700,
      fontVariations: const [FontVariation('wght', 700)],
      color: AppColors.accent,
    );
    final text = message.text;

    // The model writes Markdown: `**bold**` / `__bold__` runs and `### heading`
    // lines. Render those and drop the markers so raw `**` / `###` never show.
    // Bullets ("- ") are left as-is; they read fine as plain lines.
    if (_hasMarkdown(text)) {
      return Text.rich(
        TextSpan(
          style: base,
          children: _blockSpans(text, boldStyle, headingStyle),
        ),
      );
    }

    // No Markdown → keep the router's single highlighted value (its `emphasis`).
    final emphasis = message.emphasis;
    if (emphasis == null || !text.contains(emphasis)) {
      return Text(text, style: base);
    }
    final parts = text.split(emphasis);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: parts[0]),
          TextSpan(text: emphasis, style: boldStyle),
          TextSpan(
            text: parts.length > 1 ? parts.sublist(1).join(emphasis) : '',
          ),
        ],
      ),
    );
  }

  static final _headingRe = RegExp(r'^\s*#{1,6}\s+(.*)$');

  bool _hasMarkdown(String text) =>
      text.contains('**') ||
      text.contains('__') ||
      RegExp(r'(^|\n)\s*#{1,6}\s').hasMatch(text);

  /// Builds spans line-by-line: an ATX `### heading` line becomes a bold heading
  /// (markers stripped); every other line gets inline `**bold**` handling. Not a
  /// full Markdown parser — just what the model actually emits.
  List<InlineSpan> _blockSpans(
    String text,
    TextStyle boldStyle,
    TextStyle? headingStyle,
  ) {
    final spans = <InlineSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final heading = _headingRe.firstMatch(lines[i]);
      if (heading != null) {
        spans.add(
          TextSpan(text: heading.group(1)!.trim(), style: headingStyle),
        );
      } else {
        spans.addAll(_inlineSpans(lines[i], boldStyle));
      }
      if (i < lines.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return spans;
  }

  /// Splits [text] into spans, turning `**bold**` runs into [boldStyle]. One
  /// tolerant pass, not a Markdown parser; an unmatched marker stays literal.
  List<InlineSpan> _inlineSpans(String text, TextStyle boldStyle) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'(\*\*|__)(.+?)\1', dotAll: true);
    var i = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      spans.add(TextSpan(text: m.group(2), style: boldStyle));
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return spans;
  }
}

/// Collapsible panel showing a reasoning model's chain-of-thought as it streams.
/// Expanded while live, then auto-collapses once to "Thought for Xs" unless the
/// user has toggled it.
class _ThinkingPanel extends StatefulWidget {
  const _ThinkingPanel({
    required this.text,
    required this.active,
    required this.seconds,
  });

  final String text;
  final bool active;
  final int? seconds;

  @override
  State<_ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<_ThinkingPanel> {
  late bool _expanded = widget.active;
  bool _userToggled = false;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_ThinkingPanel old) {
    super.didUpdateWidget(old);
    // Auto-collapse once, when reasoning finishes — unless the user chose a state.
    if (old.active && !widget.active && !_userToggled) {
      _expanded = false;
    }
    // Keep the newest reasoning in view while it streams and is open.
    if (_expanded && widget.active && widget.text != old.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final label = widget.active
        ? 'Thinking…'
        : (widget.seconds != null
              ? 'Thought for ${widget.seconds}s'
              : 'Thoughts');
    return Container(
      decoration: BoxDecoration(
        color: AppColors.softTint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() {
              _expanded = !_expanded;
              _userToggled = true;
            }),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    widget.active
                        ? Icons.psychology
                        : Icons.psychology_outlined,
                    size: 17,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.secondary,
                      fontWeight: FontWeight.w500,
                      fontVariations: const [FontVariation('wght', 500)],
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(
                      Icons.expand_more,
                      size: 18,
                      color: AppColors.chevron,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 150),
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: Text(
                    widget.text,
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.faint,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Neutral loading placeholder shown before the first token arrives (model load
/// + prefill). Three pulsing dots — no wording — so it doesn't clash with the
/// live "Thinking…" panel that follows for reasoning models.
class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  Widget _dot(int i) {
    return Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            color: AppColors.mint,
            shape: BoxShape.circle,
          ),
        )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fadeIn(begin: 0.3, duration: 400.ms, delay: (i * 150).ms);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dot(0),
              const SizedBox(width: 6),
              _dot(1),
              const SizedBox(width: 6),
              _dot(2),
            ],
          ),
        ),
      ),
    ).animate().fadeIn(duration: 250.ms);
  }
}

/// A collection answer cites every validated report: two show initially, and
/// "+N more" expands the complete source set inline.
class _SourceCardList extends StatefulWidget {
  const _SourceCardList({required this.sources, required this.onView});

  final List<CuraDocument> sources;
  final ValueChanged<CuraDocument> onView;

  @override
  State<_SourceCardList> createState() => _SourceCardListState();
}

class _SourceCardListState extends State<_SourceCardList> {
  static const _collapsedCount = 2;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final sources = widget.sources;
    // [sources] is authoritative. Normalize defensive legacy/malformed totals
    // so the UI never promises cards that it cannot actually display.
    final total = sources.length;
    final visible = _expanded
        ? sources
        : sources.take(_collapsedCount).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < visible.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _SourceCard(
            document: visible[i],
            onView: () => widget.onView(visible[i]),
          ),
        ],
        if (total > _collapsedCount)
          _MoreReportsRow(
            label: _expanded ? 'Show less' : '+${total - _collapsedCount} more',
            expanded: _expanded,
            onTap: () => setState(() => _expanded = !_expanded),
          ),
      ],
    );
  }
}

/// The tappable "+N more" affordance under a stacked source list.
class _MoreReportsRow extends StatelessWidget {
  const _MoreReportsRow({
    required this.label,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  fontVariations: [FontVariation('wght', 500)],
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: AppColors.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact cited-source card under an answer.
class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.document, required this.onView});

  final CuraDocument document;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: document.type.tileColor,
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: Icon(
              document.type.icon,
              size: 19,
              color: document.type.accentColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document.title,
                  style: textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${document.dateLabel} · ${document.type.label}',
                  style: textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onView,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 36),
              textStyle: const TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: 14,
                fontWeight: FontWeight.w500,
                fontVariations: [FontVariation('wght', 500)],
              ),
            ),
            child: const Text('View'),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet listing saved conversations to reopen or delete.
class _HistorySheet extends ConsumerWidget {
  const _HistorySheet({
    required this.currentId,
    required this.onOpen,
    required this.onDelete,
  });

  final String? currentId;
  final ValueChanged<ChatSession> onOpen;
  final ValueChanged<ChatSession> onDelete;

  String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${t.day}/${t.month}/${t.year}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final sessions = ref.watch(chatSessionsProvider).value ?? const [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: Text('Chat history', style: textTheme.titleMedium),
            ),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 16, 8, 16),
                child: Text(
                  'No saved chats yet.',
                  style: textTheme.bodyMedium?.copyWith(color: AppColors.faint),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sessions.length,
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    final active = s.id == currentId;
                    return ListTile(
                      contentPadding: const EdgeInsets.only(right: 4),
                      leading: Icon(
                        active ? Icons.chat_bubble : Icons.chat_bubble_outline,
                        color: active ? AppColors.mint : AppColors.chevron,
                        size: 20,
                      ),
                      title: Text(
                        s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium,
                      ),
                      subtitle: Text(
                        _relative(s.updatedAt),
                        style: textTheme.bodySmall,
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: AppColors.destructive,
                        ),
                        onPressed: () => onDelete(s),
                      ),
                      onTap: () => onOpen(s),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.items, required this.onTap});

  final List<String> items;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final s in items)
            Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: () => onTap(s),
                borderRadius: BorderRadius.circular(999),
                child: Ink(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.hairline),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Text(
                    s,
                    style: const TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      fontVariations: [FontVariation('wght', 500)],
                      color: AppColors.secondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.busy,
    required this.onStop,
    required this.editing,
    required this.onCancelEdit,
    required this.onStartVoice,
    required this.onStopVoice,
    required this.onCancelVoice,
    required this.voiceState,
    required this.amplitude,
    required this.showThink,
    required this.thinking,
    required this.onToggleThink,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;

  /// While an answer streams the send button becomes a stop button.
  final bool busy;
  final VoidCallback onStop;

  /// True while the last question is being rewritten; shows the chip.
  final bool editing;
  final VoidCallback onCancelEdit;

  /// Voice controls: start (mic), and while recording, stop (✓) / cancel (✕).
  final VoidCallback onStartVoice;
  final VoidCallback onStopVoice;
  final VoidCallback onCancelVoice;

  /// Voice-input phase — decides which "face" of the composer is shown.
  final _VoiceState voiceState;

  /// Live mic level (0–1) while recording; null otherwise.
  final Stream<double>? amplitude;

  /// Whether to show the reasoning toggle (active model supports thinking).
  final bool showThink;

  /// Current "Think harder" state.
  final bool thinking;

  /// Flips "Think harder". Null (disabled/greyed) while an answer streams.
  final VoidCallback? onToggleThink;

  // One height for all three faces so swapping doesn't jump the footer.
  static const double _barHeight = 52;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (editing) _editingChip(context),
          // The three faces (compose / listening / transcribing) cross-fade in
          // the same footprint, so recording visibly takes over the composer.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.97, end: 1).animate(animation),
                child: child,
              ),
            ),
            child: _face(context),
          ),
        ],
      ),
    );
  }

  /// Says why the composer already has text in it.
  Widget _editingChip(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.edit_outlined, size: 14, color: AppColors.secondary),
          const SizedBox(width: 6),
          Text(
            'Editing your last question',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: AppColors.secondary),
          ),
          IconButton(
            onPressed: onCancelEdit,
            icon: const Icon(Icons.close, size: 15),
            color: AppColors.secondary,
            tooltip: 'Cancel editing',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.only(left: 6),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
          ),
        ],
      ),
    );
  }

  Widget _face(BuildContext context) {
    switch (voiceState) {
      case _VoiceState.recording:
        return _ListeningBar(
          key: const ValueKey('voice-recording'),
          height: _barHeight,
          amplitude: amplitude,
          onCancel: onCancelVoice,
          onStop: onStopVoice,
        );
      case _VoiceState.transcribing:
        return const _TranscribingBar(
          key: ValueKey('voice-transcribing'),
          height: _barHeight,
        );
      case _VoiceState.idle:
        return _composer(context);
    }
  }

  Widget _composer(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      key: const ValueKey('voice-idle'),
      children: [
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: _barHeight),
            padding: const EdgeInsets.only(left: 16, right: 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    style: textTheme.bodyMedium,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: 'Ask anything…',
                      hintStyle: textTheme.bodyMedium?.copyWith(
                        color: AppColors.faint,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                // Reasoning toggle — only present for models that can think, so
                // most models keep a clean text + mic pill.
                if (showThink)
                  _ThinkToggleButton(on: thinking, onTap: onToggleThink),
                _MicButton(onTap: onStartVoice),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Circular send button, a stop button while an answer streams.
        Semantics(
          button: true,
          label: busy ? 'Stop' : 'Send',
          child: Material(
            color: AppColors.accent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: busy ? onStop : onSend,
              child: SizedBox(
                width: 48,
                height: 48,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: Icon(
                    busy ? Icons.stop_rounded : Icons.arrow_upward,
                    key: ValueKey(busy),
                    color: AppColors.canvas,
                    size: busy ? 26 : 24,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The "Listening…" face: the composer becomes a single mint pill with a live
/// waveform on the left, a cancel (✕) and a filled accent stop (✓) on the right.
class _ListeningBar extends StatelessWidget {
  const _ListeningBar({
    super.key,
    required this.height,
    required this.amplitude,
    required this.onCancel,
    required this.onStop,
  });

  final double height;
  final Stream<double>? amplitude;
  final VoidCallback onCancel;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: height,
            padding: const EdgeInsets.only(left: 16, right: 6),
            decoration: BoxDecoration(
              color: AppColors.mintCardFill,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.mintCardBorder),
            ),
            child: Row(
              children: [
                _VoiceWaveform(levels: amplitude),
                const Spacer(),
                Text(
                  'Listening…',
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.secondary,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close, size: 22),
                  color: AppColors.destructive,
                  tooltip: 'Cancel',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                ),
                const SizedBox(width: 2),
                Semantics(
                  button: true,
                  label: 'Stop and transcribe',
                  child: Material(
                    color: AppColors.accent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onStop,
                      child: const SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(
                          Icons.check,
                          color: AppColors.canvas,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The "Transcribing…" face: a full-width pill with a spinner while Whisper
/// works on-device.
class _TranscribingBar extends StatelessWidget {
  const _TranscribingBar({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.mint,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Transcribing…',
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.secondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A continuously animating waveform: mint bars driven by a looping sine, each
/// with its own phase. The mic level only scales the swing, so the bars still
/// move when amplitude reporting is flat. Static under "remove animations".
class _VoiceWaveform extends StatefulWidget {
  const _VoiceWaveform({required this.levels});

  final Stream<double>? levels;

  @override
  State<_VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<_VoiceWaveform>
    with SingleTickerProviderStateMixin {
  static const int _barCount = 16;
  static const double _maxHeight = 22;
  static const double _barWidth = 3.5;
  static const double _gap = 3;

  late final AnimationController _controller;
  // Live mic intensity 0–1 (default mid so motion is lively before/without any
  // amplitude data). Read each tick by the builder; no setState needed.
  double _level = 0.5;
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _sub = widget.levels?.listen((v) => _level = v.clamp(0.0, 1.0));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  double _fracFor(int i, double t) {
    // Two offset sine components give an organic, non-uniform ripple.
    final wave =
        (math.sin(t + i * 0.7) + math.sin(t * 1.6 + i * 0.35)) / 2; // -1..1
    final norm = (wave + 1) / 2; // 0..1
    final swing = 0.30 + 0.70 * _level; // louder → taller dance
    return (0.16 + norm * swing).clamp(0.12, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      // Static but shaped, so it still reads as a waveform.
      return SizedBox(
        height: _maxHeight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < _barCount; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              _bar(_fracFor(i, 0)),
            ],
          ],
        ),
      );
    }
    return SizedBox(
      height: _maxHeight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value * 2 * math.pi;
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _barCount; i++) ...[
                if (i > 0) const SizedBox(width: _gap),
                _bar(_fracFor(i, t)),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _bar(double frac) => Container(
    width: _barWidth,
    height: (_maxHeight * frac).clamp(3.0, _maxHeight),
    decoration: BoxDecoration(
      color: AppColors.mint,
      borderRadius: BorderRadius.circular(999),
    ),
  );
}

/// The composer's idle mic — a quiet outline mic that starts voice input. While
/// recording/transcribing the whole composer is replaced (see _ListeningBar /
/// _TranscribingBar), so this only ever renders the start affordance.
class _MicButton extends StatelessWidget {
  const _MicButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Start voice input',
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: const SizedBox(
          width: 38,
          height: 38,
          child: Center(child: Icon(Icons.mic_none, color: AppColors.faint)),
        ),
      ),
    );
  }
}

/// The "Think harder" toggle in the composer, shown only for reasoning-capable
/// models. Filled brain when on, outline when off; disabled while an answer
/// streams.
class _ThinkToggleButton extends StatelessWidget {
  const _ThinkToggleButton({required this.on, required this.onTap});

  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final iconColor = on
        ? AppColors.accent
        : (enabled ? AppColors.chevron : AppColors.faint);
    return Tooltip(
      message: on ? 'Think harder: on' : 'Think harder: off',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: on
              ? BoxDecoration(
                  color: AppColors.softTint,
                  borderRadius: BorderRadius.circular(999),
                )
              : null,
          child: Icon(
            on ? Icons.psychology : Icons.psychology_outlined,
            size: 20,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}

/// The active-model line under the "Ask your records" title: a compact, tappable
/// label + chevron that opens the model switcher. Greyed out (null [onTap]) while
/// an answer is streaming.
class _ModelSelectorLabel extends StatelessWidget {
  const _ModelSelectorLabel({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final enabled = onTap != null;
    final color = enabled ? AppColors.secondary : AppColors.faint;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
            Icon(Icons.expand_more, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet to switch the active on-device model without leaving the chat.
/// Mirrors the Settings model card: switch between downloaded models, or download
/// one that isn't installed yet. Loads its own installed/active state.
class _ModelSwitcherSheet extends ConsumerStatefulWidget {
  const _ModelSwitcherSheet();

  @override
  ConsumerState<_ModelSwitcherSheet> createState() =>
      _ModelSwitcherSheetState();
}

class _ModelSwitcherSheetState extends ConsumerState<_ModelSwitcherSheet> {
  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _use(AiModel model) async {
    await ref.read(aiModelManagerProvider).activate(model);
    // Picking an on-device model also switches the engine back off cloud.
    await ref.read(remoteAiStoreProvider).setEngine(AiEngine.local);
    ref.invalidate(aiServiceProvider);
    ref.invalidate(aiModelStateProvider);
    ref.invalidate(activeEngineProvider);
    if (!mounted) return;
    _toast('Now using ${model.displayName}');
    Navigator.of(context).pop();
  }

  Future<void> _download(AiModel model) async {
    final ok = await ModelDownloadSheet.show(context, model) ?? false;
    if (!ok || !mounted) return;
    // A fresh download is activated by the manager; release the old warm model
    // and refresh the shared state so the header and Settings pick it up.
    ref.invalidate(aiServiceProvider);
    ref.invalidate(aiModelStateProvider);
    _toast('Now using ${model.displayName}');
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Shared reactive state — same source the Settings card and Ask header use.
    final state = ref.watch(aiModelStateProvider).value;
    final engine = ref.watch(activeEngineProvider).value;
    final onRemote = engine?.isRemote ?? false;
    final loading = state == null;
    final active = state?.active;
    final installed = state?.installed ?? const <String>{};
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('Choose model', style: textTheme.titleMedium),
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.mint,
                    ),
                  ),
                ),
              )
            else ...[
              for (final model in kAiModelCatalog)
                _SwitcherRow(
                  model: model,
                  installed: installed.contains(model.id),
                  // On cloud, no on-device model reads as active.
                  active: !onRemote && active?.id == model.id,
                  onUse: () => _use(model),
                  onDownload: () => _download(model),
                ),
              // The configured cloud model, when the user has set one up in
              // Settings — one tap to switch on-device ↔ cloud.
              if (engine?.remoteConfigured ?? false)
                _CloudSwitcherRow(label: engine!.remoteLabel, active: onRemote),
            ],
          ],
        ),
      ),
    );
  }
}

/// One model row in the switcher sheet.
class _SwitcherRow extends StatelessWidget {
  const _SwitcherRow({
    required this.model,
    required this.installed,
    required this.active,
    required this.onUse,
    required this.onDownload,
  });

  final AiModel model;
  final bool installed;
  final bool active;
  final VoidCallback onUse;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Installed + not active → tap the row to switch. Active or not-installed
    // rows aren't row-tappable (active is a no-op; not-installed uses Download).
    final onTap = installed && !active ? onUse : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: active ? AppColors.softTint : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: active ? AppColors.accent : AppColors.hairline,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  active
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: active
                      ? AppColors.accent
                      : (installed ? AppColors.chevron : AppColors.faint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.displayName, style: textTheme.bodyMedium),
                      const SizedBox(height: 2),
                      Text(
                        active
                            ? 'In use · ${model.sizeLabel}'
                            : installed
                            ? 'Downloaded · ${model.sizeLabel}'
                            : model.sizeLabel,
                        style: textTheme.bodySmall?.copyWith(
                          color: active ? AppColors.accent : AppColors.faint,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!installed)
                  TextButton(
                    onPressed: onDownload,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                    ),
                    child: const Text('Download'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The cloud-model row in the switcher sheet. Display-only, since the engine is
/// enabled from Settings: when cloud is inactive the row is greyed with a
/// "Turn on in Settings" hint rather than being selectable.
class _CloudSwitcherRow extends StatelessWidget {
  const _CloudSwitcherRow({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Greyed when off — cloud is turned on from Settings, not here.
    final titleColor = active ? AppColors.ink : AppColors.faint;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: active ? AppColors.softTint : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? AppColors.accent : AppColors.hairline,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: active ? AppColors.accent : AppColors.chevron,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: textTheme.bodyMedium?.copyWith(color: titleColor),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      active ? 'In use · Cloud' : 'Turn on in Settings',
                      style: textTheme.bodySmall?.copyWith(
                        color: active ? AppColors.accent : AppColors.faint,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.cloud_outlined,
                size: 18,
                color: active ? AppColors.chevron : AppColors.faint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
