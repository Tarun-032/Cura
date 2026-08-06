import 'package:flutter/foundation.dart';

import '../../library/document.dart';
import 'clinical_vocabulary.dart';
import 'pii_redactor.dart';

/// Unknown-token cutoff for narrative fallback.
const kUnknownRatioFallbackThreshold = 0.6;

/// Needs enough tokens to matter.
const kMinTokensForRatioFallback = 8;

/// Origin of a message accepted by the remote HTTP boundary.
enum CloudMessageOrigin { developerLiteral, userAuthored, documentDerived }

/// A string approved for cloud transmission. The private constructor is the
/// point: ordinary strings cannot cross the HTTP boundary. User and document
/// content must come from [CloudPrivacyGate]; developer prompts are const.
@immutable
class CloudSafeMessage {
  const CloudSafeMessage._(this.role, this.content, this.origin);

  const CloudSafeMessage.developerLiteral({
    required String role,
    required String content,
  }) : this._(role, content, CloudMessageOrigin.developerLiteral);

  final String role;
  final String content;
  final CloudMessageOrigin origin;
}

/// Stats for one sanitization pass.
@immutable
class CloudPrivacyStats {
  const CloudPrivacyStats({
    this.candidateLines = 0,
    this.keptLines = 0,
    this.droppedLines = 0,
    this.titlesReplaced = 0,
    this.fieldsDropped = 0,
    this.totalTokens = 0,
    this.unknownTokens = 0,
    this.nameRunsDeleted = 0,
    this.narrativeFallbacks = 0,
  });

  final int candidateLines;
  final int keptLines;
  final int droppedLines;
  final int titlesReplaced;
  final int fieldsDropped;
  final int totalTokens;
  final int unknownTokens;

  /// Name-shaped runs deleted from kept clinical lines.
  final int nameRunsDeleted;

  /// Narrative blocks dropped by the ratio check.
  final int narrativeFallbacks;

  double get unknownTokenRatio =>
      totalTokens == 0 ? 0 : unknownTokens / totalTokens;

  CloudPrivacyStats operator +(CloudPrivacyStats other) => CloudPrivacyStats(
    candidateLines: candidateLines + other.candidateLines,
    keptLines: keptLines + other.keptLines,
    droppedLines: droppedLines + other.droppedLines,
    titlesReplaced: titlesReplaced + other.titlesReplaced,
    fieldsDropped: fieldsDropped + other.fieldsDropped,
    totalTokens: totalTokens + other.totalTokens,
    unknownTokens: unknownTokens + other.unknownTokens,
    nameRunsDeleted: nameRunsDeleted + other.nameRunsDeleted,
    narrativeFallbacks: narrativeFallbacks + other.narrativeFallbacks,
  );
}

@immutable
class CloudSafeText {
  const CloudSafeText(this.text, this.stats);
  final String text;
  final CloudPrivacyStats stats;
}

/// Builds cloud-safe messages.
class CloudPrivacyGate {
  const CloudPrivacyGate();

  CloudSafeMessage userMessage(
    String text, {
    String role = 'user',
    Set<String> knownIdentityTerms = const {},
  }) {
    final safe = redactConversationForCloud(
      stripKnownIdentity(text, knownIdentityTerms),
    );
    return CloudSafeMessage._(role, safe, CloudMessageOrigin.userAuthored);
  }

  CloudSafeMessage documentMessage(
    String text, {
    String role = 'user',
    Set<String> knownIdentityTerms = const {},
  }) {
    final safe = _sanitizeDocumentText(
      stripKnownIdentity(text, knownIdentityTerms),
    );
    return CloudSafeMessage._(role, safe, CloudMessageOrigin.documentDerived);
  }

