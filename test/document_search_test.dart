// Tests for the pure keyword search behind the library search bar.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/library/document.dart';
import 'package:cura/features/library/document_search.dart';

CuraDocument _doc({
  required String id,
  required String title,
  required DocumentType type,
  DateTime? date,
  String extractedText = '',
  List<DocumentResult> results = const [],
  String? resultsNote,
  List<String> tags = const [],
}) =>
    CuraDocument(
      id: id,
      title: title,
      type: type,
      date: date ?? DateTime(2025, 4, 12),
      extractedText: extractedText,
      results: results,
      resultsNote: resultsNote,
      tags: tags,
    );

void main() {
  final cbc = _doc(
    id: 'cbc',
    title: 'Complete blood count',
    type: DocumentType.lab,
    date: DateTime(2025, 4, 12),
    extractedText: 'Hemoglobin 14.2 g/dL. Within normal range.',
    results: [const DocumentResult('Hemoglobin', '14.2 g/dL')],
    tags: ['bloodwork', 'annual'],
  );
  final rx = _doc(
    id: 'rx',
    title: 'Amoxicillin 500 mg',
    type: DocumentType.prescription,
    date: DateTime(2025, 4, 2),
    extractedText: 'Take one capsule three times daily.',
    tags: ['antibiotic'],
  );
  final receipt = _doc(
    id: 'receipt',
    title: 'City Pharmacy receipt',
    type: DocumentType.receipt,
    date: DateTime(2024, 3, 28),
    results: [const DocumentResult('Total', r'$24.50')],
    tags: ['pharmacy'],
  );
  final docs = [cbc, rx, receipt];

  List<String> ids(List<CuraDocument> ds) => ds.map((d) => d.id).toList();

  test('empty / whitespace query returns everything', () {
    expect(ids(searchDocuments(docs, '')), ['cbc', 'rx', 'receipt']);
    expect(ids(searchDocuments(docs, '   ')), ['cbc', 'rx', 'receipt']);
  });

  test('matches on title, case-insensitively', () {
    expect(ids(searchDocuments(docs, 'amoxicillin')), ['rx']);
    expect(ids(searchDocuments(docs, 'AMOXICILLIN')), ['rx']);
  });

  test('matches on extracted text', () {
    expect(ids(searchDocuments(docs, 'hemoglobin')), ['cbc']);
  });

  test('matches on tags', () {
    expect(ids(searchDocuments(docs, 'antibiotic')), ['rx']);
  });

  test('matches on the type label', () {
    expect(ids(searchDocuments(docs, 'receipt')), ['receipt']);
  });

  test('matches on the formatted date label (month + year)', () {
    // dateLabel is e.g. "Apr 12, 2025".
    expect(ids(searchDocuments(docs, 'apr 2025')), ['cbc', 'rx']);
  });

  test('multiple terms are ANDed (narrow, not widen)', () {
    expect(ids(searchDocuments(docs, 'blood count')), ['cbc']);
    // "blood" alone hits the tag/title; adding "pharmacy" excludes it.
    expect(searchDocuments(docs, 'blood pharmacy'), isEmpty);
  });

  test('no matches yields an empty list', () {
    expect(searchDocuments(docs, 'xyzzy'), isEmpty);
  });

  test('documentMatchesQuery agrees with searchDocuments', () {
    expect(documentMatchesQuery(cbc, 'hemoglobin'), isTrue);
    expect(documentMatchesQuery(cbc, 'pharmacy'), isFalse);
    expect(documentMatchesQuery(receipt, ''), isTrue);
  });
}
