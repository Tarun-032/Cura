import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../features/library/document.dart';

part 'app_database.g.dart';

/// Converts the [DocumentType] enum to/from its stable string name for storage.
/// Using the name (not the index) keeps rows valid if the enum is reordered.
class _DocumentTypeConverter extends TypeConverter<DocumentType, String> {
  const _DocumentTypeConverter();

  @override
  DocumentType fromSql(String fromDb) => DocumentType.values.byName(fromDb);

  @override
  String toSql(DocumentType value) => value.name;
}

/// Stores the structured label→value results as a JSON array of [label, value]
/// pairs, in-row rather than in a child table.
class _ResultsConverter extends TypeConverter<List<DocumentResult>, String> {
  const _ResultsConverter();

  @override
  List<DocumentResult> fromSql(String fromDb) {
    final list = jsonDecode(fromDb) as List<dynamic>;
    return list.map((e) {
      final map = e as Map<String, dynamic>;
      final legacy = _splitLegacyRangeUnit(map['range'] as String?);
      return DocumentResult(
        map['label'] as String,
        map['value'] as String,
        unit: map['unit'] as String? ?? legacy.unit,
        range: legacy.range,
      );
    }).toList();
  }

  @override
  String toSql(List<DocumentResult> value) => jsonEncode(
    value
        .map(
          (r) => {
            'label': r.label,
            'value': r.value,
            if (r.unit != null) 'unit': r.unit,
            if (r.range != null) 'range': r.range,
          },
        )
        .toList(),
  );
}

({String? range, String? unit}) _splitLegacyRangeUnit(String? raw) {
  if (raw == null || raw.trim().isEmpty) return (range: raw, unit: null);
  final text = raw.trim();
  final nums = RegExp(r'\d+(?:\.\d+)?').allMatches(text).toList();
  if (nums.isEmpty) return (range: text, unit: null);
  final suffix = text.substring(nums.last.end).trim();
  if (suffix.isEmpty ||
      !RegExp(
        r'^(?:[%A-Za-zµ]+(?:[/\.^][%A-Za-zµ0-9]+)*)$',
      ).hasMatch(suffix.replaceAll(' ', ''))) {
    return (range: text, unit: null);
  }
  return (range: text.substring(0, nums.last.end).trim(), unit: suffix);
}

/// Stores the free-form tag list as a JSON string array.
class _TagsConverter extends TypeConverter<List<String>, String> {
  const _TagsConverter();

  @override
  List<String> fromSql(String fromDb) =>
      (jsonDecode(fromDb) as List<dynamic>).cast<String>();

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

/// One row per saved document. Mirrors [CuraDocument]; `results` and `tags` are
/// JSON-encoded text columns so everything lives in a single table.
class Documents extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get type => text().map(const _DocumentTypeConverter())();
  DateTimeColumn get date => dateTime()();
  TextColumn get extractedText => text().withDefault(const Constant(''))();
  TextColumn get results =>
      text().map(const _ResultsConverter()).withDefault(const Constant('[]'))();
  TextColumn get resultsNote => text().nullable()();
  TextColumn get tags =>
      text().map(const _TagsConverter()).withDefault(const Constant('[]'))();
  // Legacy single-image path (v1/v2 rows). New scans write [filePaths] instead;
  // kept so existing rows still resolve their one image.
  TextColumn get filePath => text().nullable()();
  // Ordered page-image paths as a JSON string array — a record can span several
  // scanned pages. Null on legacy rows (fall back to [filePath]).
  TextColumn get filePaths => text().nullable()();
  // Untouched source for records imported from PDF. Null for camera scans and
  // legacy rows; page JPEGs remain in [filePaths] for OCR and previews.
  TextColumn get sourcePdfPath => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One saved Ask conversation. Title is derived from its first question.
@DataClassName('ChatSessionRow')
class ChatSessions extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One message in a chat session. `sourceDocId` is the id of the document the
/// answer cited (resolved back to a [CuraDocument] at render time), or null.
@DataClassName('ChatMessageRow')
class ChatMessages extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get role => text()(); // 'user' | 'assistant'
  TextColumn get content => text()();
  TextColumn get sourceDocId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The app's on-device SQLite database. Opened lazily in the app's private
/// sandbox by [driftDatabase] — nothing leaves the device.
@DriftDatabase(tables: [Documents, ChatSessions, ChatMessages])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'cura'));
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 → v2: add chat persistence. Existing Documents are untouched.
      if (from < 2) {
        await m.createTable(chatSessions);
        await m.createTable(chatMessages);
      }
      // v2 → v3: multi-page records. Add the JSON page-list column; existing
      // rows keep their single filePath and read it as a one-page fallback.
      if (from < 3) {
        await m.addColumn(documents, documents.filePaths);
      }
      // v3 -> v4: retain the original PDF for imported records so exporting
      // can preserve its searchable text, vectors, and native page sizes.
      if (from < 4) {
        await m.addColumn(documents, documents.sourcePdfPath);
      }
    },
  );
}