  /// Scrub assistant replies in place.
  CloudSafeMessage assistantMessage(
    String text, {
    String role = 'assistant',
    Set<String> knownIdentityTerms = const {},
  }) {
    final scrubbed = redactConversationForCloud(
      stripKnownIdentity(text, knownIdentityTerms),
    );
    final kept = <String>[];
    for (final raw in scrubbed.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      line = deleteNameRuns(line).text.trim();
      if (line.isEmpty || containsHardCloudRisk(line)) continue;
      kept.add(line);
    }
    return CloudSafeMessage._(
      role,
      kept.join('\n'),
      CloudMessageOrigin.userAuthored,
    );
  }

  /// Collect identity terms from all docs.
  Set<String> identityTermsForDocuments(List<CuraDocument> docs) => {
    for (final document in docs) ...identityTermsFor(document.extractedText),
  };

  /// Final outbound scrub.
  String sanitizeAtOutboundBoundary(CloudSafeMessage message) =>
      switch (message.origin) {
        CloudMessageOrigin.developerLiteral => message.content,
        CloudMessageOrigin.userAuthored => redactConversationForCloud(
          message.content,
        ),
        CloudMessageOrigin.documentDerived => _sanitizeDocumentText(
          message.content,
        ),
      };

  /// Scrub cloud output before display.
  String responseText(
    String text, {
    Set<String> knownIdentityTerms = const {},
  }) {
    final scrubbed = redactConversationForCloud(
      stripKnownIdentity(text, knownIdentityTerms),
    );
    final kept = <String>[];
    for (final raw in scrubbed.split('\n')) {
      final line = _sanitizeDocumentText(raw).trim();
      if (line.isNotEmpty && !containsHardCloudRisk(line)) kept.add(line);
    }
    return kept.join('\n').trim();
  }

  String _sanitizeDocumentText(String text) {
    final kept = <String>[];
    for (final raw in redactForCloud(text).split('\n')) {
      final line = deleteNameRuns(raw).text.trim();
      if (line.isNotEmpty && !containsHardCloudRisk(line)) kept.add(line);
    }
    return kept.join('\n');
  }

  /// Build a safe record inventory.
  CloudSafeText buildInventory(List<CuraDocument> docs) {
    final ordered = [...docs]..sort((a, b) => b.date.compareTo(a.date));
    final identity = identityTermsForDocuments(ordered);
    final out = StringBuffer(
      'Complete record inventory (${ordered.length} total records):\n',
    );
    var stats = const CloudPrivacyStats();
    for (var i = 0; i < ordered.length; i++) {
      final d = ordered[i];
      final title = safeTitle(d);
      if (title != d.title.trim()) {
        stats = stats + const CloudPrivacyStats(titlesReplaced: 1);
      }
      final hint = _inventoryHint(d, identity);
      final base = '[${i + 1}] $title — ${d.type.label} — ${d.dateLabel}';
      out.writeln(hint.isEmpty ? base : '$base — $hint');
    }
    return CloudSafeText(out.toString().trimRight(), stats);
  }

  /// Max hint length per inventory line.
  static const _kInventoryHintChars = 160;

  /// One scrubbed line describing what a report is about: the result rows, else
  /// the stored impression, else a medical excerpt. Empty when nothing safe
  /// survives the same scrubs as the rest of the cloud payload.
  String _inventoryHint(CuraDocument d, Set<String> identity) {
    final title = safeTitle(d);
    // Prefer structured result rows.
    if (d.results.isNotEmpty) {
      final rows = <String>[];
      for (final r in d.results) {
        if (r.needsReview) continue;
        final row = _safeRow(r, identity);
        if (row.isEmpty) continue;
        rows.add(row);
        if (rows.length >= 4) break;
      }
      if (rows.isNotEmpty) return _clipHint(rows.join('; '));
    }
    // Then use the stored note.
    final note = d.resultsNote?.trim() ?? '';
    if (note.isNotEmpty) {
      final safe = _safeField(
        _preferMedicalLines(note, title).replaceAll('\n', ' '),
        identity,
      );
      if (safe.isNotEmpty) return _clipHint(safe);
    }
    // Then use a medical excerpt.
    final excerpt = _safeField(
      keepMedicalLines(d.extractedText, title: title).replaceAll('\n', ' '),
      identity,
    );
    if (excerpt.isNotEmpty) return _clipHint(excerpt);
    return '';
  }

