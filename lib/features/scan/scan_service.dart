import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/remote/pii_redactor.dart' show deleteNameRuns;
import '../ai/retrieval.dart' show kMonthNames;
import '../library/document.dart';
import '../security/app_lock.dart' show withoutAppLock;
import 'prescription_parser.dart';
import 'qualitative_parser.dart';
import 'receipt_parser.dart';
import 'table_parser.dart';

/// A captured scan.
class ScanResult {
  const ScanResult(
    this.imagePaths,
    this.text, {
    this.results = const [],
    this.tableEvidence = const TableRepairEvidence([]),
    this.sourcePdfPath,
  });

  final List<String> imagePaths;
  final String text;
  final List<DocumentResult> results;
  final TableRepairEvidence tableEvidence;
  final String? sourcePdfPath;
}

/// One OCR pass result.
class DocumentReadout {
  const DocumentReadout(
    this.text,
    this.results, {
    this.tableEvidence = const TableRepairEvidence([]),
  });

  final String text;
  final List<DocumentResult> results;
  final TableRepairEvidence tableEvidence;
}

class _OcrPass {
  const _OcrPass(this.layout, this.lines, this.geometry, this.parsed);
  final String layout;
  final List<OcrLine> lines;
  final OcrGeometryPage geometry;
  final TableParseResult parsed;
}

