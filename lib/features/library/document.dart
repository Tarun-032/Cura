import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// The kind of medical document. Drives the row's icon, label and category tint.
/// `visit` is a manually typed visit note (no source document) — it is only
/// offered on the manual-entry form, never by the scan/import type selector.
enum DocumentType { lab, prescription, receipt, discharge, imaging, visit }

extension DocumentTypeDisplay on DocumentType {
  /// Human label shown in metadata and the type selector.
  String get label => switch (this) {
    DocumentType.lab => 'Lab report',
    DocumentType.prescription => 'Prescription',
    DocumentType.receipt => 'Receipt',
    DocumentType.discharge => 'Discharge summary',
    DocumentType.imaging => 'Imaging',
    DocumentType.visit => 'Visit note',
  };

  /// Thin line icon for the category tile.
  IconData get icon => switch (this) {
    DocumentType.lab => Icons.science_outlined,
    DocumentType.prescription => Icons.medication_outlined,
    DocumentType.receipt => Icons.receipt_long_outlined,
    DocumentType.discharge => Icons.description_outlined,
    DocumentType.imaging => Icons.monitor_heart_outlined,
    DocumentType.visit => Icons.event_note_outlined,
  };

  /// Icon color inside the category tile.
  Color get accentColor => switch (this) {
    DocumentType.lab => AppColors.catLab,
    DocumentType.prescription => AppColors.mint,
    DocumentType.receipt => AppColors.catReceiptIcon,
    DocumentType.discharge => AppColors.catDischarge,
    DocumentType.imaging => AppColors.catImaging,
    DocumentType.visit => AppColors.catVisit,
  };

  /// Soft tile fill (the category accent at low alpha).
  Color get tileColor => switch (this) {
    DocumentType.lab => AppColors.catLab.withValues(alpha: 0.16),
    DocumentType.prescription => AppColors.mint.withValues(alpha: 0.16),
    DocumentType.receipt => AppColors.catReceipt.withValues(alpha: 0.18),
    DocumentType.discharge => AppColors.catDischarge.withValues(alpha: 0.16),
    DocumentType.imaging => AppColors.catImaging.withValues(alpha: 0.16),
    DocumentType.visit => AppColors.catVisit.withValues(alpha: 0.16),
  };

  /// True for narrative reports that should store a Summary, not Results rows
  /// (imaging findings, discharge narrative, typed visit notes — not lab
  /// tables or bill lines).
  bool get isSummaryShaped =>
      this == DocumentType.imaging ||
      this == DocumentType.discharge ||
      this == DocumentType.visit;

  /// Section heading for the structured card: Summary / Breakdown / Results.
  String get structuredSectionLabel => switch (this) {
    DocumentType.imaging || DocumentType.discharge => 'Summary',
    DocumentType.receipt => 'Breakdown',
    _ => 'Results',
  };
}

/// A single label→value row inside a document's Results card, with an optional
/// reference range (e.g. "13–17 gm%") shown faintly beneath the value.
class DocumentResult {
  const DocumentResult(
    this.label,
    this.value, {
    this.unit,
    this.range,
    this.labFlag,
  });

  final String label;
  final String value;
  final String? unit;
  final String? range;

  /// Lab mark (*, #, ↑, ↓) for range cross-check.
  final String? labFlag;

  bool get needsReview => value.trim().isEmpty;

  String get valueWithUnit {
    final u = unit?.trim() ?? '';
    return u.isEmpty ? value : '${value.trim()} $u'.trim();
  }
}

/// A single stored medical document, as the UI sees it. The Drift row is mapped
/// to and from this shape in [DocumentRepository].
class CuraDocument {
  const CuraDocument({
    required this.id,
    required this.title,
    required this.type,
    required this.date,
    this.extractedText = '',
    this.results = const [],
    this.resultsNote,
    this.summaryRewrite,
    this.summaryState,
    this.tags = const [],
    this.pages = const [],
    this.sourcePdfPath,
  });

  final String id;
  final String title;
  final DocumentType type;
  final DateTime date;

  /// Full text read off the page (shown on review; fallback on detail).
  final String extractedText;

  /// Structured label→value rows (shown in the detail Results card).
  final List<DocumentResult> results;

  /// Optional footnote under the Results rows.
  final String? resultsNote;

  /// The model's readable rewrite of [resultsNote], written in the background
  /// after a scan is saved. Display only: [resultsNote] stays verbatim because
  /// Ask searches and quotes it.
  final String? summaryRewrite;

  /// 'pending', 'retry', or null once the rewrite is settled either way.
  final String? summaryState;

  /// Free-form tags, e.g. ["bloodwork", "annual"].
  final List<String> tags;

