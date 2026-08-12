import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/widgets/document_image.dart';
import '../../core/widgets/hatched_placeholder.dart';
import '../../core/widgets/working_label.dart';
import '../ai/ai_providers.dart';
import '../library/document.dart';
import '../pdf_import/pdf_import_service.dart';
import 'document_shape.dart';
import 'receipt_parser.dart'
    show isFinalReceiptAmountLabel, isReceiptSummaryLabel;
import 'scan_extraction.dart';
import 'scan_service.dart';
import 'summary_rewriter.dart';

/// Confirm-before-save screen.
class ReviewDocumentScreen extends ConsumerStatefulWidget {
  const ReviewDocumentScreen({
    super.key,
    required this.draft,
    this.isEditing = false,
    this.onRescan,
    this.replaceActionLabel = 'Re-scan',
    this.refinement,
  });

  final CuraDocument draft;
  final bool isEditing;

  /// Captures a fresh page + OCR and returns it, or null if cancelled. Provided
  /// for new scans; null when editing an existing document.
  final Future<ScanResult?> Function()? onRescan;

  /// Camera drafts say "Re-scan"; PDF drafts say "Re-import". Both replace
  /// the complete provisional source only after the new source is ready.
  final String replaceActionLabel;

  /// An optional in-flight model job with the exact fields it may still patch.
  final ScanRefinementJob? refinement;

  @override
  ConsumerState<ReviewDocumentScreen> createState() =>
      _ReviewDocumentScreenState();
}

/// Height cap for text cards.
const double kDocumentTextCapHeight = 260;

