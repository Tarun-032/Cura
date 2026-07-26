import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../security/app_lock.dart' show withoutAppLock;

const int kPdfImportPageLimit = 20;

enum PdfImportStage { preparing, rendering, reading }

class PdfImportProgress {
  const PdfImportProgress(this.stage, {this.current = 0, this.total = 0});

  final PdfImportStage stage;
  final int current;
  final int total;

  String get label => switch (stage) {
    PdfImportStage.preparing => 'Preparing PDF\u2026',
    PdfImportStage.rendering when total > 0 =>
      'Rendering page $current of $total\u2026',
    PdfImportStage.rendering => 'Rendering PDF\u2026',
    PdfImportStage.reading when total > 0 =>
      'Reading page $current of $total\u2026',
    PdfImportStage.reading => 'Reading document\u2026',
  };
}

/// A selected PDF copied into Cura's private storage, but not rendered yet.
/// Keeping this as a distinct state lets the system picker close before Cura
/// shows its non-dismissible processing dialog.
class PendingPdfImport {
  const PendingPdfImport({
    required this.sessionId,
    required this.sourcePdfPath,
    required this.pagesDirectory,
  });

  final String sessionId;
  final String sourcePdfPath;
  final String pagesDirectory;
}

class RenderedPdfImport {
  const RenderedPdfImport({
    required this.sourcePdfPath,
    required this.pagePaths,
  });

  final String sourcePdfPath;
  final List<String> pagePaths;
}

/// Selects and prepares PDFs without sending their contents off-device.
/// Android's PdfRenderer does the page rasterization; the returned JPEGs then
/// enter Cura's existing geometry-aware OCR pipeline.
class PdfImportService {
  static const _methodChannel = MethodChannel('com.cura.cura/pdf_import');
  static const _progressChannel = EventChannel(
    'com.cura.cura/pdf_import_progress',
  );

  Future<PendingPdfImport?> pickPdf() async {
    // Wrapped so the system file picker doesn't trip the app lock on return.
    final picked = await withoutAppLock(
      () => FilePicker.platform.pickFiles(
        dialogTitle: 'Import PDF',
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        allowMultiple: false,
        withData: false,
      ),
    );
    if (picked == null || picked.files.isEmpty) return null;

    final selectedPath = picked.files.single.path;
    if (selectedPath == null || selectedPath.isEmpty) {
      throw const PdfImportException('Cura could not open the selected PDF.');
    }

    final sessionId = 'pdf-${DateTime.now().microsecondsSinceEpoch}';
    final root = await _importsDirectory();
    final session = Directory(p.join(root.path, sessionId));
    final pages = Directory(p.join(session.path, 'pages'));
    try {
      await pages.create(recursive: true);
      final source = p.join(session.path, 'original.pdf');
      await File(selectedPath).copy(source);
      return PendingPdfImport(
        sessionId: sessionId,
        sourcePdfPath: source,
        pagesDirectory: pages.path,
      );
    } catch (_) {
      if (await session.exists()) await session.delete(recursive: true);
      throw const PdfImportException(
        'Cura could not copy the selected PDF into private storage.',
      );
    }
  }

  Future<RenderedPdfImport> render(
    PendingPdfImport pending, {
    void Function(PdfImportProgress progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw const PdfImportException(
        'PDF import is currently available on Android only.',
      );
    }

    onProgress?.call(const PdfImportProgress(PdfImportStage.preparing));
    StreamSubscription<dynamic>? subscription;
    if (onProgress != null) {
      subscription = _progressChannel.receiveBroadcastStream().listen((event) {
        if (event is! Map || event['sessionId'] != pending.sessionId) return;
        final current = event['current'];
        final total = event['total'];
        onProgress(
          PdfImportProgress(
            PdfImportStage.rendering,
            current: current is int ? current : 0,
            total: total is int ? total : 0,
          ),
        );
      });
    }

    try {
      final paths = await _methodChannel.invokeListMethod<String>('renderPdf', {
        'sessionId': pending.sessionId,
        'inputPath': pending.sourcePdfPath,
        'outputDirectory': pending.pagesDirectory,
        'maxPages': kPdfImportPageLimit,
        'maxLongEdge': 2400,
        'jpegQuality': 90,
      });
      if (paths == null || paths.isEmpty) {
        throw const PdfImportException('This PDF does not contain any pages.');
      }
      return RenderedPdfImport(
        sourcePdfPath: pending.sourcePdfPath,
        pagePaths: List.unmodifiable(paths),
      );
    } on PlatformException catch (error) {
      throw PdfImportException(_platformErrorMessage(error));
    } on MissingPluginException {
      throw const PdfImportException(
        'PDF import is unavailable in this build of Cura.',
      );
    } finally {
      await subscription?.cancel();
    }
  }

  Future<void> discardPending(PendingPdfImport pending) =>
      deleteImportedPdf(pending.sourcePdfPath);

  /// Removes one complete import session (original PDF plus rendered pages).
  /// The directory guard ensures an unexpected database path can never cause a
  /// recursive delete outside Cura's own private imports directory.
  Future<void> deleteImportedPdf(String? sourcePdfPath) async {
    if (sourcePdfPath == null || sourcePdfPath.isEmpty) return;
    final source = File(sourcePdfPath);
    final session = source.parent;
    final imports = await _importsDirectory();
    if (p.equals(p.normalize(session.parent.path), p.normalize(imports.path)) &&
        await session.exists()) {
      await session.delete(recursive: true);
    }
  }

  Future<void> deleteAllImports() async {
    final imports = await _importsDirectory();
    if (await imports.exists()) await imports.delete(recursive: true);
  }

  Future<Directory> _importsDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'imports'));
  }

  String _platformErrorMessage(PlatformException error) => switch (error.code) {
    'too_many_pages' =>
      'This PDF has more than $kPdfImportPageLimit pages. '
          'Cura supports up to $kPdfImportPageLimit pages per document.',
    'protected_pdf' => 'Password-protected PDFs aren\'t supported yet.',
    'empty_pdf' => 'This PDF does not contain any pages.',
    'invalid_pdf' => 'This PDF is damaged or uses a format Cura cannot read.',
    _ => error.message ?? 'Cura could not read this PDF.',
  };
}

class PdfImportException implements Exception {
  const PdfImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

final pdfImportServiceProvider = Provider<PdfImportService>(
  (ref) => PdfImportService(),
);