/// Scan and OCR service.
class ScanService {
  /// Scan pages and save them.
  Future<List<String>> captureDocument() async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg},
        mode: ScannerMode.full,
        // ML Kit needs pageLimit >= 1.
        pageLimit: 20,
        isGalleryImport: true,
      ),
    );
    try {
      // Keep the app lock off during scan.
      final result = await withoutAppLock(scanner.scanDocument);
      final images = result.images;
      if (images == null || images.isEmpty) return const [];
      return [for (final img in images) await _persistImage(img)];
    } catch (e) {
      // Log scan failures.
      debugPrint('[Cura.scan] scanDocument failed: $e');
      return const [];
    } finally {
      await scanner.close();
    }
  }

  /// Read one page.
  Future<DocumentReadout> recognize(String imagePath) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final temporaryPaths = <String>[];
    try {
      final first = await _recognizePass(recognizer, imagePath);
      // Bills use a separate parser.
      if (looksLikeBill(first.layout)) {
        final rows = parseReceiptBreakdown(
          first.lines,
          geometry: first.geometry,
          pageText: first.layout,
        );
        debugPrint('[Cura.scan] bill page rows=${rows.length}');
        return DocumentReadout(first.layout, rows);
      }
      final passes = <_OcrPass>[first];
      final firstEvidence = first.parsed.evidence.withPass(1);
      var results = repairIncompleteResultsFromGeometry(
        first.parsed.results,
        firstEvidence,
      );
      // Retry unresolved values.
      results = await _recoverIncompleteValuesFromCrops(
        recognizer,
        imagePath,
        results,
        firstEvidence,
      );

      // Escalate only when needed.
      String? enhancedPath;
      if (_needsAnotherOcrPass(passes, results)) {
        enhancedPath = await _createEnhancedOcrCopy(imagePath);
        if (enhancedPath != null) {
          temporaryPaths.add(enhancedPath);
          passes.add(await _recognizePass(recognizer, enhancedPath));
          results = repairIncompleteResultsFromGeometry(
            _mergeOcrPassResults(passes),
            _mergePassEvidence(passes),
          );
        }
      }
      var evidence = _mergePassEvidence(passes);
      debugPrint(
        '[Cura.scan] accuracyPasses=${passes.length} rows='
        '${passes.map((pass) => pass.parsed.results.length).join(',')}',
      );
      final ocrLines = first.lines;
      final layout = first.layout;
      // Use qualitative parsing if needed.
      final parsed = first.parsed;
      debugPrint(
        '[Cura.scan] table labels=${parsed.stats.labels} '
        'values=${parsed.stats.values} ranges=${parsed.stats.ranges} '
        'units=${parsed.stats.units} matched=${parsed.stats.matched} '
        'incomplete=${parsed.stats.incomplete}',
      );
      if (results.isEmpty) {
        results = parseQualitativeResults(
          ocrLines,
          textLines: layout.split('\n'),
        );
      }
      // Reconcile only on mismatches.
      final requiresReconciliation = _needsTableReconciliation(results);
      evidence = evidence.withReconciliationRequired(requiresReconciliation);
      return DocumentReadout(layout, results, tableEvidence: evidence);
    } finally {
      for (final path in temporaryPaths) {
        try {
          await File(path).delete();
        } catch (_) {
          // Best-effort cleanup.
        }
      }
      await recognizer.close();
    }
  }

  TableRepairEvidence _mergePassEvidence(List<_OcrPass> passes) {
    var evidence = const TableRepairEvidence([]);
    for (var i = 0; i < passes.length; i++) {
      evidence = evidence.merge(passes[i].parsed.evidence.withPass(i + 1));
    }
    return evidence;
  }

  bool _needsAnotherOcrPass(
    List<_OcrPass> passes,
    List<DocumentResult> merged,
  ) {
    if (merged.any((result) => result.needsReview)) return true;
    if (merged.isEmpty) {
      return passes.any(
        (pass) => pass.parsed.quality.hasTable || pass.parsed.stats.values >= 2,
      );
    }
    return false;
  }

  bool _needsTableReconciliation(List<DocumentResult> merged) {
    if (merged.any((result) => result.needsReview)) return true;
    return false;
  }

  Future<List<DocumentResult>> _recoverIncompleteValuesFromCrops(
    TextRecognizer recognizer,
    String imagePath,
    List<DocumentResult> results,
    TableRepairEvidence evidence,
  ) async {
    final unresolved = <int>[
      for (var i = 0; i < results.length; i++)
        if (results[i].needsReview) i,
    ];
    if (unresolved.isEmpty || evidence.cells.isEmpty) return results;

    String key(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final labels = evidence.cells
        .where(
          (cell) =>
              cell.pass == 1 &&
              cell.column == TableCellColumn.label &&
              cell.right > cell.left &&
              cell.bottom > cell.top,
        )
        .toList();
    final valueCells = evidence.cells
        .where(
          (cell) =>
              cell.pass == 1 &&
              cell.column == TableCellColumn.value &&
              cell.right > cell.left,
        )
        .toList();
    if (labels.isEmpty || valueCells.length < 3) return results;

    double median(Iterable<double> source) {
      final values = source.toList()..sort();
      return values[values.length ~/ 2];
    }

    final valueLeft = median(valueCells.map((cell) => cell.left));
    final lineHeight = median(
      labels
          .map((cell) => cell.bottom - cell.top)
          .where((height) => height > 0),
    );
    final laterColumns = evidence.cells
        .where(
          (cell) =>
              cell.pass == 1 &&
              (cell.column == TableCellColumn.unit ||
                  cell.column == TableCellColumn.range) &&
              cell.left > valueLeft,
        )
        .map((cell) => cell.left)
        .toList();
    if (laterColumns.isEmpty) return results;
    final nextColumnLeft = median(laterColumns);

    final targets = <({int resultIndex, TableGridCell label})>[];
    for (final resultIndex in unresolved) {
      final resultKey = key(results[resultIndex].label);
      var candidates = labels
          .where((cell) => key(cell.text) == resultKey)
          .toList();
      candidates = candidates.length == 1
          ? candidates
          : labels
                .where((cell) => _similarLabelKeys(key(cell.text), resultKey))
                .toList();
      if (candidates.length == 1) {
        targets.add((resultIndex: resultIndex, label: candidates.single));
      }
    }
    if (targets.isEmpty) return results;

    String? contactPath;
    ui.Codec? codec;
    ui.Image? source;
    ui.Image? contact;
    try {
      final bytes = await File(imagePath).readAsBytes();
      codec = await ui.instantiateImageCodec(bytes);
      source = (await codec.getNextFrame()).image;

      final cropLeft = (valueLeft - lineHeight * 1.4)
          .clamp(0.0, source.width.toDouble() - 1)
          .toDouble();
      final cropRight = ((valueLeft + nextColumnLeft) / 2)
          .clamp(cropLeft + 8, source.width.toDouble())
          .toDouble();
      const scale = 4.0;
      const padding = 18.0;
      final cropHeight = lineHeight * 1.8;
      final tileHeight = cropHeight * scale + padding * 2;
      final outputWidth = ((cropRight - cropLeft) * scale + padding * 2).ceil();
      final outputHeight = (tileHeight * targets.length).ceil();
      if (outputWidth < 32 || outputHeight < 32) return results;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
      const contrast = 1.18;
      const offset = 128 * (1 - contrast);
      final paint = ui.Paint()
        ..filterQuality = ui.FilterQuality.high
        ..colorFilter = const ui.ColorFilter.matrix([
          0.35282,
          0.69204,
          0.13412,
          0,
          offset,
          0.35282,
          0.69204,
          0.13412,
          0,
          offset,
          0.35282,
          0.69204,
          0.13412,
          0,
          offset,
          0,
          0,
          0,
          1,
          0,
        ]);
      for (var i = 0; i < targets.length; i++) {
        final centerY = targets[i].label.cy;
        final top = (centerY - cropHeight / 2)
            .clamp(0.0, source.height.toDouble() - cropHeight)
            .toDouble();
        final src = ui.Rect.fromLTRB(
          cropLeft,
          top,
          cropRight,
          top + cropHeight,
        );
        final tileTop = i * tileHeight + padding;
        final dst = ui.Rect.fromLTWH(
          padding,
          tileTop,
          (cropRight - cropLeft) * scale,
          cropHeight * scale,
        );
        canvas.drawImageRect(source, src, dst, paint);
      }
      final picture = recorder.endRecording();
      contact = await picture.toImage(outputWidth, outputHeight);
      final data = await contact.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return results;
      final dir = await getTemporaryDirectory();
      contactPath = p.join(
        dir.path,
        'cura-value-cells-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await File(
        contactPath,
      ).writeAsBytes(data.buffer.asUint8List(), flush: true);

      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(contactPath),
      );
      final candidates = <int, Set<String>>{};
      void collect(String text, double centerY) {
        final tile = (centerY / tileHeight).floor();
        if (tile < 0 || tile >= targets.length) return;
        final value = normalizeObservedValueCandidate(text);
        if (value != null) {
          candidates.putIfAbsent(tile, () => <String>{}).add(value);
        }
      }

      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          collect(line.text, line.boundingBox.center.dy);
          for (final element in line.elements) {
            collect(element.text, element.boundingBox.center.dy);
          }
        }
      }

      final repaired = [...results];
      var recovered = 0;
      for (var i = 0; i < targets.length; i++) {
        final values = candidates[i] ?? const <String>{};
        if (values.length != 1) continue;
        final original = repaired[targets[i].resultIndex];
        repaired[targets[i].resultIndex] = DocumentResult(
          original.label,
          values.single,
          unit: original.unit,
          range: original.range,
        );
        recovered++;
      }
      debugPrint(
        '[Cura.scan] targetedValueRecovery attempted=${targets.length} '
        'recovered=$recovered',
      );
      return repaired;
    } catch (error) {
      debugPrint('[Cura.scan] targeted value recovery unavailable: $error');
      return results;
    } finally {
      if (contactPath != null) {
        try {
          await File(contactPath).delete();
        } catch (_) {
          // Best-effort cache cleanup only.
        }
      }
      contact?.dispose();
      source?.dispose();
      codec?.dispose();
    }
  }

  Future<_OcrPass> _recognizePass(
    TextRecognizer recognizer,
    String imagePath, {
    double yOffset = 0,
  }) async {
    final recognized = await recognizer.processImage(
      InputImage.fromFilePath(imagePath),
    );
    final geometry = _toOcrGeometry(recognized, yOffset: yOffset);
    final lines = geometry.lines;
    return _OcrPass(
      _layoutText(recognized),
      lines,
      geometry,
      parseResultsTableDetailed(lines, geometry: geometry),
    );
  }

  List<DocumentResult> _mergeOcrPassResults(List<_OcrPass> passes) {
    if (passes.isEmpty) return const [];
    final merged = [...passes.first.parsed.results];
    String key(DocumentResult row) =>
        row.label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    for (final pass in passes.skip(1)) {
      final occurrences = <String, int>{};
      for (final candidate in pass.parsed.results) {
        final candidateKey = key(candidate);
        final occurrence = occurrences.update(
          candidateKey,
          (count) => count + 1,
          ifAbsent: () => 0,
        );
        final matches = <int>[
          for (var i = 0; i < merged.length; i++)
            if (key(merged[i]) == candidateKey) i,
        ];
        var index = occurrence < matches.length ? matches[occurrence] : -1;
        // Fall back to a near match.
        if (index < 0) {
          index = merged.indexWhere(
            (row) => _similarLabelKeys(key(row), candidateKey),
          );
        }
        if (index < 0) {
          merged.add(candidate);
        } else if (merged[index].needsReview && !candidate.needsReview) {
          merged[index] = candidate;
        }
      }
    }
    return merged;
  }

  /// Compare label keys.
  static bool _similarLabelKeys(String a, String b) {
    if (a == b) return true;
    final shorter = a.length <= b.length ? a : b;
    final longer = a.length <= b.length ? b : a;
    if (shorter.length >= 4 && longer.startsWith(shorter)) return true;
    if (shorter.length < 6) return false;
    final limit = shorter.length >= 12 ? 2 : 1;
    if (longer.length - shorter.length > limit) return false;
    return _editDistanceAtMost(a, b, limit);
  }

  static bool _editDistanceAtMost(String a, String b, int limit) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      var rowBest = i;
      for (var j = 1; j <= b.length; j++) {
        final substitution =
            previous[j - 1] +
            (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1);
        final insertion = current[j - 1] + 1;
        final deletion = previous[j] + 1;
        var best = substitution < insertion ? substitution : insertion;
        if (deletion < best) best = deletion;
        current[j] = best;
        if (best < rowBest) rowBest = best;
      }
      if (rowBest > limit) return false;
      previous = current;
    }
    return previous[b.length] <= limit;
  }

  /// Create an enhanced OCR copy.
  Future<String?> _createEnhancedOcrCopy(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      // Cap decode size.
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 2000);
      final frame = await codec.getNextFrame();
      final source = frame.image;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
      const contrast = 1.28;
      const offset = 128 * (1 - contrast);
      final paint = ui.Paint()
        ..colorFilter = const ui.ColorFilter.matrix([
          0.38272,
          0.75104,
          0.14592,
          0,
          offset,
          0.38272,
          0.75104,
          0.14592,
          0,
          offset,
          0.38272,
          0.75104,
          0.14592,
          0,
          offset,
          0,
          0,
          0,
          1,
          0,
        ]);
      canvas.drawImage(source, ui.Offset.zero, paint);
      final picture = recorder.endRecording();
      final enhanced = await picture.toImage(source.width, source.height);
      final data = await enhanced.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      enhanced.dispose();
      codec.dispose();
      if (data == null) return null;
      final dir = await getTemporaryDirectory();
      final path = p.join(
        dir.path,
        'cura-ocr-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await File(path).writeAsBytes(data.buffer.asUint8List(), flush: true);
      return path;
    } catch (error) {
      debugPrint('[Cura.scan] enhanced OCR unavailable: $error');
      return null;
    }
  }

  /// Read and merge pages.
  Future<DocumentReadout> recognizePages(
    List<String> imagePaths, {
    void Function(int current, int total)? onProgress,
  }) async {
    final texts = <String>[];
    final results = <DocumentResult>[];
    final evidenceRows = <TableEvidenceRow>[];
    final evidenceCells = <TableGridCell>[];
    var requiresReconciliation = false;
    for (var pageIndex = 0; pageIndex < imagePaths.length; pageIndex++) {
      onProgress?.call(pageIndex + 1, imagePaths.length);
      final path = imagePaths[pageIndex];
      final page = await recognize(path);
      requiresReconciliation =
          requiresReconciliation || page.tableEvidence.requiresReconciliation;
      if (page.text.trim().isNotEmpty) texts.add(page.text.trim());
      for (final result in page.results) {
        final signature = _resultSignature(result);
        if (results.every(
          (existing) => _resultSignature(existing) != signature,
        )) {
          results.add(result);
        }
      }
      for (final row in page.tableEvidence.rows) {
        evidenceRows.add(
          TableEvidenceRow(
            label: row.label,
            rowText: row.rowText,
            order: evidenceRows.length,
            incomplete: row.incomplete,
          ),
        );
      }
      for (final cell in page.tableEvidence.cells) {
        evidenceCells.add(
          TableGridCell(
            id: 'pg${pageIndex + 1}_${cell.id}',
            text: cell.text,
            column: cell.column,
            rowHint: cell.rowHint,
            pass: pageIndex * 100 + cell.pass,
            granularity: cell.granularity,
            confidence: cell.confidence,
            section: cell.section,
            left: cell.left,
            top: cell.top,
            right: cell.right,
            bottom: cell.bottom,
          ),
        );
      }
    }
    return DocumentReadout(
      texts.join('\n\n'),
      results,
      tableEvidence: TableRepairEvidence(
        evidenceRows,
        cells: evidenceCells,
        requiresReconciliation: requiresReconciliation,
      ),
    );
  }

  /// Read page text.
  Future<String> recognizeText(String imagePath) async =>
      (await recognize(imagePath)).text;

  /// Build OCR geometry.
  OcrGeometryPage _toOcrGeometry(
    RecognizedText recognized, {
    double yOffset = 0,
  }) {
    final lines = <OcrLine>[];
    final elements = <OcrElementBox>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final parentLine = lines.length;
        lines.add(
          OcrLine(
            line.text,
            line.boundingBox.left,
            line.boundingBox.top + yOffset,
            line.boundingBox.right,
            line.boundingBox.bottom + yOffset,
            confidence: line.confidence,
          ),
        );
        for (final element in line.elements) {
          elements.add(
            OcrElementBox(
              element.text,
              element.boundingBox.left,
              element.boundingBox.top + yOffset,
              element.boundingBox.right,
              element.boundingBox.bottom + yOffset,
              parentLine: parentLine,
              confidence: element.confidence,
              symbols: [
                for (final symbol in element.symbols)
                  OcrSymbolBox(
                    symbol.text,
                    symbol.boundingBox.left,
                    symbol.boundingBox.top + yOffset,
                    symbol.boundingBox.right,
                    symbol.boundingBox.bottom + yOffset,
                    confidence: symbol.confidence,
                  ),
              ],
            ),
          );
        }
      }
    }
    return OcrGeometryPage(lines: lines, elements: elements);
  }

  /// Rebuild reading order text.
  String _layoutText(RecognizedText recognized) {
    final lines = [for (final block in recognized.blocks) ...block.lines];
    if (lines.isEmpty) return recognized.text;

    lines.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));

    final rows = <List<TextLine>>[];
    for (final line in lines) {
      final center = line.boundingBox.center.dy;
      if (rows.isNotEmpty) {
        final ref = rows.last.first.boundingBox;
        // Same row if vertically close.
        if ((ref.center.dy - center).abs() <= ref.height * 0.6) {
          rows.last.add(line);
          continue;
        }
      }
      rows.add([line]);
    }

    final buffer = StringBuffer();
    for (final row in rows) {
      row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
      buffer.writeln(row.map((l) => l.text).join('   '));
    }
    return buffer.toString().trim();
  }

  /// Find the page date.
  DateTime? extractDate(String text) {
    DateTime? best;
    var bestRank = _dateLabelPriority.length + 1;
    for (final line in text.split('\n')) {
      for (final re in [_numericDateRe, _monthNameDateRe]) {
        for (final m in re.allMatches(line)) {
          final parsed = re == _numericDateRe
              ? _parseNumericDate(m)
              : _parseMonthNameDate(m);
          if (parsed == null) continue;
          // Rank by the label before the date.
          final before = line.substring(0, m.start).toLowerCase();
          if (_dobRe.hasMatch(before)) continue;
          var rank = _dateLabelPriority.length; // unlabeled: last resort
          for (var i = 0; i < _dateLabelPriority.length; i++) {
            if (before.contains(_dateLabelPriority[i])) {
              rank = i;
              break;
            }
          }
          // First best date wins.
          if (rank < bestRank) {
            bestRank = rank;
            best = parsed;
          }
        }
      }
    }
    return best;
  }

  DateTime? _parseNumericDate(RegExpMatch m) {
    var day = int.parse(m.group(1)!);
    var month = int.parse(m.group(2)!);
    // Allow month-first dates.
    if (month > 12 && day <= 12) {
      final t = day;
      day = month;
      month = t;
    }
    return _validDate(day, month, int.parse(m.group(3)!));
  }

  DateTime? _parseMonthNameDate(RegExpMatch m) {
    // Match month prefixes.
    final word = m.group(2)!.toLowerCase();
    for (var i = 0; i < kMonthNames.length; i++) {
      if (kMonthNames[i].startsWith(word)) {
        return _validDate(
          int.parse(m.group(1)!),
          i + 1,
          int.parse(m.group(3)!),
        );
      }
    }
    return null;
  }

  /// Validate the date.
  DateTime? _validDate(int day, int month, int year) {
    if (year < 100) year += 2000;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    if (year < 2000 || year > DateTime.now().year + 1) return null;
    final d = DateTime(year, month, day);
    return (d.month == month && d.day == day) ? d : null;
  }

  /// First non-empty line.
  String? firstLine(String text) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// Guess a document title.
  String _repairOcrLettersForTitle(String line) =>
      line.replaceAll(RegExp(r'(?<=[A-Za-z])0(?=[A-Za-z])'), 'o');

  String detectTitle(String text) {
    // Bills first.
    if (looksLikeBill(text)) return detectReceiptTitle(text);
    final documentText = text.toLowerCase();
    // Handle common serology bundles.
    if (documentText.contains('rubella') &&
        (documentText.contains('measles') ||
            documentText.contains('rubeola')) &&
        documentText.contains('mumps') &&
        documentText.contains('igg')) {
      return 'Rubella, Measles & Mumps IgG Antibody Report';
    }
    for (final raw in text.split('\n')) {
      final line = _repairOcrLettersForTitle(raw.trim());
      if (!_headingShaped(line)) continue;
      // Check the title maps first.
      if (_titleBlocklist.hasMatch(line)) continue;
      final lower = line.toLowerCase();
      // Check procedure names first.
      for (final e in _knownProcedures.entries) {
        if (RegExp('\\b${RegExp.escape(e.key)}\\b').hasMatch(lower)) {
          return e.value;
        }
      }
      // Check panel names next.
      final alnum = line.replaceAll(RegExp('[^A-Za-z0-9]'), '').length;
      for (final e in _knownPanels.entries) {
        final key = e.key.replaceAll(RegExp('[^A-Za-z0-9]'), '').length;
        if (lower.contains(e.key) && alnum > 0 && key / alnum >= 0.4) {
          return e.value;
        }
      }
    }
    String? banner;
    for (final raw in text.split('\n')) {
      final line = _repairOcrLettersForTitle(raw.trim());
      if (line.length < 4 || line.length > 48) continue;
      // Skip headers and boilerplate.
      if (_titleNoise.hasMatch(line) ||
          _headerLineRe.hasMatch(line) ||
          _titleBlocklist.hasMatch(line)) {
        continue;
      }
      final letters = line.replaceAll(RegExp('[^A-Za-z]'), '');
      if (letters.length < 3) continue;
      final caps =
          letters.replaceAll(RegExp('[^A-Z]'), '').length / letters.length;
      if (caps <= 0.7) continue;
      if (_titleKeyword.hasMatch(line)) return _titleCase(line);
      banner ??= _departmentBanner(line); // remember a department banner
    }
    // Fall back to a department banner.
    return banner ?? 'Lab report';
  }

  /// Guess a bill title.
  String detectReceiptTitle(String text) {
    final kind = RegExp(r'\binvoice\b', caseSensitive: false).hasMatch(text)
        ? 'invoice'
        : 'bill';
    final rows = text.split('\n');
    for (final row in rows.take(8)) {
      for (final cell in row.split(RegExp(r'\s{2,}'))) {
        final line = _repairOcrLettersForTitle(cell.trim());
        if (line.length < 4 || line.length > 48) continue;
        if (_receiptHeadingNoise.hasMatch(line)) continue;
        final letters = line.replaceAll(RegExp('[^A-Za-z]'), '');
        // Mostly words.
        if (letters.length < 4 || letters.length / line.length < 0.6) continue;
        if (line.split(RegExp(r'\s+')).length > 6) continue;
        return '${_titleCase(line)} $kind';
      }
    }
    return 'Medical $kind';
  }

  /// Check for a heading-like line.
  bool _headingShaped(String line) {
    if (line.length < 4 || line.length > 60) return false;
    var words = 0, capped = 0;
    for (final w in line.split(RegExp(r'\s+'))) {
      if (!RegExp('^[A-Za-z]').hasMatch(w)) continue;
      words++;
      if (RegExp('^[A-Z]').hasMatch(w)) capped++;
    }
    return words > 0 && capped / words >= 0.7;
  }

  /// Detect the document kind.
  DocumentType detectType(String text) {
    final l = text.toLowerCase();
    // Bills first.
    if (looksLikeBill(l)) return DocumentType.receipt;
    if (l.contains('prescription') ||
        RegExp(
          r'\brx\b|\btablet\b|\bcapsule\b|\b\d+\s*mg\b.*\bdaily\b',
        ).hasMatch(l)) {
      return DocumentType.prescription;
    }
    if (l.contains('discharge')) return DocumentType.discharge;
    // Imaging before lab.
    if (_imagingTypeRe.hasMatch(l)) return DocumentType.imaging;
    return DocumentType.lab;
  }

  /// Summarize structured results.
  String? summarize(List<DocumentResult> results, {DocumentType? type}) {
    if (results.isEmpty) return null;
    if (type == DocumentType.receipt) {
      final items = results
          .where((r) => !isReceiptSummaryLabel(r.label))
          .length;
      final total = results
          .where((r) => isFinalReceiptAmountLabel(r.label))
          .lastOrNull;
      final count = '$items item${items == 1 ? '' : 's'}';
      if (total == null) return items == 0 ? null : count;
      return items == 0
          ? 'Total ${total.value}'
          : 'Total ${total.value} · $count';
    }
    // Labs: live summary at draw time, not stored.
    return null;
  }

  /// Extract narrative summary text.
  String? extractFindingsSummary(String text) {
    final captured = <String>[];
    // Track empty headings.
    final headingAt = <int>{};
    final emptyHeadingAt = <int>{};
    String? current;
    for (final raw in text.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      // Stop at administrative footers.
      if (_summaryAdministrativeFooter.hasMatch(line)) {
        current = null;
        continue;
      }
      // Skip letterheads and footers.
      if (_summaryIdentityLine.hasMatch(line)) continue;
      // Remove merged identity spans.
      line = line
          .replaceAll(_summaryIdentitySpan, ' ')
          .replaceAll(RegExp(r'\s{2,}'), ' ')
          .trim();
      if (line.isEmpty) continue;
      final m = _sectionHeaderRe.firstMatch(line);
      if (m != null) {
        final head = m.group(1)!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        // Match phrases and stems.
        final wanted = _summarySections.any(
          (s) => head == s || head.startsWith(s) || head.endsWith(s),
        );
        current = wanted ? head : null;
        if (wanted) {
          var rest = line.substring(m.end).trim();
          // Drop empty underlines.
          if (_isPunctuationOnly(rest)) rest = '';
          final label = head
              .split(' ')
              .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
              .join(' ');
          headingAt.add(captured.length);
          if (rest.isEmpty) emptyHeadingAt.add(captured.length);
          captured.add(rest.isEmpty ? '$label:' : '$label: $rest');
        }
        continue;
      }
      // Skip identity lines.
      if (current != null && _looksLikeIdentityLine(line)) continue;
      if (current != null && !_isPunctuationOnly(line)) captured.add(line);
    }
    // Drop empty headings.
    final kept = [
      for (var i = 0; i < captured.length; i++)
        if (!emptyHeadingAt.contains(i) ||
            (i + 1 < captured.length && !headingAt.contains(i + 1)))
          captured[i],
    ];
    if (kept.isEmpty) return null;
    // Keep one line per item.
    var summary = kept
        .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .join('\n')
        .trim();
    // Cap the summary length.
    const cap = 2500;
    if (summary.length > cap) {
      final cut = summary.lastIndexOf('. ', cap);
      summary = '${summary.substring(0, cut > 200 ? cut + 1 : cap).trim()}…';
    }
    return summary.isEmpty ? null : summary;
  }

  /// Parse a prescription.
  ({String? summary, List<DocumentResult> medicines}) parsePrescription(
    String text,
  ) => (
    summary: extractFindingsSummary(text),
    medicines: parsePrescriptionMedicines(text),
  );

  /// Delete one scan image.
  Future<void> deleteImage(String? path) async {
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// Delete all page images.
  Future<void> deleteImages(List<String> paths) async {
    for (final path in paths) {
      await deleteImage(path);
    }
  }

  /// Delete all scans.
  Future<void> deleteAllImages() async {
    final dir = await _scansDir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<String> _persistImage(String tempPath) async {
    final dir = await _scansDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    final dest = p.join(
      dir.path,
      'scan-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await File(tempPath).copy(dest);
    return dest;
  }

  Future<Directory> _scansDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'scans'));
  }
}

