import 'dart:convert';

import 'package:drift/drift.dart';

import '../../features/library/document.dart';
import 'app_database.dart';

/// Sits between the Drift database and the UI. The screens only ever see
/// [CuraDocument]; this class maps to/from the generated Drift row so Drift
/// never leaks into the feature layer.
class DocumentRepository {
  DocumentRepository(this._db);

  final AppDatabase _db;

  /// A live, ordered (newest first) stream of all saved documents. Emits a new
  /// list whenever anything changes — this is what drives the UI.
  Stream<List<CuraDocument>> watchDocuments() {
    final query = _db.select(_db.documents)
      ..orderBy([(d) => OrderingTerm.desc(d.date)]);
    return query.watch().map((rows) => rows.map(_toModel).toList());
  }

  /// Insert (or overwrite, if the id already exists) a document.
  Future<void> add(CuraDocument doc) =>
      _db.into(_db.documents).insertOnConflictUpdate(_toRow(doc));

  /// Persist edits to an existing document (same upsert semantics).
  Future<void> update(CuraDocument doc) => add(doc);

  /// Remove a single document by id.
  Future<void> delete(String id) =>
      (_db.delete(_db.documents)..where((d) => d.id.equals(id))).go();

  /// Wipe every document from the device.
  Future<void> deleteAll() => _db.delete(_db.documents).go();

  CuraDocument _toModel(Document row) => CuraDocument(
    id: row.id,
    title: row.title,
    type: row.type,
    date: row.date,
    extractedText: row.extractedText,
    results: row.results,
    resultsNote: row.resultsNote,
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
    tags: Value(doc.tags),
    // Mirror the first page into the legacy column so any single-image
    // reader (and older code paths) still resolves an image.
    filePath: Value(doc.primaryImage),
    filePaths: Value(jsonEncode(doc.pages)),
    sourcePdfPath: Value(doc.sourcePdfPath),
  );

  /// Prefer the JSON page list; fall back to the legacy single [filePath] for
  /// rows written before v3.
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