  String _clipHint(String s) {
    final t = s.trim();
    if (t.length <= _kInventoryHintChars) return t;
    return '${t.substring(0, _kInventoryHintChars).trimRight()}…';
  }

  CloudSafeText buildContext(List<CuraDocument> docs) {
    final out = StringBuffer();
    var stats = const CloudPrivacyStats();
    final identity = identityTermsForDocuments(docs);
    for (var i = 0; i < docs.length; i++) {
      final d = docs[i];
      final title = safeTitle(d);
      if (title != d.title.trim()) {
        stats = stats + const CloudPrivacyStats(titlesReplaced: 1);
      }
      out.writeln('[${i + 1}] $title — ${d.type.label} — ${d.dateLabel}');

      if (d.results.isNotEmpty) {
        final rows = <String>[];
        for (final result in d.results) {
          final row = _safeRow(result, identity);
          if (row.isEmpty) {
            stats = stats + const CloudPrivacyStats(fieldsDropped: 1);
            continue;
          }
          rows.add(row);
        }
        if (rows.isNotEmpty) out.writeln('Results: ${rows.join('; ')}');
      }

      // Keep the same allowlist as raw OCR.
      final note = d.resultsNote == null
          ? const CloudSafeText('', CloudPrivacyStats())
          : _safeNarrative(
              _preferMedicalLines(d.resultsNote!, title),
              identity: identity,
            );
      if (note.text.isNotEmpty) out.writeln('Notes: ${note.text}');
      stats = stats + note.stats;

      // Raw OCR is the last resort.
      if (d.results.isEmpty && note.text.isEmpty) {
        final narrative = _safeNarrative(
          keepMedicalLines(d.extractedText, title: title),
          identity: identity,
        );
        if (narrative.text.isNotEmpty) out.writeln('Text: ${narrative.text}');
        stats = stats + narrative.stats;
      }
      out.writeln();
    }
    final text = out.toString().trim();
    debugPrint(
      '[Cura.privacy] context docs=${docs.length} '
      'lines=${stats.keptLines}/${stats.candidateLines} '
      'dropped=${stats.droppedLines} fieldsDropped=${stats.fieldsDropped} '
      'titlesReplaced=${stats.titlesReplaced} '
      'nameRuns=${stats.nameRunsDeleted} '
      'narrativeFallbacks=${stats.narrativeFallbacks} '
      'unknownRatio=${stats.unknownTokenRatio.toStringAsFixed(2)} '
      'vocab=$kClinicalVocabularyVersion',
    );
    return CloudSafeText(text, stats);
  }

  /// Cloud scan refinement takes the same minimized policy as Ask. Bills use the
  /// bill allowlist instead, since the medical-line selector rejects fees, totals
  /// and GST, and a starved payload makes the model invent a lab title.
  CloudSafeText scanText(String ocr, {String? title, DocumentType? type}) {
    if (type == DocumentType.receipt) {
      final candidates = ocr
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .length;
      final safe = billCloudText(ocr);
      final kept = safe.isEmpty ? 0 : safe.split('\n').length;
      return CloudSafeText(
        safe,
        CloudPrivacyStats(
          candidateLines: candidates,
          keptLines: kept,
          droppedLines: candidates - kept,
        ),
      );
    }
    final minimized = keepMedicalLines(ocr, title: title);
    // Scan narrative never drops on ratio alone.
    return _safeNarrative(
      minimized,
      dropOnHighRatio: false,
      identity: identityTermsFor(ocr),
    );
  }