String _resultSignature(DocumentResult result) =>
    [result.label, result.value, result.unit ?? '', result.range ?? '']
        .map(
          (part) => part.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim(),
        )
        .join('|');

/// App scan service.
final scanServiceProvider = Provider<ScanService>((ref) => ScanService());

// ── Date extraction ──────────────────────────────────────────────────────────

final _numericDateRe = RegExp(r'(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})');
// Day, month word, year: "30-Aug-2024", "2 September 2003", "03-SEP-2024".
// Any trailing time ("08:37:41 PM") is naturally left behind by the year group.
final _monthNameDateRe = RegExp(
  r'(\d{1,2})[ \-.]+([A-Za-z]{3,9})[ \-.,]+(\d{2,4})',
);

/// Date label priority.
const _dateLabelPriority = [
  'reported',
  'reprinted',
  'printed',
  // Bills prefer their own date.
  'bill',
  'inv',
  'collected',
  'received',
  'registered',
  'date',
];

/// Birth dates never win.
final _dobRe = RegExp(r'\bd\.?\s*o\.?\s*b\b|birth', caseSensitive: false);

/// Imaging and radiology terms.
final _imagingTypeRe = RegExp(
  r'\bpet[\s\-/]?ct\b|\bpet\s+scan\b|\bmri\b|magnetic resonance|'
  r'\bct\s+scan\b|computed tomography|\bx[\s\-]?ray\b|'
  r'\bultrasound\b|\bultrasonography\b|\bsonography\b|\busg\b|'
  r'\bdoppler\b|\bmammogram\b|\bmammography\b|'
  r'\becg\b|\bekg\b|\belectrocardiogram\b|\beeg\b|'
  r'\bechocardiogram\b|\bechocardiography\b|\b2d\s+echo\b',
  caseSensitive: false,
);

