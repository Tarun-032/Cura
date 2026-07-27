import 'package:cura/core/data/app_database.dart';
import 'package:cura/core/data/document_repository.dart';
import 'package:cura/features/library/document.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v3 database migration adds the nullable original PDF column', () async {
    final executor = NativeDatabase.memory(
      setup: (database) {
        database.execute('''
          CREATE TABLE documents (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            type TEXT NOT NULL,
            date INTEGER NOT NULL,
            extracted_text TEXT NOT NULL DEFAULT '',
            results TEXT NOT NULL DEFAULT '[]',
            results_note TEXT,
            tags TEXT NOT NULL DEFAULT '[]',
            file_path TEXT,
            file_paths TEXT
          )
        ''');
        database.execute('PRAGMA user_version = 3');
      },
    );
    final database = AppDatabase.forTesting(executor);
    addTearDown(database.close);

    final columns = await database
        .customSelect('PRAGMA table_info(documents)')
        .get();

    expect(
      columns.map((row) => row.read<String>('name')),
      contains('source_pdf_path'),
    );
  });

  test('v4 database migration adds the summary rewrite columns', () async {
    final executor = NativeDatabase.memory(
      setup: (database) {
        database.execute('''
          CREATE TABLE documents (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            type TEXT NOT NULL,
            date INTEGER NOT NULL,
            extracted_text TEXT NOT NULL DEFAULT '',
            results TEXT NOT NULL DEFAULT '[]',
            results_note TEXT,
            tags TEXT NOT NULL DEFAULT '[]',
            file_path TEXT,
            file_paths TEXT,
            source_pdf_path TEXT
          )
        ''');
        database.execute('''
          INSERT INTO documents (id, title, type, date, results_note)
          VALUES ('scan-old', 'Chest CT', 'imaging', 0, 'Impression: normal.')
        ''');
        database.execute('PRAGMA user_version = 4');
      },
    );
    final database = AppDatabase.forTesting(executor);
    addTearDown(database.close);

    final stored = (await DocumentRepository(
      database,
    ).watchDocuments().first).single;

    // An existing record keeps its summary and is never queued.
    expect(stored.resultsNote, 'Impression: normal.');
    expect(stored.summaryRewrite, isNull);
    expect(stored.summaryState, isNull);
  });

  test('v5 database migration re-queues every existing rewrite', () async {
    final executor = NativeDatabase.memory(
      setup: (database) {
        database.execute('''
          CREATE TABLE documents (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            type TEXT NOT NULL,
            date INTEGER NOT NULL,
            extracted_text TEXT NOT NULL DEFAULT '',
            results TEXT NOT NULL DEFAULT '[]',
            results_note TEXT,
            summary_rewrite TEXT,
            summary_state TEXT,
            tags TEXT NOT NULL DEFAULT '[]',
            file_path TEXT,
            file_paths TEXT,
            source_pdf_path TEXT
          )
        ''');
        database.execute('''
          INSERT INTO documents (id, title, type, date, results_note, summary_rewrite)
          VALUES ('scan-cut', 'Chest CT', 'imaging', 0,
                  'Impression: pneumonia.', 'The report would arrive in 2')
        ''');
        database.execute('''
          INSERT INTO documents (id, title, type, date, results_note)
          VALUES ('scan-plain', 'Blood work', 'lab', 0, '4 results')
        ''');
        database.execute('PRAGMA user_version = 5');
      },
    );
    final database = AppDatabase.forTesting(executor);
    addTearDown(database.close);

    final stored = {
      for (final d in await DocumentRepository(database).watchDocuments().first)
        d.id: d,
    };

    // The truncated rewrite is dropped and queued again; nothing else moves.
    expect(stored['scan-cut']!.summaryRewrite, isNull);
    expect(stored['scan-cut']!.summaryState, 'pending');
    expect(stored['scan-cut']!.resultsNote, 'Impression: pneumonia.');
    expect(stored['scan-cut']!.title, 'Chest CT');
    // A document that never had a rewrite is not queued by the migration.
    expect(stored['scan-plain']!.summaryState, isNull);
  });

  test('persists the original PDF path alongside rendered pages', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DocumentRepository(database);
    final document = CuraDocument(
      id: 'pdf-1',
      title: 'Imported lab report',
      type: DocumentType.lab,
      date: DateTime(2026, 7, 15),
      extractedText: 'Hemoglobin 14.2 g/dL',
      pages: const ['/private/imports/pdf-1/pages/page-001.jpg'],
      sourcePdfPath: '/private/imports/pdf-1/original.pdf',
    );

    await repository.add(document);
    final stored = (await repository.watchDocuments().first).single;

    expect(stored.pages, document.pages);
    expect(stored.sourcePdfPath, document.sourcePdfPath);
  });

  test('camera and legacy-shaped records keep a null PDF path', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DocumentRepository(database);

    await repository.add(
      CuraDocument(
        id: 'scan-1',
        title: 'Camera scan',
        type: DocumentType.receipt,
        date: DateTime(2026, 7, 15),
        pages: const ['/private/scans/page.jpg'],
      ),
    );

    final stored = (await repository.watchDocuments().first).single;
    expect(stored.sourcePdfPath, isNull);
  });
}