class _ReviewDocumentScreenState extends ConsumerState<ReviewDocumentScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _textController;
  late final TextEditingController _noteController;
  // Shared scrollbar controller.
  final ScrollController _textScrollController = ScrollController();
  final ScrollController _summaryScrollController = ScrollController();
  // Anchor the rewrite popup.
  final GlobalKey _rewriteHintKey = GlobalKey();
  late DocumentType _type;
  late DateTime _date;
  List<String> _pages = const [];
  String? _sourcePdfPath;
  late List<_ResultRow> _resultRows;
  String? _resultsNote;
  bool _busy = false;

  // Background refinement state.
  bool _patching = false;
  bool _saved = false;
  bool _titleTouched = false;
  bool _typeTouched = false;
  bool _dateTouched = false;
  bool _resultsTouched = false;
  bool _noteTouched = false;
  bool _refinementPending = false;
  Set<ScanRefinementField> _refinementFields = const {};
  ScanRefinementJob? _activeRefinement;
  Timer? _refinementTimer;
  int _refinementGeneration = 0;

  bool get _summaryShaped => isSummaryDocument(_type, _textController.text);

  /// True when the breakdown has item rows.
  bool get _hasItemRows => _resultRows.any(
    (r) => r.label.isNotEmpty && !isReceiptSummaryLabel(r.label),
  );

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.draft.title);
    _textController = TextEditingController(text: widget.draft.extractedText);
    _type = widget.draft.type;
    _date = widget.draft.date;
    _pages = widget.draft.pages;
    _sourcePdfPath = widget.draft.sourcePdfPath;
    _resultRows = [];
    _seedResultRows(widget.draft.results);
    _resultsNote = widget.draft.resultsNote;
    // Mirror the summary note.
    _noteController = TextEditingController(text: _resultsNote ?? '');
    _noteController.addListener(() {
      _resultsNote = _noteController.text;
      if (!_patching) {
        if (!_noteTouched) setState(() => _noteTouched = true);
        _cancelRefinementWhenUserHasFilledEveryTarget();
      }
    });

    // Mark title edits.
    _titleController.addListener(() {
      if (!_patching) {
        if (!_titleTouched) setState(() => _titleTouched = true);
        _cancelRefinementWhenUserHasFilledEveryTarget();
      }
    });

    final refinement = widget.refinement;
    if (refinement != null) _watchRefinement(refinement, notify: false);
  }

  void _watchRefinement(ScanRefinementJob job, {bool notify = true}) {
    _refinementTimer?.cancel();
    _activeRefinement?.cancel();
    final generation = ++_refinementGeneration;

    void markPending() {
      _activeRefinement = job;
      _refinementFields = job.fields;
      _refinementPending = true;
    }

    if (notify) {
      setState(markPending);
    } else {
      markPending();
    }

    _refinementTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || generation != _refinementGeneration) return;
      job.cancel();
      _refinementGeneration++;
      setState(() {
        _activeRefinement = null;
        _refinementFields = const {};
        _refinementPending = false;
      });
    });

    job.result
        .then((ext) {
          if (!mounted || _saved || generation != _refinementGeneration) {
            return;
          }
          _refinementTimer?.cancel();
          if (ext != null) {
            _applyRefinement(ext, fields: job.fields);
          } else {
            setState(() {
              _activeRefinement = null;
              _refinementFields = const {};
              _refinementPending = false;
            });
          }
        })
        .catchError((_) {
          if (!mounted || _saved || generation != _refinementGeneration) {
            return;
          }
          _refinementTimer?.cancel();
          setState(() {
            _activeRefinement = null;
            _refinementFields = const {};
            _refinementPending = false;
          });
        });
  }

  void _cancelRefinement({bool notify = true}) {
    _refinementGeneration++;
    _refinementTimer?.cancel();
    _refinementTimer = null;
    _activeRefinement?.cancel();

    void clear() {
      _activeRefinement = null;
      _refinementFields = const {};
      _refinementPending = false;
    }

    if (notify && mounted) {
      setState(clear);
    } else {
      clear();
    }
  }

  /// Once every targeted field has a user-supplied value, cancel the request and
  /// unlock Save rather than waiting for an answer nobody needs.
  void _cancelRefinementWhenUserHasFilledEveryTarget() {
    if (!_refinementPending || _refinementFields.isEmpty) return;
    final allFilled = _refinementFields.every((field) {
      return switch (field) {
        ScanRefinementField.title =>
          _titleTouched && _titleController.text.trim().isNotEmpty,
        ScanRefinementField.type => _typeTouched,
        ScanRefinementField.date => _dateTouched,
        ScanRefinementField.results => _resultsTouched,
        ScanRefinementField.receiptNote =>
          _noteTouched && _noteController.text.trim().isNotEmpty,
      };
    });
    if (allFilled) _cancelRefinement();
  }

  /// Patches the draft with the model's validated fields, only where the user
  /// hasn't edited and only filling results the deterministic reader missed.
  void _applyRefinement(
    ScanExtraction ext, {
    required Set<ScanRefinementField> fields,
  }) {
    setState(() {
      _activeRefinement = null;
      _refinementFields = const {};
      _refinementPending = false;
      _patching = true;
      final refinedTitle = ext.title?.trim();
      // Keep generic bill titles out.
      final genericRefinedBillTitle =
          _type == DocumentType.receipt &&
          refinedTitle != null &&
          RegExp(
            r'^(medical|hospital|pharmacy)?\s*(bill|invoice|receipt)$',
            caseSensitive: false,
          ).hasMatch(refinedTitle);
      if (fields.contains(ScanRefinementField.title) &&
          !_titleTouched &&
          refinedTitle != null &&
          refinedTitle.isNotEmpty &&
          !genericRefinedBillTitle) {
        _titleController.text = refinedTitle;
      }
      if (fields.contains(ScanRefinementField.type) &&
          !_typeTouched &&
          ext.type != null &&
          acceptsRefinedType(
            current: _type,
            next: ext.type!,
            extractedText: _textController.text,
            hasSummary: _resultsNote?.trim().isNotEmpty ?? false,
          )) {
        _type = ext.type!;
      }
      if (fields.contains(ScanRefinementField.date) &&
          !_dateTouched &&
          ext.date != null) {
        _date = ext.date!;
      }
      final shaped = _type;
      final summaryShaped = isSummaryDocument(shaped, _textController.text);
      if (fields.contains(ScanRefinementField.results) &&
          !summaryShaped &&
          !_resultsTouched &&
          ext.results.isNotEmpty) {
        if (shaped == DocumentType.lab &&
            (ext.verifiedTableRepair || ext.groundedLabRows)) {
          _seedResultRows(
            mergeRefinedResults(
              type: shaped,
              deterministic: _collectResults(),
              refined: ext.results,
              verifiedTableRepair: ext.verifiedTableRepair,
              groundedLabRows: ext.groundedLabRows,
            ),
          );
        } else if (shaped == DocumentType.prescription ||
            (shaped != DocumentType.lab &&
                // A bill breakdown is geometry-only; the model contributes the
                // "what was this for" note instead of rows.
                shaped != DocumentType.receipt &&
                widget.draft.results.isEmpty)) {
          _seedResultRows(ext.results);
        }
      }
      if (summaryShaped && !_resultsTouched) {
        for (final r in _resultRows) {
          r.dispose();
        }
        _resultRows = [];
      }
      if (fields.contains(ScanRefinementField.receiptNote) &&
          !_noteTouched &&
          (_resultsNote == null || _resultsNote!.isEmpty) &&
          ext.note != null &&
          ext.note!.isNotEmpty) {
        _resultsNote = ext.note;
        _noteController.text = ext.note!;
      }
      _patching = false;
    });
  }

  @override
  void dispose() {
    _cancelRefinement(notify: false);
    _titleController.dispose();
    _textController.dispose();
    _noteController.dispose();
    _textScrollController.dispose();
    _summaryScrollController.dispose();
    for (final r in _resultRows) {
      r.dispose();
    }
    super.dispose();
  }

  /// Current edited results.
  List<DocumentResult> _collectResults() => [
    for (final r in _resultRows)
      if (r.label.isNotEmpty || r.value.isNotEmpty)
        DocumentResult(
          r.label,
          r.value,
          unit: _type == DocumentType.prescription || r.unit.isEmpty
              ? null
              : r.unit,
          range: _type == DocumentType.prescription || r.range.isEmpty
              ? null
              : r.range,
          labFlag: r.labFlag,
        ),
  ];

  void _seedResultRows(List<DocumentResult> results) {
    for (final r in _resultRows) {
      r.dispose();
    }
    _resultRows = [
      for (final r in results)
        _type == DocumentType.prescription
            ? _ResultRow.fromPrescription(r)
            : _ResultRow.from(r),
    ];
  }

  void _markResultsTouched(String _) {
    if (!_patching && !_resultsTouched) {
      setState(() => _resultsTouched = true);
      _cancelRefinementWhenUserHasFilledEveryTarget();
    }
  }

  void _addResultRow() => setState(() {
    _resultsTouched = true;
    _resultRows.add(_ResultRow.empty());
  });

  void _removeResultRow(int index) {
    setState(() {
      _resultsTouched = true;
      _resultRows.removeAt(index).dispose();
    });
  }

  String get _dateLabel {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[_date.month - 1]} ${_date.day}, ${_date.year}';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _dateTouched = true;
        _date = picked;
      });
      _cancelRefinementWhenUserHasFilledEveryTarget();
    }
  }

  void _save() {
    _saved = true; // stop any late AI patch from touching a popped screen
    // A hand-edited summary must never sit under a rewrite of the old text.
    final noteEdited =
        (_resultsNote?.trim() ?? '') !=
        (widget.draft.resultsNote?.trim() ?? '');
    final doc = widget.draft.copyWith(
      title: _titleController.text.trim().isEmpty
          ? widget.draft.title
          : _titleController.text.trim(),
      type: _type,
      date: _date,
      extractedText: _textController.text.trim(),
      pages: _pages,
      sourcePdfPath: _sourcePdfPath,
      clearSourcePdf: _sourcePdfPath == null,
      // Narrative types never persist result rows (vitals/protocol noise).
      results: _summaryShaped ? const [] : _collectResults(),
      resultsNote: (_resultsNote == null || _resultsNote!.trim().isEmpty)
          ? null
          : _resultsNote!.trim(),
      clearResultsNote: _resultsNote == null || _resultsNote!.trim().isEmpty,
      clearSummaryRewrite: noteEdited,
      clearSummaryState: noteEdited,
    );
    Navigator.of(context).pop(doc);
  }

  Future<void> _rescan() async {
    final onRescan = widget.onRescan;
    if (onRescan == null) {
      _toast('Re-scan from the scan button on the home screen');
      return;
    }
    _cancelRefinement();
    setState(() => _busy = true);
    try {
      final result = await onRescan();
      if (result != null && mounted) {
        final svc = ref.read(scanServiceProvider);
        // Release the old source after replace.
        if (_sourcePdfPath != null) {
          await ref
              .read(pdfImportServiceProvider)
              .deleteImportedPdf(_sourcePdfPath);
        } else {
          await svc.deleteImages(_pages);
        }
        final detectedType = svc.detectType(result.text);
        final summaryShaped = isSummaryDocument(detectedType, result.text);
        // Handle prescriptions and receipts separately.
        final rx = detectedType == DocumentType.prescription
            ? svc.parsePrescription(result.text)
            : null;
        final deterministicNote = rx != null
            ? rx.summary
            : detectedType == DocumentType.receipt
            ? null
            : summaryShaped
            ? svc.extractFindingsSummary(result.text)
            : (result.results.isNotEmpty
                  ? svc.summarize(result.results, type: detectedType)
                  : svc.extractFindingsSummary(result.text));
        setState(() {
          _pages = result.imagePaths;
          _sourcePdfPath = result.sourcePdfPath;
          _textController.text = result.text;
          _titleController.text = svc.detectTitle(result.text);
          _type = detectedType;
          _date = svc.extractDate(result.text) ?? DateTime.now();
          _resultsNote = deterministicNote;
          _noteController.text = deterministicNote ?? '';
          _seedResultRows(
            rx != null
                ? rx.medicines
                : summaryShaped
                ? const []
                : result.results,
          );
          // Re-scan resets refinement.
          _titleTouched = false;
          _typeTouched = false;
          _dateTouched = false;
          _resultsTouched = false;
          _noteTouched = false;
        });

        // Start the new refinement job.
        final useRemote = await ref.read(remoteAiStoreProvider).remoteActive();
        final job = ref
            .read(aiServiceProvider)
            .startDocumentRefinement(
              result.text,
              draftType: detectedType,
              useRemote: useRemote,
              title: _titleController.text,
              tableEvidence: result.tableEvidence,
              deterministicResults: result.results,
            );
        if (job != null && mounted) {
          _watchRefinement(job);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  /// Read-only findings block.
  List<Widget> _findingsSection(TextTheme textTheme) {
    final note = _resultsNote?.trim();
    if (note == null || note.isEmpty) return const [];
    return [
      _summaryLabel(),
      const SizedBox(height: 8),
      _FieldBox(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: kDocumentTextCapHeight),
          child: Scrollbar(
            controller: _summaryScrollController,
            child: SingleChildScrollView(
              controller: _summaryScrollController,
              child: Text(
                note,
                style: textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),
    ];
  }

  List<Widget> _prescriptionSections(TextTheme textTheme) => [
    _summaryLabel(),
    const SizedBox(height: 8),
    _FieldBox(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: kDocumentTextCapHeight),
        child: Scrollbar(
          controller: _summaryScrollController,
          child: TextField(
            key: const ValueKey('prescription-summary'),
            controller: _noteController,
            scrollController: _summaryScrollController,
            style: textTheme.bodyMedium?.copyWith(height: 1.5),
            minLines: 3,
            maxLines: null,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: 'Add a short summary (optional)',
              hintStyle: textTheme.bodyMedium?.copyWith(color: AppColors.faint),
            ),
          ),
        ),
      ),
    ),
    const SizedBox(height: 20),
    Row(
      children: [
        _label('Medicines'),
        const Spacer(),
        Text('Check these before saving', style: textTheme.labelSmall),
      ],
    ),
    const SizedBox(height: 8),
    if (_resultRows.isEmpty)
      const _PrescriptionEmptyState()
    else ...[
      _ResultReviewNotice(
        rows: _resultRows,
        noun: 'medicine',
        optionalValue: true,
        onRescan: widget.onRescan == null ? null : _rescan,
        actionLabel: widget.replaceActionLabel,
      ),
      for (var i = 0; i < _resultRows.length; i++) ...[
        _PrescriptionMedicineRowEditor(
          index: i,
          row: _resultRows[i],
          onChanged: _markResultsTouched,
          onDelete: () => _removeResultRow(i),
        ),
        const SizedBox(height: 10),
      ],
    ],
    _AddResultButton(label: 'Add medicine', onTap: _addResultRow),
    const SizedBox(height: 20),
  ];

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.canvas,
      ),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(
                title: widget.isEditing ? 'Edit document' : 'Review document',
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    // Scanned page preview + Re-scan pill.
                    Stack(
                      children: [
                        _pages.isNotEmpty
                            ? DocumentPages(
                                paths: _pages,
                                height: 172,
                                openOnTap: !_busy,
                              )
                            : const HatchedPlaceholder(
                                height: 172,
                                label: 'scanned page',
                              ),
                        Positioned(
                          top: 12,
                          right: 12,
                          child: _RescanPill(
                            label: widget.replaceActionLabel,
                            onTap: _busy ? null : _rescan,
                          ),
                        ),
                        if (_busy)
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Center(
                                child: SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: AppColors.surface,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 22),

                    _label('Title'),
                    const SizedBox(height: 8),
                    _FieldBox(
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const ValueKey('document-title'),
                              controller: _titleController,
                              style: textTheme.bodyLarge,
                              decoration: const InputDecoration(
                                isCollapsed: true,
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          if (_isRefining(ScanRefinementField.title))
                            const WorkingLabel(
                              key: ValueKey('title-refinement-status'),
                              text: 'Writing title…',
                            )
                          else
                            const Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: AppColors.faint,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    _refinementLabel(
                      'Type',
                      field: ScanRefinementField.type,
                      pendingText: 'Checking type…',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        // Visit note is for manually typed records only, though
                        // the chip still renders if the draft already is one.
                        for (final t in DocumentType.values)
                          if (t != DocumentType.visit ||
                              _type == DocumentType.visit)
                            _TypeChip(
                              label: t.label,
                              selected: _type == t,
                              onTap: () {
                                setState(() {
                                  _typeTouched = true;
                                  _type = t;
                                  // Switching to a narrative type drops any
                                  // rows the geometry parser may have left.
                                  if (isSummaryDocument(
                                    t,
                                    _textController.text,
                                  )) {
                                    for (final r in _resultRows) {
                                      r.dispose();
                                    }
                                    _resultRows = [];
                                  }
                                });
                                _cancelRefinementWhenUserHasFilledEveryTarget();
                              },
                            ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    _refinementLabel(
                      'Date',
                      field: ScanRefinementField.date,
                      pendingText: 'Checking date…',
                    ),
                    const SizedBox(height: 8),
                    _FieldBox(
                      onTap: _pickDate,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.calendar_today_outlined,
                            size: 18,
                            color: AppColors.secondary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(_dateLabel, style: textTheme.bodyLarge),
                          ),
                          const Icon(
                            Icons.edit_outlined,
                            size: 18,
                            color: AppColors.faint,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // A prescription pairs a Summary with an optional medicine
                    // list; narrative reports use Summary alone.
                    if (_type == DocumentType.prescription) ...[
                      ..._prescriptionSections(textTheme),
                    ] else if (_summaryShaped) ...[
                      ..._findingsSection(textTheme),
                    ] else ...[
                      // Findings beat an empty list; the editor stays below.
                      if (_resultRows.isEmpty &&
                          _type != DocumentType.receipt &&
                          !_isRefining(ScanRefinementField.results))
                        ..._findingsSection(textTheme),
                      _refinementLabel(
                        _type.structuredSectionLabel,
                        field: ScanRefinementField.results,
                        pendingText: 'Checking results…',
                        idleTrailing: Text(
                          'Check these before saving',
                          style: textTheme.labelSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _ResultReviewNotice(
                        rows: _resultRows,
                        noun: _type == DocumentType.receipt
                            ? 'amount'
                            : 'result',
                        onRescan: widget.onRescan == null ? null : _rescan,
                        actionLabel: widget.replaceActionLabel,
                      ),
                      for (var i = 0; i < _resultRows.length; i++) ...[
                        _ResultRowEditor(
                          row: _resultRows[i],
                          receipt: _type == DocumentType.receipt,
                          finalAmount:
                              _type == DocumentType.receipt &&
                              isFinalReceiptAmountLabel(_resultRows[i].label),
                          onDelete: () => _removeResultRow(i),
                          onChanged: _markResultsTouched,
                        ),
                        const SizedBox(height: 10),
                      ],
                      _AddResultButton(
                        label: _type == DocumentType.receipt
                            ? 'Add item'
                            : 'Add result',
                        onTap: _addResultRow,
                      ),
                      // Bills with no readable breakdown still get a free-text
                      // "why", saved as resultsNote so Ask can see it.
                      if (_type == DocumentType.receipt) ...[
                        const SizedBox(height: 20),
                        _label('What was this for?'),
                        const SizedBox(height: 8),
                        _FieldBox(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const ValueKey('receipt-note'),
                                  controller: _noteController,
                                  style: textTheme.bodyMedium?.copyWith(
                                    height: 1.5,
                                  ),
                                  minLines: 1,
                                  maxLines: 3,
                                  decoration: InputDecoration(
                                    isCollapsed: true,
                                    border: InputBorder.none,
                                    hintText: _hasItemRows
                                        ? 'Optional note about this bill'
                                        : 'e.g. Ultrasound scan, consultation, '
                                              'medicines…',
                                    hintStyle: textTheme.bodyMedium?.copyWith(
                                      color: AppColors.faint,
                                    ),
                                  ),
                                ),
                              ),
                              if (_isRefining(
                                ScanRefinementField.receiptNote,
                              )) ...[
                                const SizedBox(width: 10),
                                const WorkingLabel(
                                  key: ValueKey(
                                    'receipt-note-refinement-status',
                                  ),
                                  text: 'Writing bill note…',
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                    ],

                    Row(
                      children: [
                        _label('Extracted text'),
                        const Spacer(),
                        const Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: AppColors.faint,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _FieldBox(
                      // maxLines: null keeps the card hugging a short receipt;
                      // the cap only bites on a long transcript.
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: kDocumentTextCapHeight,
                        ),
                        child: Scrollbar(
                          controller: _textScrollController,
                          child: TextField(
                            controller: _textController,
                            scrollController: _textScrollController,
                            style: textTheme.bodyMedium?.copyWith(height: 1.5),
                            maxLines: null,
                            decoration: const InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    SizedBox(
                      height: 54,
                      child: ElevatedButton(
                        onPressed: (_busy || _refinementPending) ? null : _save,
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
                        child: const Text('Save to device'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The Summary heading, with a tappable hint when a background rewrite is
  /// coming. Matches the Medicines and Extracted text rows. Editing an existing
  /// record shows no hint: its rewrite has already happened.
  Widget _summaryLabel() {
    if (widget.isEditing ||
        !needsSummaryRewrite(
          type: _type,
          extractedText: _textController.text,
          note: _resultsNote,
        )) {
      return _label('Summary');
    }
    final remote = ref.watch(activeEngineProvider).value?.isRemote ?? false;
    return Row(
      children: [
        _label('Summary'),
        const Spacer(),
        InkWell(
          key: _rewriteHintKey,
          onTap: () => _showRewriteInfo(remote),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Cura will tidy this up',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.info_outline,
                  size: 15,
                  color: AppColors.faint,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// A small popup hanging off the icon, like the Ask message menu. A dialog
  /// would take the whole screen for one sentence.
  void _showRewriteInfo(bool remote) {
    final anchor =
        _rewriteHintKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (anchor == null || overlay == null) return;
    final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = anchor.localToGlobal(
      anchor.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        bottomRight.dy + 4,
        overlay.size.width - bottomRight.dx,
        overlay.size.height - bottomRight.dy,
      ),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.hairline),
      ),
      constraints: const BoxConstraints(maxWidth: 260),
      items: [
        PopupMenuItem<void>(
          height: 0,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Text(
            remote
                ? 'Cura will rewrite this summary in the background so it '
                      'reads clearly. Names and personal details are removed '
                      'before anything is sent.'
                : 'Cura will rewrite this summary in the background so it '
                      'reads clearly, on your device.',
            style: const TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 13,
              height: 1.4,
              color: AppColors.ink,
            ),
          ),
        ),
      ],
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'PlusJakartaSans',
        fontSize: 13,
        color: AppColors.secondary,
      ),
    );
  }

  bool _isRefining(ScanRefinementField field) {
    if (!_refinementPending || !_refinementFields.contains(field)) return false;
    return switch (field) {
      ScanRefinementField.title => !_titleTouched,
      ScanRefinementField.type => !_typeTouched,
      ScanRefinementField.date => !_dateTouched,
      ScanRefinementField.results => !_resultsTouched,
      ScanRefinementField.receiptNote => !_noteTouched,
    };
  }

  Widget _refinementLabel(
    String text, {
    required ScanRefinementField field,
    required String pendingText,
    Widget? idleTrailing,
  }) {
    final pending = _isRefining(field);
    if (!pending && idleTrailing == null) return _label(text);
    return Row(
      children: [
        _label(text),
        const Spacer(),
        if (pending) WorkingLabel(text: pendingText) else idleTrailing!,
      ],
    );
  }
}

/// Back chevron + title row used by the full-screen document pages.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            color: AppColors.ink,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _RescanPill extends StatelessWidget {
  const _RescanPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.refresh, size: 16, color: AppColors.ink),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontVariations: [FontVariation('wght', 500)],
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Holds the three editable fields for one results row.
class _ResultRow {
  _ResultRow(
    this.labelCtrl,
    this.valueCtrl,
    this.unitCtrl,
    this.rangeCtrl, {
    this.seedFlag,
    this.seedValue = '',
  });

  factory _ResultRow.from(DocumentResult r) => _ResultRow(
    TextEditingController(text: r.label),
    TextEditingController(text: r.value),
    TextEditingController(text: r.unit ?? ''),
    TextEditingController(text: r.range ?? ''),
    seedFlag: r.labFlag,
    seedValue: r.value.trim(),
  );

  /// A prescription may have a dose unit in the lab-shaped unit slot, so fold it
  /// into Directions rather than lose it during an edit.
  factory _ResultRow.fromPrescription(DocumentResult r) => _ResultRow(
    TextEditingController(text: r.label),
    TextEditingController(text: r.valueWithUnit),
    TextEditingController(),
    TextEditingController(),
  );

  factory _ResultRow.empty() => _ResultRow(
    TextEditingController(),
    TextEditingController(),
    TextEditingController(),
    TextEditingController(),
  );

  final TextEditingController labelCtrl;
  final TextEditingController valueCtrl;
  final TextEditingController unitCtrl;
  final TextEditingController rangeCtrl;

  /// Lab mark tied to [seedValue].
  final String? seedFlag;
  final String seedValue;

  /// Cleared once the value is edited.
  String? get labFlag => value == seedValue ? seedFlag : null;

  String get label => labelCtrl.text.trim();
  String get value => valueCtrl.text.trim();
  String get unit => unitCtrl.text.trim();
  String get range => rangeCtrl.text.trim();

  void dispose() {
    labelCtrl.dispose();
    valueCtrl.dispose();
    unitCtrl.dispose();
    rangeCtrl.dispose();
  }
}

/// One editable results row: test name on top, value + normal range below.
/// Receipt rows are money, not measurements: Item + Amount only — the unit and
/// normal-range cells would be meaningless and are hidden.
class _ResultRowEditor extends StatelessWidget {
  const _ResultRowEditor({
    required this.row,
    required this.onDelete,
    required this.onChanged,
    this.receipt = false,
    this.finalAmount = false,
  });

  final _ResultRow row;
  final VoidCallback onDelete;
  final ValueChanged<String> onChanged;
  final bool receipt;
  final bool finalAmount;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 12),
      decoration: BoxDecoration(
        color: finalAmount ? AppColors.mintCardFill : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: finalAmount ? AppColors.mintCardBorder : AppColors.hairline,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _cell(
                  textTheme,
                  row.labelCtrl,
                  receipt ? 'Item' : 'Test name',
                  onChanged,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: AppColors.faint),
                tooltip: 'Remove',
                onPressed: onDelete,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Expanded(
                  child: _cell(
                    textTheme,
                    row.valueCtrl,
                    receipt ? 'Amount' : 'Value',
                    onChanged,
                  ),
                ),
                if (!receipt) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: _cell(textTheme, row.unitCtrl, 'Unit', onChanged),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: _cell(
                      textTheme,
                      row.rangeCtrl,
                      'Normal range',
                      onChanged,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: row.valueCtrl,
            builder: (context, value, _) {
              if (value.text.trim().isNotEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(0, 6, 8, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    receipt
                        ? 'Check the amount against the bill'
                        : 'Check value against the report',
                    style: const TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 11.5,
                      color: AppColors.secondary,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _cell(
    TextTheme textTheme,
    TextEditingController c,
    String hint,
    ValueChanged<String> onChanged,
  ) {
    return TextField(
      controller: c,
      onChanged: onChanged,
      style: textTheme.bodyMedium,
      decoration: InputDecoration(
        isCollapsed: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        border: InputBorder.none,
        hintText: hint,
        hintStyle: textTheme.bodyMedium?.copyWith(color: AppColors.faint),
      ),
    );
  }
}

class _PrescriptionMedicineRowEditor extends StatelessWidget {
  const _PrescriptionMedicineRowEditor({
    required this.index,
    required this.row,
    required this.onChanged,
    required this.onDelete,
  });

  final int index;
  final _ResultRow row;
  final ValueChanged<String> onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('medicine-name-$index'),
                  controller: row.labelCtrl,
                  onChanged: onChanged,
                  style: textTheme.bodyMedium,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: InputBorder.none,
                    hintText: 'Medicine name or strength',
                    hintStyle: textTheme.bodyMedium?.copyWith(
                      color: AppColors.faint,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: AppColors.faint),
                tooltip: 'Remove medicine',
                onPressed: onDelete,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              key: ValueKey('medicine-directions-$index'),
              controller: row.valueCtrl,
              onChanged: onChanged,
              style: textTheme.bodyMedium,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: InputBorder.none,
                hintText: 'Directions',
                hintStyle: textTheme.bodyMedium?.copyWith(
                  color: AppColors.faint,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrescriptionEmptyState extends StatelessWidget {
  const _PrescriptionEmptyState();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.hairline),
    ),
    child: Row(
      children: [
        const Icon(Icons.medication_outlined, size: 18, color: AppColors.faint),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            'No clear medicines found. Add one if needed.',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
  );
}

class _ResultReviewNotice extends StatelessWidget {
  const _ResultReviewNotice({
    required this.rows,
    required this.actionLabel,
    this.noun = 'result',
    this.optionalValue = false,
    this.onRescan,
  });

  final List<_ResultRow> rows;
  final String actionLabel;
  final String noun;

  /// True for prescription medicines, where Directions is optional so only a
  /// nameless row needs checking; false for lab results, where a missing value is
  /// the problem. A fully blank row is a placeholder either way.
  final bool optionalValue;
  final VoidCallback? onRescan;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: Listenable.merge([
        for (final row in rows) ...[row.labelCtrl, row.valueCtrl],
      ]),
      builder: (context, _) {
        final unresolved = rows.where((row) {
          final hasName = row.label.isNotEmpty;
          final hasDetail = row.value.isNotEmpty;
          if (!hasName && !hasDetail) return false; // just-added blank row
          return optionalValue ? !hasName : !hasDetail;
        }).toList();
        final count = unresolved.length;
        if (count == 0) return const SizedBox.shrink();
        final named = unresolved
            .map((row) => row.label.trim())
            .where((label) => label.isNotEmpty)
            .take(3)
            .join(', ');
        final suffix = count > 3 ? ', and ${count - 3} more' : '';
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.info_outline,
                size: 18,
                color: AppColors.secondary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '$count ${count == 1 ? '$noun needs' : '${noun}s need'} '
                  'checking${named.isEmpty ? '' : ': $named$suffix'}. '
                  'Review ${count == 1 ? 'it' : 'them'} before saving.',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              if (onRescan != null)
                TextButton(onPressed: onRescan, child: Text(actionLabel)),
            ],
          ),
        );
      },
    );
  }
}

/// Dashed-feel "add a row" affordance under the results list.
class _AddResultButton extends StatelessWidget {
  const _AddResultButton({required this.onTap, this.label = 'Add result'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add, size: 18, color: AppColors.accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: 14,
                fontWeight: FontWeight.w500,
                fontVariations: [FontVariation('wght', 500)],
                color: AppColors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// White rounded field container (label-less input/well).
class _FieldBox extends StatelessWidget {
  const _FieldBox({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: box,
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : AppColors.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.hairline,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontVariations: const [FontVariation('wght', 500)],
              color: selected ? AppColors.canvas : AppColors.secondary,
            ),
          ),
        ),
      ),
    );
  }
}