// ── Findings summary (narrative reports) ─────────────────────────────────────

/// Section labels to summarize.
const _summarySections = [
  'indication',
  'finding',
  'impression',
  'conclusion',
  'opinion',
  'advice',
  'diagnosis',
  'procedure',
  'hospital course',
  'treatment',
  'chief complaint',
  'complaint',
  'examination',
  'o/e',
  'investigation',
  'follow',
  'review',
  'plan',
  'operative',
  'surgery',
  'condition on discharge',
  'medication',
  // Narrative lab medicine.
  'specimen',
  'macroscopic description',
  'microscopic description',
  'comment',
  // Microbiology narrative sections.
  'culture report',
  'smear findings',
  'organism',
  'sensitivity',
];

/// A summary section header.
final _sectionHeaderRe = RegExp(
  r'^(indication|findings?|impression|conclusion|opinion|advice|protocol|'
  r'technique|procedure|comments?|history|note|reference|ref|report status|'
  r'specimen|macroscopic\s+description|microscopic\s+description|method|'
  r'culture\s+report|smear\s+findings|organisms?\s+isolated|organism|'
  r'sensitivity|antibiotic\s+sensitivity|'
  r'diagnosis|final\s+diagnosis|hospital\s+course|treatment|'
  r'chief\s+complaints?|complaints?|examination|o/e|investigations?|'
  r'follow[\s-]?up|review|plan|rx|sig|'
  r'operative(?:\s+(?:findings?|notes?|procedure))?|surgery|'
  r'condition\s+on\s+discharge|medications?\s+on\s+discharge)\b\s*:?',
  caseSensitive: false,
);

