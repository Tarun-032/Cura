/// ChatML prompt formatting (mirrors native template).
library;

const String _imStart = '<|im_start|>';
const String _imEnd = '<|im_end|>';

/// System block.
String chatmlSystemBlock(String system) => '$_imStart' 'system\n$system$_imEnd\n';

/// Incremental user turn. `closePrev` closes a previous open assistant turn.
String chatmlUserTurn(String content, {required bool closePrev}) =>
    '${closePrev ? '$_imEnd\n' : ''}$_imStart'
    'user\n$content$_imEnd\n$_imStart'
    'assistant\n';

/// Full conversation format builder.
String chatmlFull(List<({String role, String text})> turns) {
  final b = StringBuffer();
  for (final t in turns) {
    b.write('$_imStart${t.role}\n${t.text}$_imEnd\n');
  }
  b.write('$_imStart' 'assistant\n');
  return b.toString();
}
