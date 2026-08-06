import 'dart:convert';

import 'package:drift/drift.dart';

import '../../features/library/document.dart';
import 'app_database.dart';

/// Maps Drift rows to [CuraDocument].
class DocumentRepository {
  DocumentRepository(this._db);

  final AppDatabase _db;

  /// Watch saved documents, newest first.
  Stream<List<CuraDocument>> watchDocuments() {
    final query = _db.select(_db.documents)
      ..orderBy([(d) => OrderingTerm.desc(d.date)]);
    return query.watch().map((rows) => rows.map(_toModel).toList());
  }

  /// Insert or update a document.
  Future<void> add(CuraDocument doc) =>
      _db.into(_db.documents).insertOnConflictUpdate(_toRow(doc));

  /// Update a document.
  Future<void> update(CuraDocument doc) => add(doc);

  /// Delete one document.
  Future<void> delete(String id) =>
      (_db.delete(_db.documents)..where((d) => d.id.equals(id))).go();

  /// Delete every document.
  Future<void> deleteAll() => _db.delete(_db.documents).go();

  /// Oldest pending summary rewrite.
  Future<CuraDocument?> nextPendingSummary({
    Set<String> excluding = const {},
  }) async {
    final query = _db.select(_db.documents)
      ..where(
        (d) =>
            d.summaryState.isIn(const ['pending', 'retry']) &
            d.id.isNotIn(excluding),
      )
      ..orderBy([(d) => OrderingTerm.asc(d.id)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  /// Documents with a summary but no rewrite.
  Future<List<CuraDocument>> summaryRewriteCandidates() async {
    final query = _db.select(_db.documents)
      ..where(
        (d) =>
            d.summaryState.isNull() &
            d.summaryRewrite.isNull() &
            d.resultsNote.isNotNull(),
      );
    return (await query.get()).map(_toModel).toList();
  }

  /// Mark documents as pending rewrite.
  Future<void> queuePendingSummaries(List<String> ids) async {
    if (ids.isEmpty) return;
    await (_db.update(_db.documents)..where((d) => d.id.isIn(ids))).write(
      // Literal state value.
      const DocumentsCompanion(summaryState: Value('pending')),
    );
  }

  /// Save one rewrite result.
  Future<void> setSummaryRewrite(
    String id, {
    String? text,
    String? state,
  }) async {
    await (_db.update(_db.documents)..where((d) => d.id.equals(id))).write(
      DocumentsCompanion(
        summaryRewrite: Value(text),
        summaryState: Value(state),
      ),
    );
  }

  CuraDocument _toModel(Document row) => CuraDocument(
    id: row.id,
    title: row.title,
    type: row.type,
    date: row.date,
    extractedText: row.extractedText,
    results: row.results,
    resultsNote: row.resultsNote,
    summaryRewrite: row.summaryRewrite,
    summaryState: row.summaryState,
    tags: row.tags,
    pages: _pagesFromRow(row),
    sourcePdfPath: row.sourcePdfPath,
  );

  DocumentsCompanion _toRow(CuraDocument doc) => DocumentsCompanion(
    id: Value(doc.id),
    title: Value(doc.title),
    type: Value(doc.type),
    date: Value(doc.date),
    extractedText: Value(doc.extractedText),
    results: Value(doc.results),
    resultsNote: Value(doc.resultsNote),
    summaryRewrite: Value(doc.summaryRewrite),
    summaryState: Value(doc.summaryState),
    tags: Value(doc.tags),
    // Mirror the first page into the legacy column so any single-image
    // reader (and older code paths) still resolves an image.
    filePath: Value(doc.primaryImage),
    filePaths: Value(jsonEncode(doc.pages)),
    sourcePdfPath: Value(doc.sourcePdfPath),
  );

  /// Read pages from JSON, then legacy path.
  List<String> _pagesFromRow(Document row) {
    final raw = row.filePaths;
    if (raw != null && raw.isNotEmpty) {
      final list = (jsonDecode(raw) as List<dynamic>).cast<String>();
      if (list.isNotEmpty) return list;
    }
    final legacy = row.filePath;
    return legacy == null ? const [] : [legacy];
  }
}