/// Lines to skip in summaries.
final _summaryIdentityLine = RegExp(
  r'^(?:facility\s+address|regd\.?\s*office|registered\s+office|address|'
  r'tel|telephone|phone|mobile|mob|fax|e-?mail|website|cin|gstin|'
  r'patient\s+name|name|uhid|mrn|encounter(?:[\s/]\w+)*|visit(?:[\s/]\w+)*|'
  r'ip\s*no|op\s*no|reg(?:n|istration)?\s*no|accession|bill\s*no|'
  r'dob|d\.o\.b\.?|date\s+of\s+birth|age|sex|gender|'
  r'doctor|consultant|referred\s+by|ref(?:erring)?\s+(?:doctor|physician))'
  r'(?:\s*[:#=]|\s+-\s)'
  // Boilerplate between sections.
  r'|^(?:printed\s+(?:by|on)|page\s+\d+\s+of\s+\d+|(?:mr|mrs|ms)\.)\b'
  r'|\b(?:computer[\s-]?generated|signature\s+is\s+not\s+required)\b'
  // Contact strings and long ids.
  r'|[\w.-]+@[\w-]+\.\w{2,}|\bwww\.\w|\b\d{6,}\b',
  caseSensitive: false,
);

/// Check for identity lines.
bool _isPunctuationOnly(String line) => !RegExp('[A-Za-z0-9]').hasMatch(line);

