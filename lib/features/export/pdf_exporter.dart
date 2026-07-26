import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../library/document.dart';
import '../security/app_lock.dart' show withoutAppLock;

/// How a single-file export attempt ended. Cancelling the save dialog is a
/// normal outcome, so callers can stay silent instead of showing an error.
enum ExportOutcome { saved, cancelled }

enum PdfSaveStatus { saved, cancelled }

class PdfSaveResult {
  const PdfSaveResult.saved(this.fileName) : status = PdfSaveStatus.saved;
  const PdfSaveResult.cancelled()
    : status = PdfSaveStatus.cancelled,
      fileName = null;

  final PdfSaveStatus status;
  final String? fileName;
}

/// Result of Settings' multi-record export. A batch can partially succeed when
/// one record has lost/corrupt page images, the user cancels an older Android
/// save dialog, or storage fails after earlier PDFs were already written.
class BatchPdfExportResult {
  const BatchPdfExportResult({
    required this.saved,
    required this.skipped,
    required this.failed,
    required this.cancelled,
    required this.savedToDownloadsCura,
    this.errorMessage,
  });

  final int saved;
  final int skipped;
  final int failed;
  final bool cancelled;
  final bool savedToDownloadsCura;
  final String? errorMessage;

  bool get completed => !cancelled && errorMessage == null && failed == 0;
}

typedef DocumentPdfBuilder = Future<Uint8List> Function(CuraDocument document);

/// Destination seam kept separate from PDF generation so batch cancellation,
/// partial success, and naming can be tested without opening a system picker.
abstract class PdfBatchSaver {
  Future<bool> supportsAutomaticDownloads();

  Future<PdfSaveResult> save(
    Uint8List bytes, {
    required String fileName,
    required bool automaticDownloads,
  });
}

/// Builds PDFs from the documents' original scanned page images. Everything is
/// pure Dart and on-device; only the destination hand-off crosses to Android.
class PdfExporter {
  PdfExporter({PdfBatchSaver? batchSaver, DocumentPdfBuilder? documentBuilder})
    : _batchSaver = batchSaver ?? _PlatformPdfBatchSaver(),
      _documentBuilder = documentBuilder ?? buildDocumentPdf;

  final PdfBatchSaver _batchSaver;
  final DocumentPdfBuilder _documentBuilder;

