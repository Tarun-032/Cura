import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/data/providers.dart';
import '../library/document.dart';
import '../library/widgets/document_row.dart';
import 'pdf_exporter.dart';

/// Settings -> "Export all data": every exportable record has a checkbox and
/// each selected record becomes its own PDF. Modern Android writes them to the
/// public Downloads/Cura folder; older platforms use one save dialog per PDF.
class ExportSelectionScreen extends ConsumerStatefulWidget {
  const ExportSelectionScreen({super.key});

  @override
  ConsumerState<ExportSelectionScreen> createState() =>
      _ExportSelectionScreenState();
}

class _ExportSelectionScreenState extends ConsumerState<ExportSelectionScreen> {
  final Set<String> _selected = {};
  bool _seeded = false;

  bool _exporting = false;
  int _done = 0;
  int _total = 0;
  String? _currentTitle;

  void _toggle(String id) {
    if (_exporting) return;
    setState(
      () => _selected.contains(id) ? _selected.remove(id) : _selected.add(id),
    );
  }

  void _toggleAll(List<CuraDocument> exportableDocs) {
    if (_exporting) return;
    setState(() {
      final allSelected =
          exportableDocs.isNotEmpty &&
          exportableDocs.every((doc) => _selected.contains(doc.id));
      if (allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(exportableDocs.map((doc) => doc.id));
      }
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _export(List<CuraDocument> docs) async {
    final chosen = docs
        .where((doc) => _selected.contains(doc.id) && _canExport(doc))
        .toList();
    if (chosen.isEmpty || _exporting) return;

    setState(() {
      _exporting = true;
      _done = 0;
      _total = chosen.length;
      _currentTitle = chosen.first.title;
    });

    BatchPdfExportResult? result;
    String? error;
    try {
      result = await PdfExporter().exportSeparately(
        chosen,
        onProgress: (done, total, currentTitle) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
              _currentTitle = currentTitle;
            });
          }
        },
      );
    } on PdfExportException catch (e) {
      error = e.message;
    } catch (e) {
      debugPrint('[Cura.export] batch failed: $e');
      error = 'Couldn\'t create the PDFs';
    }

    if (!mounted) return;
    setState(() {
      _exporting = false;
      _currentTitle = null;
    });

    if (error != null) {
      _toast(error);
      return;
    }
    if (result == null) return;

    final message = _resultMessage(result);
    if (message != null) _toast(message);
    if (result.saved == chosen.length &&
        result.skipped == 0 &&
        result.failed == 0 &&
        !result.cancelled &&
        result.errorMessage == null) {
      Navigator.of(context).maybePop();
    }
    // Cancelled/partial export: stay on the screen with selection intact.
  }

  String? _resultMessage(BatchPdfExportResult result) {
    final destination = result.savedToDownloadsCura ? ' to Downloads/Cura' : '';
    final saved = '${result.saved} PDF${result.saved == 1 ? '' : 's'} saved';
    final omitted = result.skipped + result.failed;

    if (result.cancelled) {
      return result.saved == 0 ? null : '$saved$destination; export stopped';
    }
    if (result.errorMessage != null) {
      return result.saved == 0
          ? result.errorMessage
          : '$saved$destination. ${result.errorMessage}';
    }
    if (result.saved == 0) {
      return omitted == 0
          ? 'No PDFs exported'
          : 'No readable scanned pages to export';
    }
    if (omitted > 0) {
      return '$saved$destination; $omitted skipped';
    }
    return '$saved$destination';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final docs = ref.watch(documentsProvider).value ?? const <CuraDocument>[];
    final exportableDocs = docs.where(_canExport).toList();

    // Preselect every record that can actually produce a PDF, once, when the
    // first database frame arrives. Records without scans remain visible below.
    if (!_seeded && docs.isNotEmpty) {
      _seeded = true;
      _selected.addAll(exportableDocs.map((doc) => doc.id));
    }

    final selectedCount = exportableDocs
        .where((doc) => _selected.contains(doc.id))
        .length;
    final allSelected =
        exportableDocs.isNotEmpty && selectedCount == exportableDocs.length;

    return PopScope(
      canPop: !_exporting,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: AppColors.surface,
        ),
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                        color: AppColors.ink,
                        onPressed: _exporting
                            ? null
                            : () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            'Export records',
                            style: textTheme.titleMedium,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$selectedCount of ${exportableDocs.length} selected',
                          style: textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: exportableDocs.isEmpty || _exporting
                            ? null
                            : () => _toggleAll(exportableDocs),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.accent,
                        ),
                        child: Text(allSelected ? 'Select none' : 'Select all'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: docs.isEmpty
                      ? Center(
                          child: Text(
                            'No documents to export',
                            style: textTheme.bodyMedium?.copyWith(
                              color: AppColors.secondary,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                          itemCount: docs.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, i) {
                            final doc = docs[i];
                            final exportable = _canExport(doc);
                            final checked =
                                exportable && _selected.contains(doc.id);
                            return DocumentRow(
                              document: doc,
                              metadata: exportable
                                  ? null
                                  : 'No scanned pages to export',
                              onTap: exportable
                                  ? () => _toggle(doc.id)
                                  : () => _toast('No scanned pages to export'),
                              trailing: Checkbox(
                                value: checked,
                                activeColor: AppColors.accent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                onChanged: _exporting || !exportable
                                    ? null
                                    : (_) => _toggle(doc.id),
                              ),
                            );
                          },
                        ),
                ),
                Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: AppColors.surface,
                    border: Border(top: BorderSide(color: AppColors.hairline)),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                  child: _exporting
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                value: _total == 0 ? null : _done / _total,
                                minHeight: 8,
                                backgroundColor: AppColors.hairline,
                                color: AppColors.accent,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _done >= _total
                                  ? 'Finishing export...'
                                  : 'Creating PDF ${_done + 1} of $_total'
                                        '${_currentTitle == null ? '' : ' - $_currentTitle'}',
                              style: textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        )
                      : SizedBox(
                          height: 52,
                          child: ElevatedButton.icon(
                            onPressed: selectedCount == 0
                                ? null
                                : () => _export(docs),
                            icon: const Icon(
                              Icons.file_upload_outlined,
                              size: 20,
                            ),
                            label: Text(
                              selectedCount == 1
                                  ? 'Export 1 PDF'
                                  : 'Export $selectedCount PDFs',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accent,
                              foregroundColor: AppColors.canvas,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              textStyle: const TextStyle(
                                fontFamily: 'PlusJakartaSans',
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                fontVariations: [FontVariation('wght', 500)],
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _canExport(CuraDocument doc) =>
    doc.pages.isNotEmpty || (doc.sourcePdfPath?.isNotEmpty ?? false);