  /// Sanitizes geometry-derived table evidence without the medical-line
  /// selector, which cannot know an uncommon test name or unit and would break
  /// row alignment. All PII scrubs still apply; this relaxes recall only.
  CloudSafeText tableText(String serializedGrid) {
    if (serializedGrid.trim().isEmpty) {
      return const CloudSafeText('', CloudPrivacyStats());
    }
    final identity = identityTermsFor(serializedGrid);
    final candidates = serializedGrid
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final kept = <String>[];
    var nameRuns = 0;
    for (final raw in candidates) {
      var line = redactForCloud(stripKnownIdentity(raw, identity)).trim();
      if (line.isEmpty || containsHardCloudRisk(line)) continue;
      final deleted = deleteNameRuns(line);
      nameRuns += deleted.runs;
      line = deleted.text.trim();
      if (line.isEmpty || containsHardCloudRisk(line)) continue;
      kept.add(line);
    }
    return CloudSafeText(
      kept.join('\n'),
      CloudPrivacyStats(
        candidateLines: candidates.length,
        keptLines: kept.length,
        droppedLines: candidates.length - kept.length,
        nameRunsDeleted: nameRuns,
      ),
    );
  }

  String safeTitle(CuraDocument document) {
    final title = document.title.trim();
    // Canonicalize receipt titles.
    if (document.type == DocumentType.receipt) {
      return _canonicalTitle(document);
    }
    if (_isTitleSafeToSend(title)) return title;
    return _canonicalTitle(document);
  }

  /// One results row as `label: value (range)`.
  String _safeRow(DocumentResult result, Set<String> identity) {
    if (isIdentityRowLabel(result.label)) return '';
    final label = _safeField(result.label, identity);
    final value = _safeField(result.value, identity);
    if (label.isEmpty || value.isEmpty) return '';
    final unit = result.unit == null ? '' : _safeField(result.unit!, identity);
    final range = result.range == null
        ? ''
        : _safeField(result.range!, identity);
    final measured = unit.isEmpty ? value : '$value $unit';
    final row = '$label: $measured${range.isEmpty ? '' : ' ($range)'}';
    // Keep age and sex rows by design.
    if (isKeptDemographicRowLabel(result.label)) {
      return containsHardCloudRisk(measured) ? '' : row;
    }
    // Re-check the assembled row.
    final safe = _safeField(row, identity);
    return safe == row ? row : '';
  }

  String _safeField(String source, [Set<String> identity = const {}]) {
    final safe = redactForCloud(stripKnownIdentity(source, identity)).trim();
    if (safe.isEmpty || containsHardCloudRisk(safe)) return '';
    final deleted = deleteNameRuns(safe).text.trim();
    if (deleted.isEmpty || containsHardCloudRisk(deleted)) return '';
    return deleted;
  }

  /// Apply the medical-line allowlist.
  String _preferMedicalLines(String source, String title) {
    final minimized = keepMedicalLines(source, title: title);
    return minimized.trim().isEmpty ? source : minimized;
  }

  /// Scrub narrative line by line.
  CloudSafeText _safeNarrative(
    String source, {
    bool dropOnHighRatio = true,
    Set<String> identity = const {},
  }) {
    if (source.trim().isEmpty) {
      return const CloudSafeText('', CloudPrivacyStats());
    }
    final candidates = source
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final kept = <String>[];
    var totalTokens = 0;
    var unknownTokens = 0;
    var nameRuns = 0;
    for (final line in candidates) {
      var scrubbed = redactForCloud(stripKnownIdentity(line, identity)).trim();
      if (scrubbed.isEmpty || containsHardCloudRisk(scrubbed)) continue;
      // Drop bare name runs.
      final deleted = deleteNameRuns(scrubbed);
      nameRuns += deleted.runs;
      scrubbed = deleted.text.trim();
      if (scrubbed.isEmpty || containsHardCloudRisk(scrubbed)) continue;
      kept.add(scrubbed);
      for (final token
          in scrubbed
              .toLowerCase()
              .split(RegExp(r'[^a-z]+'))
              .where((token) => token.isNotEmpty)) {
        totalTokens++;
        if (!isKnownClinicalToken(token)) unknownTokens++;
      }
    }
    final ratio = totalTokens == 0 ? 0.0 : unknownTokens / totalTokens;
    final fallback =
        dropOnHighRatio &&
        totalTokens >= kMinTokensForRatioFallback &&
        ratio > kUnknownRatioFallbackThreshold;
    return CloudSafeText(
      fallback ? '' : kept.join('\n'),
      CloudPrivacyStats(
        candidateLines: candidates.length,
        keptLines: fallback ? 0 : kept.length,
        droppedLines: candidates.length - (fallback ? 0 : kept.length),
        totalTokens: totalTokens,
        unknownTokens: unknownTokens,
        nameRunsDeleted: nameRuns,
        narrativeFallbacks: fallback ? 1 : 0,
      ),
    );
  }
}