  /// Generates and saves one PDF through the system save-file dialog. This is
  /// the detail-screen behavior and intentionally remains user-directed.
  Future<ExportOutcome> export(
    List<CuraDocument> docs, {
    required String fileName,
    void Function(int done, int total)? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    if (docs.length == 1) {
      onProgress?.call(0, 1);
      final bytes = await _documentBuilder(docs.single);
      onProgress?.call(1, 1);
      // Wrapped so the system save dialog doesn't trip the app lock on return.
      final saved = await withoutAppLock(
        () => FilePicker.platform.saveFile(
          dialogTitle: 'Save PDF',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['pdf'],
          bytes: bytes,
        ),
      );
      debugPrint(
        '[Cura.export] save ${saved == null ? 'cancelled' : 'done'} '
        'bytes=${bytes.length} ms=${sw.elapsedMilliseconds}',
      );
      return saved == null ? ExportOutcome.cancelled : ExportOutcome.saved;
    }

    var pageCount = 0;
    var skipped = 0;
    final imagesPerDoc = <List<Uint8List>>[];
    for (var i = 0; i < docs.length; i++) {
      onProgress?.call(i, docs.length);
      final paths = docs[i].pages;
      final prepared = await Isolate.run(() => preparePageImages(paths));
      skipped += paths.length - prepared.length;
      pageCount += prepared.length;
      imagesPerDoc.add(prepared);
    }
    onProgress?.call(docs.length, docs.length);

    if (pageCount == 0) {
      throw const PdfExportException('No readable scanned pages to export.');
    }

    final images = [for (final list in imagesPerDoc) ...list];
    final bytes = await Isolate.run(() => buildImagesPdf(images));
    debugPrint(
      '[Cura.export] built pdf docs=${docs.length} pages=$pageCount '
      'skipped=$skipped bytes=${bytes.length} ms=${sw.elapsedMilliseconds}',
    );

    // Wrapped so the system save dialog doesn't trip the app lock on return.
    final saved = await withoutAppLock(
      () => FilePicker.platform.saveFile(
        dialogTitle: 'Save PDF',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        bytes: bytes,
      ),
    );
    debugPrint(
      '[Cura.export] save ${saved == null ? 'cancelled' : 'done'} '
      'ms=${sw.elapsedMilliseconds}',
    );
    return saved == null ? ExportOutcome.cancelled : ExportOutcome.saved;
  }

  /// Creates and saves one PDF per selected record, serially. Processing one
  /// record at a time bounds peak memory even when many camera scans are chosen.
  Future<BatchPdfExportResult> exportSeparately(
    List<CuraDocument> docs, {
    void Function(int done, int total, String? currentTitle)? onProgress,
  }) async {
    final automaticDownloads = await _batchSaver.supportsAutomaticDownloads();
    final fileNames = pdfFileNamesForDocuments(docs);
    var saved = 0;
    var skipped = 0;
    var failed = 0;

    for (var i = 0; i < docs.length; i++) {
      final doc = docs[i];
      onProgress?.call(i, docs.length, doc.title);

      Uint8List bytes;
      try {
        bytes = await _documentBuilder(doc);
      } on PdfExportException catch (e) {
        skipped++;
        debugPrint('[Cura.export] skipped title="${doc.title}": $e');
        continue;
      } catch (e) {
        failed++;
        debugPrint('[Cura.export] build failed title="${doc.title}": $e');
        continue;
      }

      try {
        final result = await _batchSaver.save(
          bytes,
          fileName: fileNames[i],
          automaticDownloads: automaticDownloads,
        );
        if (result.status == PdfSaveStatus.cancelled) {
          return BatchPdfExportResult(
            saved: saved,
            skipped: skipped,
            failed: failed,
            cancelled: true,
            savedToDownloadsCura: automaticDownloads,
          );
        }
        saved++;
      } catch (e) {
        failed++;
        debugPrint('[Cura.export] save failed title="${doc.title}": $e');
        return BatchPdfExportResult(
          saved: saved,
          skipped: skipped,
          failed: failed,
          cancelled: false,
          savedToDownloadsCura: automaticDownloads,
          errorMessage: 'Couldn\'t save ${doc.title}',
        );
      }
    }

    onProgress?.call(docs.length, docs.length, null);
    return BatchPdfExportResult(
      saved: saved,
      skipped: skipped,
      failed: failed,
      cancelled: false,
      savedToDownloadsCura: automaticDownloads,
    );
  }
}

class _PlatformPdfBatchSaver implements PdfBatchSaver {
  static const _channel = MethodChannel('com.cura.cura/export');

