import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/data/providers.dart';
import '../../core/widgets/document_image.dart';
import '../../core/widgets/hatched_placeholder.dart';
import '../../core/widgets/working_label.dart';
import '../export/pdf_exporter.dart';
import '../scan/review_document_screen.dart';
import '../scan/summary_rewriter.dart';
import 'document.dart';
import 'manual_entry_screen.dart';

/// View a single saved document: the document is the
/// hero; actions (Export / Edit / Delete) are quiet. All actions are local.
class DocumentDetailScreen extends ConsumerStatefulWidget {
  const DocumentDetailScreen({
    super.key,
    required this.document,
    required this.onUpdate,
    required this.onDelete,
  });

  final CuraDocument document;
  final ValueChanged<CuraDocument> onUpdate;
  final ValueChanged<CuraDocument> onDelete;

  @override
  ConsumerState<DocumentDetailScreen> createState() =>
      _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends ConsumerState<DocumentDetailScreen> {
  late CuraDocument _document;

  @override
  void initState() {
    super.initState();
    _document = widget.document;
  }

  /// Re-reads the stored row so a background summary rewrite lands on an open
  /// page, and keeps [_document] on it so Export and Edit see it too. Falls back
  /// to the local copy while the stream loads, and after a delete, when the row
  /// is gone but this screen is still popping.
  CuraDocument _syncFromStore() {
    for (final row in ref.watch(documentsProvider).value ?? const []) {
      if (row.id == _document.id) return _document = row;
    }
    return _document;
  }

  Future<void> _edit() async {
    // Manually created records edit through their own form. Scanned
    // prescriptions use Review's combined editable Summary + Medicines shape.
    final manual = _document.id.startsWith('manual-');
    final result = await Navigator.of(context).push<CuraDocument>(
      MaterialPageRoute(
        builder: (_) => manual
            ? ManualEntryScreen(existing: _document)
            : ReviewDocumentScreen(draft: _document, isEditing: true),
      ),
    );
    if (result != null) {
      setState(() => _document = result);
      widget.onUpdate(result);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text(
          '"${_document.title}" will be removed from this device. This can\'t '
          'be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      widget.onDelete(_document);
      Navigator.of(context).pop();
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  /// Exports this document's scanned pages as a PDF via the system save dialog
  /// (defaults to Downloads). A brief modal covers generation; the SAF dialog
  /// then takes over the screen, so no percent progress is needed for one doc.
  Future<void> _exportPdf() async {
    if (_document.pages.isEmpty) {
      _toast('No scanned pages to export');
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          color: AppColors.surface,
          child: Padding(
            padding: EdgeInsets.all(22),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.accent,
                  ),
                ),
                SizedBox(width: 16),
                Text(
                  'Creating PDF…',
                  style: TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    fontSize: 15,
                    color: AppColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    ExportOutcome? outcome;
    String? error;
    try {
      outcome = await PdfExporter().export([
        _document,
      ], fileName: pdfFileNameFor(_document));
    } on PdfExportException catch (e) {
      error = e.message;
    } catch (e) {
      debugPrint('[Cura.export] failed: $e');
      error = 'Couldn\'t create the PDF';
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    if (error != null) {
      _toast(error);
    } else if (outcome == ExportOutcome.saved) {
      _toast('PDF saved');
    }
    // Cancelled save dialog: stay silent — the user chose to back out.
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final doc = _syncFromStore();
    final rewriting =
        doc.summaryState == kSummaryPending ||
        doc.summaryState == kSummaryRetry;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.canvas,
      ),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // Top bar: back + centered title + overflow.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                      color: AppColors.ink,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Center(
                        child: Text('Document', style: textTheme.titleMedium),
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, color: AppColors.ink),
                      onSelected: (v) {
                        if (v == 'edit') _edit();
                        if (v == 'delete') _confirmDelete();
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children:
                      [
                            doc.pages.isNotEmpty
                                ? DocumentPages(paths: doc.pages, height: 210)
                                : const HatchedPlaceholder(
                                    height: 210,
                                    label: 'document scan',
                                  ),
                            const SizedBox(height: 20),
                            Text(doc.title, style: textTheme.titleLarge),
                            const SizedBox(height: 12),
                            _MetadataRow(document: doc),
                            const SizedBox(height: 20),
                            if (doc.type == DocumentType.prescription) ...[
                              if (doc.resultsNote != null &&
                                  doc.resultsNote!.trim().isNotEmpty)
                                _SummaryCard(
                                  text: doc.summaryRewrite ?? doc.resultsNote!,
                                  rewriting: rewriting,
                                ),
                              if (doc.resultsNote != null &&
                                  doc.resultsNote!.trim().isNotEmpty &&
                                  doc.results.isNotEmpty)
                                const SizedBox(height: 12),
                              if (doc.results.isNotEmpty)
                                _PrescriptionMedicinesCard(document: doc),
                              if (doc.results.isEmpty &&
                                  (doc.resultsNote == null ||
                                      doc.resultsNote!.trim().isEmpty))
                                _TextCard(text: doc.extractedText),
                            ] else if (doc.results.isNotEmpty)
                              _ResultsCard(document: doc)
                            else if (doc.resultsNote != null &&
                                doc.resultsNote!.trim().isNotEmpty)
                              _SummaryCard(
                                text: doc.summaryRewrite ?? doc.resultsNote!,
                                rewriting: rewriting,
                              )
                            else
                              _TextCard(text: doc.extractedText),
                            const SizedBox(height: 22),
                            _ActionRow(
                              onExport: _exportPdf,
                              onEdit: _edit,
                              onDelete: _confirmDelete,
                            ),
                          ]
                          .animate(interval: 60.ms)
                          .fadeIn(duration: 350.ms)
                          .slideY(begin: 0.1, curve: Curves.easeOutCubic),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.document});

  final CuraDocument document;

  @override
  Widget build(BuildContext context) {
    final meta = document.tags.isEmpty
        ? document.dateLabel
        : '${document.dateLabel} · ${document.tags.join(' · ')}';

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 6,
      children: [
        // Category pill.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: document.type.tileColor,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: document.type.accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                document.type.label,
                style: const TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 12.5,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.calendar_today_outlined,
              size: 14,
              color: AppColors.faint,
            ),
            const SizedBox(width: 6),
            Text(
              meta,
              style: const TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: 12.5,
                color: AppColors.faint,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ResultsCard extends StatelessWidget {
  const _ResultsCard({required this.document});

  final CuraDocument document;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Text(
            document.type.structuredSectionLabel,
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < document.results.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.divider),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      document.results[i].label,
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        document.results[i].needsReview
                            ? 'Check value'
                            : document.results[i].valueWithUnit,
                        style: const TextStyle(
                          fontFamily: 'PlusJakartaSans',
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                          fontVariations: [FontVariation('wght', 500)],
                          color: AppColors.ink,
                        ),
                      ),
                      // A "normal range" means nothing on a receipt row; the
                      // parser never sets one, but a hand-edited record could.
                      if (document.results[i].range != null &&
                          document.type != DocumentType.receipt) ...[
                        const SizedBox(height: 2),
                        Text(
                          document.results[i].range!,
                          style: textTheme.bodySmall?.copyWith(
                            color: AppColors.faint,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (document.resultsNote != null) ...[
            const SizedBox(height: 4),
            Text(document.resultsNote!, style: textTheme.bodySmall),
            const SizedBox(height: 14),
          ] else
            const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _PrescriptionMedicinesCard extends StatelessWidget {
  const _PrescriptionMedicinesCard({required this.document});

  final CuraDocument document;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Medicines', style: textTheme.titleMedium),
          const SizedBox(height: 6),
          for (var i = 0; i < document.results.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.divider),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.results[i].label.trim().isEmpty
                        ? 'Medicine'
                        : document.results[i].label,
                    style: textTheme.bodyMedium?.copyWith(
                      color: AppColors.secondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    document.results[i].value.trim().isEmpty
                        ? 'Directions not captured'
                        : document.results[i].valueWithUnit,
                    style: textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The report's own Findings / Impression, verbatim, shown when there is no
/// results table. Stateful only for the scroll controller: a long summary
/// scrolls inside the card rather than pushing the actions down the page.
class _SummaryCard extends StatefulWidget {
  const _SummaryCard({required this.text, this.rewriting = false});

  final String text;

  /// The model is still turning the scraped sections into readable prose. The
  /// deterministic text below stays readable meanwhile.
  final bool rewriting;

  @override
  State<_SummaryCard> createState() => _SummaryCardState();
}

class _SummaryCardState extends State<_SummaryCard> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Summary', style: textTheme.titleMedium),
              if (widget.rewriting) ...[
                const Spacer(),
                const WorkingLabel(text: 'Rewriting…'),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: kDocumentTextCapHeight,
            ),
            child: Scrollbar(
              controller: _controller,
              child: SingleChildScrollView(
                controller: _controller,
                child: Text(
                  widget.text,
                  style: textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextCard extends StatelessWidget {
  const _TextCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Extracted text', style: textTheme.titleMedium),
          const SizedBox(height: 10),
          Text(text, style: textTheme.bodyMedium?.copyWith(height: 1.5)),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.onExport,
    required this.onEdit,
    required this.onDelete,
  });

  final VoidCallback onExport;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: onExport,
              icon: const Icon(Icons.file_upload_outlined, size: 19),
              label: const Text('Export PDF'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.ink,
                backgroundColor: AppColors.surface,
                side: const BorderSide(color: AppColors.hairline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: const TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  fontVariations: [FontVariation('wght', 500)],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _IconSquare(
          icon: Icons.edit_outlined,
          iconColor: AppColors.secondary,
          background: AppColors.surface,
          border: AppColors.hairline,
          onTap: onEdit,
        ),
        const SizedBox(width: 10),
        _IconSquare(
          icon: Icons.delete_outline,
          iconColor: AppColors.destructive,
          background: AppColors.destructiveTint,
          border: AppColors.destructiveTint,
          onTap: onDelete,
        ),
      ],
    );
  }
}

class _IconSquare extends StatelessWidget {
  const _IconSquare({
    required this.icon,
    required this.iconColor,
    required this.background,
    required this.border,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final Color background;
  final Color border;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border),
          ),
          child: Icon(icon, size: 20, color: iconColor),
        ),
      ),
    );
  }
}