bool _looksLikeIdentityLine(String line) {
  final t = line.trim();
  if (t.isEmpty || t.length > 90) return false;
  // Measurements mean clinical content.
  if (RegExp(r'\d').hasMatch(t) && !_facilityWord.hasMatch(t)) return false;
  if (_facilityWord.hasMatch(t)) return true;
  // A bare name run and nothing else on the line.
  final stripped = deleteNameRuns(t);
  return stripped.runs > 0 &&
      stripped.text.replaceAll(RegExp(r'[^A-Za-z]'), '').length < 3;
}

/// Facility words.
final _facilityWord = RegExp(
  r'\b(?:hospital|clinic|institute|laborator(?:y|ies)|diagnostics?|'
  r'polyclinic|nursing\s+home|medical\s+(?:centre|center|college))\b',
  caseSensitive: false,
);

/// Merged identity spans.
final _summaryIdentitySpan = RegExp(
  r'\b(?:facility\s+address|regd\.?\s*office|registered\s+office|address|'
  r'network|branch(?:es)?|centres?|centers?|'
  r'tel|telephone|phone|mobile|mob|fax|e-?mail|website|cin|gstin|'
  r'patient\s+name|name|uhid|mrn|encounter(?:\s*id)?|visit(?:\s*id)?|'
  r'ip\s*no|op\s*no|reg(?:n|istration)?\s*no|accession|bill\s*no|'
  r'dob|d\.o\.b\.?|date\s+of\s+birth|age|sex|gender|marital(?:\s+status)?|'
  r'doctor|consultant|authoriz?sed|authorized|collected\s+by|'
  r'referred\s+by|ref(?:erring)?\s+(?:doctor|physician))'
  // Stop at the next label.
  r'\s*[:#=]\s*\S+'
  r'(?:(?!\b[A-Za-z][A-Za-z.]*(?:\s+[A-Za-z][A-Za-z.]*){0,2}\s*:)[^\n]){0,90}',
  caseSensitive: false,
);

