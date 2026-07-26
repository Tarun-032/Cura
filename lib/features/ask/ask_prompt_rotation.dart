import 'package:shared_preferences/shared_preferences.dart';

/// One stable set of copy for a single visit to Ask.
class AskPromptSet {
  const AskPromptSet({required this.welcome, required this.suggestions});

  final String welcome;
  final List<String> suggestions;
}

/// Short examples that fit the two-line Home card on narrow phones.
const kHomeAskExamples = <String>[
  'What was my latest result?',
  'Summarize my newest report.',
  'How many records do I have?',
  'List my recent documents.',
  'What does my latest report say?',
];

/// Generic prompts only: every chip remains useful regardless of which document
/// types happen to be stored on the phone.
const kAskPromptSets = <AskPromptSet>[
  AskPromptSet(
    welcome: 'Ask about a result, date, or report in your records.',
    suggestions: ['Summarize my latest report', 'What were my recent results?'],
  ),
  AskPromptSet(
    welcome: 'I can find values and dates in your saved documents.',
    suggestions: ['What is my latest report?', 'How many records do I have?'],
  ),
  AskPromptSet(
    welcome: 'Ask me to organize or explain what your records contain.',
    suggestions: ['List all my reports', 'Summarize my newest report'],
  ),
  AskPromptSet(
    welcome: 'Choose a question below, or ask about any saved document.',
    suggestions: ['What documents do I have?', 'Show my latest results'],
  ),
];

const _homePromptIndexKey = 'cura_home_prompt_index';
const _askPromptSetIndexKey = 'cura_ask_prompt_set_index';

/// Advances the two prompt cycles with no randomness. Persisted indexes carry
/// across cold launches; the in-memory copies prevent repeats if a write fails.
class AskPromptRotation {
  int? _homeIndex;
  int? _askIndex;

  Future<String> takeNextHomeExample() async {
    final index = await _takeNext(
      key: _homePromptIndexKey,
      length: kHomeAskExamples.length,
      memoryIndex: _homeIndex,
      remember: (value) => _homeIndex = value,
    );
    return kHomeAskExamples[index];
  }

  Future<AskPromptSet> takeNextAskSet() async {
    final index = await _takeNext(
      key: _askPromptSetIndexKey,
      length: kAskPromptSets.length,
      memoryIndex: _askIndex,
      remember: (value) => _askIndex = value,
    );
    return kAskPromptSets[index];
  }

  Future<int> _takeNext({
    required String key,
    required int length,
    required int? memoryIndex,
    required void Function(int) remember,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final previous = memoryIndex ?? prefs.getInt(key) ?? -1;
      final next = (previous + 1) % length;
      remember(next);
      await prefs.setInt(key, next);
      return next;
    } catch (_) {
      final next = ((memoryIndex ?? -1) + 1) % length;
      remember(next);
      return next;
    }
  }
}

final askPromptRotation = AskPromptRotation();