  /// On-device paths to the scanned page images for this document, in order. A
  /// record can span several pages (a multi-page report or bill), all kept under
  /// this one document.
  final List<String> pages;

  /// Private path to an untouched user-imported PDF. Rendered [pages] remain
  /// the OCR/preview source, while this file is copied byte-for-byte on export.
  /// Camera-created records and pre-v4 database rows leave it null.
  final String? sourcePdfPath;

  /// The first page image, or null when there are none — a convenience for
  /// single-image callers (thumbnails, deletion of a lone image).
  String? get primaryImage => pages.isEmpty ? null : pages.first;

  /// Returns a copy with the given fields replaced (used when editing and when
  /// AI structuring fills in the results).
  CuraDocument copyWith({
    String? title,
    DocumentType? type,
    DateTime? date,
    String? extractedText,
    List<String>? pages,
    List<DocumentResult>? results,
    String? resultsNote,
    bool clearResultsNote = false,
    String? summaryRewrite,
    bool clearSummaryRewrite = false,
    String? summaryState,
    bool clearSummaryState = false,
    String? sourcePdfPath,
    bool clearSourcePdf = false,
  }) {
    return CuraDocument(
      id: id,
      title: title ?? this.title,
      type: type ?? this.type,
      date: date ?? this.date,
      extractedText: extractedText ?? this.extractedText,
      results: results ?? this.results,
      resultsNote: clearResultsNote ? null : (resultsNote ?? this.resultsNote),
      summaryRewrite: clearSummaryRewrite
          ? null
          : (summaryRewrite ?? this.summaryRewrite),
      summaryState: clearSummaryState
          ? null
          : (summaryState ?? this.summaryState),
      tags: tags,
      pages: pages ?? this.pages,
      sourcePdfPath: clearSourcePdf
          ? null
          : (sourcePdfPath ?? this.sourcePdfPath),
    );
  }

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// e.g. "Apr 12, 2025" — formatted without the intl package.
  String get dateLabel =>
      '${_months[date.month - 1]} ${date.day}, ${date.year}';

  /// e.g. "Apr 12" — month + day, no year (timeline node labels).
  String get shortDateLabel => '${_months[date.month - 1]} ${date.day}';
}

/// Sample documents for UI previews and tests.
/// (Not `const` because `DateTime` literals aren't compile-time constants.)
final List<CuraDocument> sampleDocuments = [
  CuraDocument(
    id: 'sample-cbc',
    title: 'Complete blood count',
    type: DocumentType.lab,
    date: DateTime(2025, 4, 12),
    extractedText:
        'Hemoglobin 14.2 g/dL · WBC 6.1 ×10⁹/L · Platelets 250 ×10⁹/L · '
        'Total cholesterol 184 mg/dL. All values within normal reference range.',
    results: [
      DocumentResult('Hemoglobin', '14.2 g/dL'),
      DocumentResult('White blood cells', '6.1 ×10⁹/L'),
      DocumentResult('Platelets', '250 ×10⁹/L'),
      DocumentResult('Total cholesterol', '184 mg/dL'),
    ],
    resultsNote: 'All values within the normal reference range.',
    tags: ['bloodwork', 'annual'],
  ),
  CuraDocument(
    id: 'sample-amoxicillin',
    title: 'Amoxicillin 500 mg',
    type: DocumentType.prescription,
    date: DateTime(2025, 4, 2),
    extractedText:
        'Amoxicillin 500 mg capsules. Take one capsule three times daily for '
        '7 days. Complete the full course.',
    results: [
      DocumentResult('Dose', '500 mg'),
      DocumentResult('Frequency', '3× daily'),
      DocumentResult('Duration', '7 days'),
    ],
    tags: ['antibiotic'],
  ),
  CuraDocument(
    id: 'sample-pharmacy',
    title: 'City Pharmacy receipt',
    type: DocumentType.receipt,
    date: DateTime(2025, 3, 28),
    extractedText:
        'City Pharmacy. 3 items. Total \$24.50 paid by card on Mar 28, 2025.',
    results: [
      DocumentResult('Total', '\$24.50'),
      DocumentResult('Items', '3'),
      DocumentResult('Paid', 'Card'),
    ],
    tags: ['pharmacy'],
  ),
  CuraDocument(
    id: 'sample-discharge',
    title: 'Discharge summary',
    type: DocumentType.discharge,
    date: DateTime(2025, 3, 15),
    extractedText:
        'Patient discharged in stable condition after a two-day observation. '
        'Follow up with primary care in two weeks. Continue prescribed '
        'medication and rest.',
    tags: ['hospital'],
  ),
];
