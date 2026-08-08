import '../library/document.dart' show CuraDocument;

/// Who sent a chat message.
enum ChatRole { user, assistant, notice }

/// The last model label recorded for the session.
String? lastRecordedModel(List<StoredMessage> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role == ChatRole.notice) return messages[i].text;
  }
  return null;
}

/// The label to record before the next question, if needed.
String? modelNoticeFor({required String? recorded, required String current}) {
  final label = current.trim();
  if (label.isEmpty || label == recorded) return null;
  return label;
}

/// Packs cited sources into a single stored value.
String? encodeSourceRef(List<CuraDocument> sources, int total) {
  if (sources.isEmpty) return null;
  if (sources.length <= 1) return sources.first.id;
  return '${sources.map((d) => d.id).join(',')}#$total';
}

/// Inverse of [encodeSourceRef].
({List<String> ids, int total}) decodeSourceRef(String raw) {
  final hash = raw.indexOf('#');
  final idPart = hash < 0 ? raw : raw.substring(0, hash);
  final ids = idPart.split(',').where((s) => s.isNotEmpty).toList();
  final total = hash < 0 ? ids.length : int.tryParse(raw.substring(hash + 1));
  return (ids: ids, total: total ?? ids.length);
}

/// A saved Ask conversation header.
class ChatSession {
  const ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// A persisted chat message.
class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.sourceDocId,
  });

  final String id;
  final ChatRole role;
  final String text;
  final DateTime createdAt;
  final String? sourceDocId;
}
