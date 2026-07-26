/// ChatML prompt formatting, mirrored from the plugin's native `ChatMLTemplate`
/// (`llama_flutter_android` → `ChatTemplates.kt`) so the same prompt can be built
/// incrementally, one turn at a time, and reuse the model's KV cache.
///
/// `generateChat` re-formats and re-prefills the whole conversation every call.
/// Ask instead feeds the model only the *new* turn via the raw `generate()` API
/// and keeps the KV cache warm across turns (see `AiService`). That is safe only
/// while the incremental context is **byte-identical** to a full rebuild, so
/// these helpers are exact copies of the native template and are covered by
/// golden tests (`test/chat_format_test.dart`).
///
/// ChatML format (Qwen 2.5 / Qwen3 / LFM2.5 — all `template: 'chatml'`):
/// ```
/// <|im_start|>{role}\n{content}<|im_end|>\n     (repeated per turn)
/// <|im_start|>assistant\n                        (generation prompt)
/// ```
/// The native `ChatMLTemplate` does **not** trim content, so neither does this.
library;

const String _imStart = '<|im_start|>';
const String _imEnd = '<|im_end|>';

/// The system block that anchors a conversation's KV cache: a single closed
/// `system` turn, with **no** trailing generation prompt (user turns are appended
/// after it). Feeding this alone pre-warms the system prompt.
String chatmlSystemBlock(String system) => '$_imStart' 'system\n$system$_imEnd\n';

/// One incremental user turn to append onto a warm KV cache, ending with the
/// assistant generation prompt so the model answers next.
///
/// [closePrev] closes a preceding **open** assistant answer already sitting in
/// the cache — after generation the KV ends `...<|im_start|>assistant\n{answer}`
/// with no `<|im_end|>` (the plugin breaks on EOS before decoding the stop
/// token), so the next turn must add it. It is `false` right after a clean
/// [chatmlSystemBlock], which already ends with `<|im_end|>\n`.
String chatmlUserTurn(String content, {required bool closePrev}) =>
    '${closePrev ? '$_imEnd\n' : ''}$_imStart'
    'user\n$content$_imEnd\n$_imStart'
    'assistant\n';

/// Full-conversation format — the from-scratch rebuild, identical to the native
/// `ChatMLTemplate.format`. [turns] are `(role, text)` in order (`system` /
/// `user` / `assistant`); a trailing assistant generation prompt is appended.
String chatmlFull(List<({String role, String text})> turns) {
  final b = StringBuffer();
  for (final t in turns) {
    b.write('$_imStart${t.role}\n${t.text}$_imEnd\n');
  }
  b.write('$_imStart' 'assistant\n');
  return b.toString();
}
