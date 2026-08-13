import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Document kind. `visit` is manual-entry only.
enum DocumentType { lab, prescription, receipt, discharge, imaging, visit }

extension DocumentTypeDisplay on DocumentType {
  /// Display label.
  String get label => switch (this) {
    DocumentType.lab => 'Lab report',
    DocumentType.prescription => 'Prescription',
    DocumentType.receipt => 'Receipt',
    DocumentType.discharge => 'Discharge summary',
    DocumentType.imaging => 'Imaging',
    DocumentType.visit => 'Visit note',
  };

  /// Category icon.
  IconData get icon => switch (this) {
    DocumentType.lab => Icons.science_outlined,
    DocumentType.prescription => Icons.medication_outlined,
    DocumentType.receipt => Icons.receipt_long_outlined,
    DocumentType.discharge => Icons.description_outlined,
    DocumentType.imaging => Icons.monitor_heart_outlined,
    DocumentType.visit => Icons.event_note_outlined,
  };

  /// Icon accent.
  Color get accentColor => switch (this) {
    DocumentType.lab => AppColors.catLab,
    DocumentType.prescription => AppColors.mint,
    DocumentType.receipt => AppColors.catReceiptIcon,
    DocumentType.discharge => AppColors.catDischarge,
    DocumentType.imaging => AppColors.catImaging,
    DocumentType.visit => AppColors.catVisit,
  };

  /// Soft tile fill.
  Color get tileColor => switch (this) {
    DocumentType.lab => AppColors.catLab.withValues(alpha: 0.16),
    DocumentType.prescription => AppColors.mint.withValues(alpha: 0.16),
    DocumentType.receipt => AppColors.catReceipt.withValues(alpha: 0.18),
    DocumentType.discharge => AppColors.catDischarge.withValues(alpha: 0.16),
    DocumentType.imaging => AppColors.catImaging.withValues(alpha: 0.16),
    DocumentType.visit => AppColors.catVisit.withValues(alpha: 0.16),
  };

  /// Narrative types → Summary, not Results rows.
  bool get isSummaryShaped =>
      this == DocumentType.imaging ||
      this == DocumentType.discharge ||
      this == DocumentType.visit;

  /// Card section heading.
  String get structuredSectionLabel => switch (this) {
    DocumentType.imaging || DocumentType.discharge => 'Summary',
    DocumentType.receipt => 'Breakdown',
    _ => 'Results',
  };
}

/// One Results row (label, value, optional range).
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

/// UI document shape ([DocumentRepository] ↔ Drift).
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

  /// OCR text.
  final String extractedText;

  /// Structured Results rows.
  final List<DocumentResult> results;

  /// Footnote under Results.
  final String? resultsNote;

  /// Display rewrite of [resultsNote]; Ask uses the verbatim note.
  final String? summaryRewrite;

  /// Rewrite state: pending | retry | null.
  final String? summaryState;

  /// Free-form tags.
  final List<String> tags;

  /// Page image paths, in order.
  final List<String> pages;

  /// Imported PDF path; null for camera / legacy rows.
  final String? sourcePdfPath;

  /// First page image, or null.
  String? get primaryImage => pages.isEmpty ? null : pages.first;

  /// Copy with replaced fields.
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

  /// "Apr 12, 2025".
  String get dateLabel => '${shortDate(date)}, ${date.year}';

  /// "Apr 12" (no year).
  String get shortDateLabel => shortDate(date);
}

const _months = [
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

/// "Apr 12".
String shortDate(DateTime d) => '${_months[d.month - 1]} ${d.day}';

/// Sample docs for previews/tests (not const: DateTime).
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
