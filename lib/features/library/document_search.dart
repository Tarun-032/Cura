import 'document.dart';

/// Case-insensitive keyword search over a document's visible text: title, type,
/// date, extracted text, results, note and tags. Terms are ANDed, so extra words
/// narrow rather than widen. An empty query returns the list unchanged.
List<CuraDocument> searchDocuments(List<CuraDocument> docs, String query) {
  final terms = _terms(query);
  if (terms.isEmpty) return docs;
  return docs.where((d) {
    final hay = _haystack(d);
    return terms.every(hay.contains);
  }).toList();
}

/// Whether a single document matches [query] (same rules as [searchDocuments]).
bool documentMatchesQuery(CuraDocument doc, String query) {
  final terms = _terms(query);
  if (terms.isEmpty) return true;
  final hay = _haystack(doc);
  return terms.every(hay.contains);
}

List<String> _terms(String query) => query
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((t) => t.isNotEmpty)
    .toList();

/// One lowercase blob of everything worth matching on, joined by spaces.
String _haystack(CuraDocument d) {
  final b = StringBuffer()
    ..write(d.title.toLowerCase())
    ..write(' ')
    ..write(d.type.label.toLowerCase())
    ..write(' ')
    ..write(d.dateLabel.toLowerCase())
    ..write(' ')
    ..write(d.extractedText.toLowerCase())
    ..write(' ')
    ..write(d.resultsNote?.toLowerCase() ?? '')
    ..write(' ')
    ..write(d.tags.join(' ').toLowerCase())
    ..write(' ');
  for (final r in d.results) {
    b
      ..write(r.label.toLowerCase())
      ..write(' ')
      ..write(r.value.toLowerCase())
      ..write(' ')
      ..write(r.range?.toLowerCase() ?? '')
      ..write(' ');
  }
  return b.toString();
}
