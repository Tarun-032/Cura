import 'dart:io';
import 'dart:typed_data';

import 'package:cura/features/export/pdf_exporter.dart';
import 'package:cura/features/library/document.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

CuraDocument _doc(
  String title,
  DateTime date, {
  String id = 'test',
  List<String> pages = const [],
  String? sourcePdfPath,
}) => CuraDocument(
  id: id,
  title: title,
  type: DocumentType.lab,
  date: date,
  pages: pages,
  sourcePdfPath: sourcePdfPath,
);

class _FakeSaver implements PdfBatchSaver {
  _FakeSaver({
    this.automaticDownloads = true,
    this.cancelOnCall,
    this.failOnCall,
  });

  final bool automaticDownloads;
  final int? cancelOnCall;
  final int? failOnCall;
  final List<String> names = [];
  final List<Uint8List> payloads = [];

  @override
  Future<bool> supportsAutomaticDownloads() async => automaticDownloads;

  @override
  Future<PdfSaveResult> save(
    Uint8List bytes, {
    required String fileName,
    required bool automaticDownloads,
  }) async {
    expect(automaticDownloads, this.automaticDownloads);
    final call = names.length;
    names.add(fileName);
    payloads.add(bytes);
    if (failOnCall == call) throw StateError('storage unavailable');
    if (cancelOnCall == call) return const PdfSaveResult.cancelled();
    return PdfSaveResult.saved(fileName);
  }
}