// Single-word safe title tokens.
const _safeTitleTokens = <String>{
  'cbc',
  'ct',
  'ecg',
  'eeg',
  'echo',
  'lab',
  'mri',
  'pet',
  'scan',
  'test',
  'usg',
  'xray',
  'ultrasound',
  'mammogram',
  'prescription',
  'receipt',
  'report',
};

/// Keep titles unless they look like identity.
bool _isTitleSafeToSend(String title) {
  final t = title.trim();
  if (t.isEmpty) return false;
  // Hard identifiers.
  if (containsHardCloudRisk(t)) return false;
  // Person-name runs.
  if (deleteNameRuns(t).runs > 0) return false;
  // Org, place, and patient-context words.
  if (containsIdentityContext(t)) return false;
  // One-word titles need a known anchor.
  final words = RegExp(
    r"[A-Za-z][A-Za-z'’-]*",
  ).allMatches(t).map((m) => m.group(0)!).toList();
  if (words.length == 1) {
    final w = words.first;
    final isAcronym = w.length >= 2 && w == w.toUpperCase();
    final lower = w.toLowerCase();
    final known =
        isKnownClinicalToken(lower) ||
        kAnatomyTerms.contains(lower) ||
        _safeTitleTokens.contains(lower);
    if (!isAcronym && !known) return false;
  }
  return true;
}

String _canonicalTitle(CuraDocument d) => switch (d.type) {
  DocumentType.lab => 'Laboratory report',
  DocumentType.prescription => 'Prescription',
  DocumentType.receipt => 'Receipt',
  DocumentType.discharge => 'Discharge summary',
  DocumentType.imaging => _canonicalImagingTitle(d),
  DocumentType.visit => 'Visit note',
};

String _canonicalImagingTitle(CuraDocument d) {
  final end = d.extractedText.length > 300 ? 300 : d.extractedText.length;
  // Title match outranks body match.
  final lower = '${d.title} ${d.extractedText.substring(0, end)}'.toLowerCase();
  const modalities = <(String, String)>[
    ('ultrasound', 'Ultrasound'),
    ('usg', 'Ultrasound'),
    ('sonograph', 'Ultrasound'),
    ('doppler', 'Doppler ultrasound'),
    ('pet-ct', 'PET-CT scan'),
    ('pet ct', 'PET-CT scan'),
    ('mri', 'MRI scan'),
    ('magnetic resonance', 'MRI scan'),
    ('ct scan', 'CT scan'),
    ('cect', 'CT scan'),
    ('ncct', 'CT scan'),
    ('computed tomography', 'CT scan'),
    ('x-ray', 'X-ray'),
    ('xray', 'X-ray'),
    ('mammogra', 'Mammogram'),
    ('echocardiogra', 'Echocardiogram'),
  ];
  // Earliest match wins.
  var bestIndex = 1 << 30;
  String? label;
  for (final (alias, name) in modalities) {
    final idx = lower.indexOf(alias);
    if (idx >= 0 && idx < bestIndex) {
      bestIndex = idx;
      label = name;
    }
  }
  if (label == null) return 'Imaging report';
  final anatomy = _firstAnatomyTerm(lower);
  return anatomy == null ? label : '$label — $anatomy';
}

/// First anatomy word in [lower].
String? _firstAnatomyTerm(String lower) {
  for (final m in RegExp(r'[a-z]+').allMatches(lower)) {
    if (kAnatomyTerms.contains(m.group(0))) return m.group(0);
  }
  return null;
}