  @override
  Future<bool> supportsAutomaticDownloads() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('supportsAutomaticDownloads') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<PdfSaveResult> save(
    Uint8List bytes, {
    required String fileName,
    required bool automaticDownloads,
  }) async {
    if (automaticDownloads) {
      final savedName = await _channel.invokeMethod<String>(
        'savePdfToDownloads',
        {'fileName': fileName, 'bytes': bytes},
      );
      if (savedName == null || savedName.isEmpty) {
        throw const PdfExportException('Android did not return a saved file.');
      }
      return PdfSaveResult.saved(savedName);
    }

    // Wrapped so the system save dialog doesn't trip the app lock on return.
    final saved = await withoutAppLock(
      () => FilePicker.platform.saveFile(
        dialogTitle: 'Save PDF',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        bytes: bytes,
      ),
    );
    return saved == null
        ? const PdfSaveResult.cancelled()
        : PdfSaveResult.saved(fileName);
  }
}

/// Returns an imported record's untouched original PDF whenever it is still
/// readable. Camera records (and imports whose original was externally lost)
/// fall back to rebuilding from Cura's private page images.
Future<Uint8List> buildDocumentPdf(CuraDocument document) async {
  final sw = Stopwatch()..start();
  final sourcePdfPath = document.sourcePdfPath;
  if (sourcePdfPath != null && sourcePdfPath.isNotEmpty) {
    final original = await Isolate.run(() => readOriginalPdf(sourcePdfPath));
    if (original != null) {
      debugPrint(
        '[Cura.export] copied original pdf title="${document.title}" '
        'bytes=${original.length} ms=${sw.elapsedMilliseconds}',
      );
      return original;
    }
  }

  final images = await Isolate.run(() => preparePageImages(document.pages));
  if (images.isEmpty) {
    throw const PdfExportException('No readable scanned pages to export.');
  }
  final bytes = await Isolate.run(() => buildImagesPdf(images));
  debugPrint(
    '[Cura.export] built separate pdf title="${document.title}" '
    'pages=${images.length} skipped=${document.pages.length - images.length} '
    'bytes=${bytes.length} ms=${sw.elapsedMilliseconds}',
  );
  return bytes;
}

/// Reads a source PDF only when it still has a PDF header. Returning null keeps
/// export resilient: Cura can rebuild from rendered pages if private storage was
/// partially restored or damaged.
Uint8List? readOriginalPdf(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
      return null;
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Reads each page image and re-encodes big camera JPEGs down to <=1600px on
/// the long side. Missing or undecodable files are skipped so one lost page
/// cannot prevent the rest of a record from being exported.
List<Uint8List> preparePageImages(List<String> paths) {
  const maxEdge = 1600;
  const passThroughBytes = 600 * 1024;
  final out = <Uint8List>[];
  for (final path in paths) {
    try {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      if (bytes.length <= passThroughBytes) {
        out.add(bytes);
        continue;
      }
      final decoded = img.decodeImage(bytes);
      if (decoded == null) continue;
      final long = decoded.width > decoded.height
          ? decoded.width
          : decoded.height;
      final resized = long <= maxEdge
          ? decoded
          : img.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? maxEdge : null,
              height: decoded.height > decoded.width ? maxEdge : null,
            );
      out.add(Uint8List.fromList(img.encodeJpg(resized, quality: 80)));
    } catch (_) {
      // Skip this page; a partial record export beats no export.
    }
  }
  return out;
}

/// Lays out one image per A4 page, scaled to fit with its aspect preserved.
Future<Uint8List> buildImagesPdf(List<Uint8List> images) {
  final doc = pw.Document();
  for (final bytes in images) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(12),
        build: (_) => pw.Center(
          child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
        ),
      ),
    );
  }
  return doc.save();
}

/// `cura-<title-slug>-<yyyy-mm-dd>.pdf` for a single document's export.
String pdfFileNameFor(CuraDocument doc) =>
    'cura-${_slug(doc.title)}-${_ymd(doc.date)}.pdf';

/// Allocates stable, distinct names inside one batch. The Android saver also
/// checks Downloads/Cura itself, covering files left by earlier export runs.
List<String> pdfFileNamesForDocuments(Iterable<CuraDocument> documents) {
  final used = <String>{};
  final names = <String>[];
  for (final doc in documents) {
    final base = pdfFileNameFor(doc);
    var candidate = base;
    var suffix = 2;
    while (!used.add(candidate.toLowerCase())) {
      candidate = '${base.substring(0, base.length - 4)}-${suffix++}.pdf';
    }
    names.add(candidate);
  }
  return names;
}

String _slug(String title) {
  var s = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  s = s.replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 40) s = s.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  return s.isEmpty ? 'document' : s;
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class PdfExportException implements Exception {
  const PdfExportException(this.message);
  final String message;
  @override
  String toString() => message;
}