void main() {
  group('pdf file names', () {
    test('slugs the title and appends the document date', () {
      expect(
        pdfFileNameFor(_doc('Complete blood count', DateTime(2026, 7, 4))),
        'cura-complete-blood-count-2026-07-04.pdf',
      );
    });

    test('collapses punctuation and unicode runs into single dashes', () {
      expect(
        pdfFileNameFor(
          _doc('Vitamin D (25-OH)!! Test', DateTime(2025, 12, 31)),
        ),
        'cura-vitamin-d-25-oh-test-2025-12-31.pdf',
      );
    });

    test('falls back to document when nothing slugs', () {
      expect(
        pdfFileNameFor(_doc('***', DateTime(2026, 1, 2))),
        'cura-document-2026-01-02.pdf',
      );
    });

    test('caps very long titles without a trailing dash', () {
      final name = pdfFileNameFor(
        _doc('${'a' * 30} ${'b' * 30}', DateTime(2026, 1, 2)),
      );
      final slug = name.substring('cura-'.length, name.indexOf('-2026'));
      expect(slug.length, lessThanOrEqualTo(40));
      expect(slug.endsWith('-'), isFalse);
    });

    test('numbers duplicate names inside one export batch', () {
      final docs = [
        _doc('CBC', DateTime(2026, 1, 2), id: 'a'),
        _doc('CBC', DateTime(2026, 1, 2), id: 'b'),
        _doc('CBC', DateTime(2026, 1, 2), id: 'c'),
      ];

      expect(pdfFileNamesForDocuments(docs), [
        'cura-cbc-2026-01-02.pdf',
        'cura-cbc-2026-01-02-2.pdf',
        'cura-cbc-2026-01-02-3.pdf',
      ]);
    });
  });

  group('separate batch export', () {
    final docs = [
      _doc('First report', DateTime(2026, 1, 1), id: 'first'),
      _doc('Second report', DateTime(2026, 1, 2), id: 'second'),
      _doc('Third report', DateTime(2026, 1, 3), id: 'third'),
    ];

    test('builds and saves one payload per document', () async {
      final saver = _FakeSaver();
      final built = <String>[];
      final exporter = PdfExporter(
        batchSaver: saver,
        documentBuilder: (doc) async {
          built.add(doc.id);
          return Uint8List.fromList(doc.id.codeUnits);
        },
      );

      final result = await exporter.exportSeparately(docs);

      expect(built, ['first', 'second', 'third']);
      expect(saver.names, [
        'cura-first-report-2026-01-01.pdf',
        'cura-second-report-2026-01-02.pdf',
        'cura-third-report-2026-01-03.pdf',
      ]);
      expect(saver.payloads.map(String.fromCharCodes), [
        'first',
        'second',
        'third',
      ]);
      expect(result.saved, 3);
      expect(result.skipped, 0);
      expect(result.failed, 0);
      expect(result.completed, isTrue);
      expect(result.savedToDownloadsCura, isTrue);
    });

    test('skips an unreadable document and continues', () async {
      final saver = _FakeSaver();
      final exporter = PdfExporter(
        batchSaver: saver,
        documentBuilder: (doc) async {
          if (doc.id == 'second') {
            throw const PdfExportException('No readable pages');
          }
          return Uint8List.fromList(doc.id.codeUnits);
        },
      );

      final result = await exporter.exportSeparately(docs);

      expect(result.saved, 2);
      expect(result.skipped, 1);
      expect(result.failed, 0);
      expect(saver.names, hasLength(2));
    });

    test('cancelling a save dialog stops later documents', () async {
      final saver = _FakeSaver(automaticDownloads: false, cancelOnCall: 1);
      final exporter = PdfExporter(
        batchSaver: saver,
        documentBuilder: (doc) async => Uint8List.fromList(doc.id.codeUnits),
      );

      final result = await exporter.exportSeparately(docs);

      expect(result.saved, 1);
      expect(result.cancelled, isTrue);
      expect(result.savedToDownloadsCura, isFalse);
      expect(saver.names, hasLength(2));
    });

    test('a storage failure reports partial success and stops', () async {
      final saver = _FakeSaver(failOnCall: 1);
      final exporter = PdfExporter(
        batchSaver: saver,
        documentBuilder: (doc) async => Uint8List.fromList(doc.id.codeUnits),
      );

      final result = await exporter.exportSeparately(docs);

      expect(result.saved, 1);
      expect(result.failed, 1);
      expect(result.errorMessage, contains('Second report'));
      expect(saver.names, hasLength(2));
    });
  });

  group('page image prep and pdf build', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cura_pdf_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    File writeJpeg(String name, {int width = 120, int height = 80}) {
      final image = img.Image(width: width, height: height);
      img.fill(image, color: img.ColorRgb8(220, 240, 230));
      final file = File('${tmp.path}/$name');
      file.writeAsBytesSync(img.encodeJpg(image, quality: 90));
      return file;
    }

    test('keeps readable pages in order and skips missing/corrupt ones', () {
      final a = writeJpeg('a.jpg');
      final b = writeJpeg('b.jpg', width: 90);
      final corrupt = File('${tmp.path}/broken.jpg')
        ..writeAsBytesSync(Uint8List.fromList(List.filled(700 * 1024, 7)));

      final prepared = preparePageImages([
        a.path,
        '${tmp.path}/does-not-exist.jpg',
        corrupt.path,
        b.path,
      ]);

      expect(prepared, hasLength(2));
      expect(prepared[0], a.readAsBytesSync());
      expect(prepared[1], b.readAsBytesSync());
    });

    test('builds a valid PDF with one page per image', () async {
      final page = writeJpeg('page.jpg');
      final images = preparePageImages([page.path, page.path]);
      final bytes = await buildImagesPdf(images);

      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      final body = String.fromCharCodes(bytes);
      expect(RegExp(r'/Type\s*/Page\b').allMatches(body), hasLength(2));
    });

    test('each document PDF contains only that document pages', () async {
      final a = writeJpeg('a.jpg');
      final b = writeJpeg('b.jpg');
      final first = _doc(
        'First',
        DateTime(2026, 1, 1),
        id: 'first',
        pages: [a.path],
      );
      final second = _doc(
        'Second',
        DateTime(2026, 1, 2),
        id: 'second',
        pages: [a.path, b.path],
      );

      final firstPdf = String.fromCharCodes(await buildDocumentPdf(first));
      final secondPdf = String.fromCharCodes(await buildDocumentPdf(second));

      expect(RegExp(r'/Type\s*/Page\b').allMatches(firstPdf), hasLength(1));
      expect(RegExp(r'/Type\s*/Page\b').allMatches(secondPdf), hasLength(2));
    });

    test('imported document returns the original PDF byte-for-byte', () async {
      final source = File('${tmp.path}/original.pdf');
      final original = Uint8List.fromList(
        '%PDF-1.7\noriginal-payload'.codeUnits,
      );
      source.writeAsBytesSync(original);
      final imported = _doc(
        'Imported report',
        DateTime(2026, 1, 3),
        sourcePdfPath: source.path,
      );

      expect(await buildDocumentPdf(imported), original);
    });

    test('missing original PDF falls back to rendered pages', () async {
      final page = writeJpeg('fallback.jpg');
      final imported = _doc(
        'Imported report',
        DateTime(2026, 1, 3),
        pages: [page.path],
        sourcePdfPath: '${tmp.path}/missing.pdf',
      );

      final exported = await buildDocumentPdf(imported);

      expect(String.fromCharCodes(exported.take(5)), '%PDF-');
    });
  });
}
