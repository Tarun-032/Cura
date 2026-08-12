import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../features/library/document.dart';

part 'app_database.g.dart';

/// DocumentType ↔ name string (stable if enum reordered).
class _DocumentTypeConverter extends TypeConverter<DocumentType, String> {
  const _DocumentTypeConverter();

  @override
  DocumentType fromSql(String fromDb) => DocumentType.values.byName(fromDb);

  @override
  String toSql(DocumentType value) => value.name;
}

/// Results as JSON in-row.
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
        labFlag: map['labFlag'] as String?,
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
            if (r.labFlag != null) 'labFlag': r.labFlag,
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

/// Tags as JSON array.
class _TagsConverter extends TypeConverter<List<String>, String> {
  const _TagsConverter();

  @override
  List<String> fromSql(String fromDb) =>
      (jsonDecode(fromDb) as List<dynamic>).cast<String>();

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

/// One document row ([CuraDocument] shape).
class Documents extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get type => text().map(const _DocumentTypeConverter())();
  DateTimeColumn get date => dateTime()();
  TextColumn get extractedText => text().withDefault(const Constant(''))();
  TextColumn get results =>
      text().map(const _ResultsConverter()).withDefault(const Constant('[]'))();
  TextColumn get resultsNote => text().nullable()();
  // Readable rewrite of resultsNote (Ask keeps verbatim).
  TextColumn get summaryRewrite => text().nullable()();
  // pending | retry | null.
  TextColumn get summaryState => text().nullable()();
  TextColumn get tags =>
      text().map(const _TagsConverter()).withDefault(const Constant('[]'))();
  // Legacy single-image path.
  TextColumn get filePath => text().nullable()();
  // Page paths JSON; null → filePath.
  TextColumn get filePaths => text().nullable()();
  // Imported PDF source; null for camera scans.
  TextColumn get sourcePdfPath => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One Ask session.
@DataClassName('ChatSessionRow')
class ChatSessions extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One chat message (`sourceDocId` = cited doc, or null).
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

/// One dose time (`id` = notification id).
@DataClassName('ReminderRow')
class Reminders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get documentId => text()();
  TextColumn get medicineLabel => text()();

  /// Minutes since midnight.
  IntColumn get minuteOfDay => integer()();
  DateTimeColumn get startDate => dateTime()();

  /// Last day, or null if open-ended.
  DateTimeColumn get endDate => dateTime().nullable()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// Last taken day.
  DateTimeColumn get lastTakenDay => dateTime().nullable()();
}

/// On-device SQLite DB.
@DriftDatabase(tables: [Documents, ChatSessions, ChatMessages, Reminders])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'cura'));
  AppDatabase.forTesting(super.executor);

  /// Same DB file for the notification isolate.
  AppDatabase.background(File file) : super(NativeDatabase(file));

  @override
  int get schemaVersion => 8;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 → v2: chat tables.
      if (from < 2) {
        await m.createTable(chatSessions);
        await m.createTable(chatMessages);
      }
      // v2 → v3: multi-page filePaths.
      if (from < 3) {
        await m.addColumn(documents, documents.filePaths);
      }
      // v3 → v4: sourcePdfPath.
      if (from < 4) {
        await m.addColumn(documents, documents.sourcePdfPath);
      }
      // v4 → v5: summary rewrite columns.
      if (from < 5) {
        await m.addColumn(documents, documents.summaryRewrite);
        await m.addColumn(documents, documents.summaryState);
      }
      // v5 → v6: clear truncated rewrites for redo.
      if (from < 6) {
        await customStatement(
          "UPDATE documents SET summary_rewrite = NULL, summary_state = 'pending' "
          'WHERE summary_rewrite IS NOT NULL',
        );
      }
      // v6 → v7: reminders table.
      // Later Reminder columns need `else if` (createTable = current schema).
      if (from < 7) {
        await m.createTable(reminders);
      } else if (from < 8) {
        // v7 → v8: lastTakenDay.
        await m.addColumn(reminders, reminders.lastTakenDay);
      }
    },
  );
}

/// Drift DB filename under app documents.
const kDatabaseFileName = 'cura.sqlite';