final _summaryAdministrativeFooter = RegExp(
  r'\b(?:will\s+be\s+(?:stored|discarded|destroyed)|retained\s+for|'
  r'electronically\s+signed|end\s+of\s+(?:the\s+)?report)\b',
  caseSensitive: false,
);

/// Canonical procedure titles.
const _knownProcedures = <String, String>{
  'pet-ct': 'PET-CT Scan',
  'pet/ct': 'PET-CT Scan',
  'pet ct': 'PET-CT Scan',
  'pet scan': 'PET Scan',
  'ct scan': 'CT Scan',
  'computed tomography': 'CT Scan',
  'mri': 'MRI Scan',
  'magnetic resonance': 'MRI Scan',
  'x-ray': 'X-Ray',
  'x ray': 'X-Ray',
  'xray': 'X-Ray',
  'ultrasound': 'Ultrasound',
  'ultrasonography': 'Ultrasound',
  'sonography': 'Ultrasound',
  'usg': 'Ultrasound',
  'doppler': 'Doppler Study',
  'mammogram': 'Mammogram',
  'mammography': 'Mammogram',
  'ecg': 'ECG',
  'ekg': 'ECG',
  'electrocardiogram': 'ECG',
  'eeg': 'EEG',
  'electroencephalogram': 'EEG',
  'echocardiogram': 'Echocardiogram',
  'echocardiography': 'Echocardiogram',
  '2d echo': 'Echocardiogram',
  'xpert mtb': 'Xpert MTB/RIF',
  'mtb/rif': 'Xpert MTB/RIF',
  'genexpert': 'Xpert MTB/RIF',
  'histopathology': 'Histopathology',
  'biopsy': 'Biopsy Report',
  'culture and sensitivity': 'Culture & Sensitivity',
  'culture & sensitivity': 'Culture & Sensitivity',
};

