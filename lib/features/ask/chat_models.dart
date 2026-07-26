import '../library/document.dart' show CuraDocument;

/// Who sent a chat message.
enum ChatRole { user, assistant }

/// Packs a message's cited sources into the single `sourceDocId` column, so no
/// migration is needed: one source stores its bare id, several store
/// `id1,id2,...#N` with the validated match count. Null when nothing to cite.
String? encodeSourceRef(List<CuraDocument> sources, int total) {
  if (sources.isEmpty) return null;
  if (sources.length <= 1) return sources.first.id;
  return '${sources.map((d) => d.id).join(',')}#$total';
}

/// Inverse of [encodeSourceRef]. Legacy rows (a bare id, no separators) decode
/// to a single id with total 1. Never throws on malformed input.
({List<String> ids, int total}) decodeSourceRef(String raw) {
  final hash = raw.indexOf('#');
  final idPart = hash < 0 ? raw : raw.substring(0, hash);
  final ids = idPart.split(',').where((s) => s.isNotEmpty).toList();
  final total = hash < 0 ? ids.length : int.tryParse(raw.substring(hash + 1));
  return (ids: ids, total: total ?? ids.length);
}

/// A saved Ask conversation (header). Messages are loaded separately.
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

/// A persisted chat message. [sourceDocId] is the cited document's id (resolved
/// to a CuraDocument at render time), or null.
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