/// Text that must not become a title.
final _titleBlocklist = RegExp(
  r'end of report|page\s+\d+\s+of\s+\d+|^\W*(specimen|collected|received|'
  r'reported|printed|checked|test name|dob)\b|'
  r'this\s+is\s+(?:the\s+)?final\s+report|report\s+status|'
  r'^\W*(?:amended|provisional|final|preliminary|interim)\s+report\b',
  caseSensitive: false,
);

/// Canonical lab panel titles.
const _knownPanels = <String, String>{
  'liver function': 'Liver Function Test',
  'lipid': 'Lipid Profile',
  'cbc haemogram': 'CBC Haemogram',
  'cbc hemogram': 'CBC Hemogram',
  'complete blood count': 'Complete Blood Count',
  'haemogram': 'Complete Blood Count',
  'hemogram': 'Complete Blood Count',
  'kidney function': 'Kidney Function Test',
  'renal function': 'Renal Function Test',
  'thyroid': 'Thyroid Profile',
  'urine routine': 'Urine Routine Examination',
  'urinalysis': 'Urinalysis',
  'glucose tolerance': 'Glucose Tolerance Test',
  'blood sugar': 'Blood Sugar',
  'hba1c': 'HbA1c',
  'glycated': 'HbA1c',
  'vitamin d': 'Vitamin D',
  'vitamin b12': 'Vitamin B12',
  'electrolyte': 'Electrolytes',
};

/// Bill title noise.
final _receiptHeadingNoise = RegExp(
  r'gst\s*invoice|tax\s*invoice|cash\s*bill|bill\s*of\s*supply|\breceipt\b|'
  r'\binvoice\b|cash\s*memo|day\s*care|\bbill\b|\bestimate\b|\bpatient\b|'
  r'\bname\b|\bage\b|\bsex\b|\bdr\b|doctor|father|address|\broad\b|street|'
  r'\bplot\b|sector|\bphone\b|\bmob\b|\bcell\b|email|www\.|\bgstin\b|'
  r'\bgst\b|\bpan\b|\btan\b|\bcin\b|\buhid\b|\bdate\b|\binv\b|\bno\.?\s*:|'
  r'reference|customer|copy|original|duplicate|amount|quantity|\bqty\b|'
  r'\bpage\b|\bsl\b|\bs\.?\s*no\b',
  caseSensitive: false,
);

/// Title noise.
final _titleNoise = RegExp(
  r'laborator|patholog|diagnostic|hospital|clinic|centre|center|'
  r'\bdr\.?\b|patient|referred|reg\.?\s*no|age\s*/\s*sex|\bdate\b|\bname\b',
  caseSensitive: false,
);
final _titleKeyword = RegExp(
  r'test|profile|panel|report|count|function|screen|assay|examination',
  caseSensitive: false,
);
// Column headers.
final _headerLineRe = RegExp(
  r'observed value|normal range|test done|test name|reference (range|interval)|'
  r'biological reference|\bresult\b',
  caseSensitive: false,
);

/// Department titles.
const _departments = <String, String>{
  'biochemistry': 'Biochemistry',
  'haematology': 'Haematology',
  'hematology': 'Hematology',
  'microbiology': 'Microbiology',
  'molecular biology': 'Molecular Biology',
  'nuclear medicine': 'Nuclear Medicine',
  'clinical pathology': 'Clinical Pathology',
  'serology': 'Serology',
  'immunology': 'Immunology',
  'histopathology': 'Histopathology',
};

String? _departmentBanner(String line) {
  final l = line.toLowerCase();
  for (final e in _departments.entries) {
    if (l.contains(e.key)) return e.value;
  }
  return null;
}

String _titleCase(String s) => s
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');
