import 'package:flutter/foundation.dart';

import '../../library/document.dart';
import 'clinical_vocabulary.dart';
import 'pii_redactor.dart';

/// Above this fraction of unknown (non-clinical) tokens, a narrative block is
/// dropped to structured facts only. The capitalisation-blind backstop for OCR
/// the name-run rule cannot reason about.
const kUnknownRatioFallbackThreshold = 0.6;

/// The ratio fallback only fires with enough tokens to be meaningful; a short
/// impression with one odd word must not be discarded.
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

/// Content-free diagnostics for one local sanitization pass.
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

  /// Narrative blocks dropped to structured-facts-only because their unknown
  /// token ratio was too high.
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

/// The single factory for user- and document-derived cloud messages. Document
/// text is minimized and line-scrubbed; the user's own words get targeted span
/// removal instead, so ordinary conversational language survives.
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

  /// Middle policy for prior assistant turns, which are cased prose that can
  /// quote report text: span scrubs, then per-line name-run deletion and a
  /// hard-risk drop. No whole-line drop on org words, which would erase benign
  /// answers and break the antecedents a follow-up relies on.
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

  /// Union of exact identities and quasi-identifiers read from every local
  /// record. Ask applies this union to every document and history message, so an
  /// identifier learned from one record cannot survive in another record's note.
  Set<String> identityTermsForDocuments(List<CuraDocument> docs) => {
    for (final document in docs) ...identityTermsFor(document.extractedText),
  };

  /// Final, idempotent transform used by the HTTP serializer. This deliberately
  /// does not trust an earlier caller-side pass: the literal string that will be
  /// encoded is scrubbed again according to its declared origin.
  String sanitizeAtOutboundBoundary(CloudSafeMessage message) =>
      switch (message.origin) {
        CloudMessageOrigin.developerLiteral => message.content,
        CloudMessageOrigin.userAuthored =>
          redactConversationForCloud(message.content),
        CloudMessageOrigin.documentDerived =>
          _sanitizeDocumentText(message.content),
      };

  /// Scrubs cloud output before it can be displayed or persisted as chat
  /// history. This removes exact local identities even if the model inferred or
  /// reconstructed them instead of copying them from the prompt.
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

  /// Safe inventory for count/list/latest queries. A stored title is kept only
  /// when every token is clinical, else a canonical type title is used. Each line
  /// carries a scrubbed hint (see [_inventoryHint]) so topical questions are
  /// answered from real content rather than guessed from titles.
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

  /// Max characters of the findings hint appended to each inventory line. Short
  /// so the enriched inventory stays a small prefill even with many records,
  /// while still carrying enough signal to answer topical questions.
  static const _kInventoryHintChars = 100;

  /// One scrubbed line describing what a report is about: the stored impression,
  /// else the first result rows, else a medical excerpt. Empty when nothing safe
  /// survives the same scrubs as the rest of the cloud payload.
  String _inventoryHint(CuraDocument d, Set<String> identity) {
    final title = safeTitle(d);
    // 1) A stored note / impression (imaging, discharge, histopath, or any doc).
    final note = d.resultsNote?.trim() ?? '';
    if (note.isNotEmpty) {
      final safe = _safeField(
        _preferMedicalLines(note, title).replaceAll('\n', ' '),
        identity,
      );
      if (safe.isNotEmpty) return _clipHint(safe);
    }
    // 2) Structured result rows → "Label: value" for the first few.
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
    // 3) A medical excerpt (letterhead / patient block already dropped).
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

      // The stored summary takes the same medical-line allowlist as raw OCR,
      // since it is built from the page and can carry letterhead the scanner
      // swept up. A note with no clinical signal at all (a receipt purpose, a
      // typed visit note) keeps the plain scrub instead of being erased.
      final note = d.resultsNote == null
          ? const CloudSafeText('', CloudPrivacyStats())
          : _safeNarrative(
              _preferMedicalLines(d.resultsNote!, title),
              identity: identity,
            );
      if (note.text.isNotEmpty) out.writeln('Notes: ${note.text}');
      stats = stats + note.stats;

      // Raw OCR is the last resort, not an addition. Where a note or a results
      // table already carries the medical content, the page text only repeats it
      // with the letterhead, footers and patient block attached.
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
    // Log-only: scan narrative is never dropped on a high unknown ratio, since
    // parseScanExtraction re-validates every returned value anyway.
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
    // A vendor/facility name is correlatable health information too. Receipt
    // titles are therefore canonicalized instead of being sent verbatim.
    if (document.type == DocumentType.receipt) {
      return _canonicalTitle(document);
    }
    if (_isTitleSafeToSend(title)) return title;
    return _canonicalTitle(document);
  }

  /// One results row as `label: value (range)`, or empty when the row is
  /// identity rather than a finding.
  ///
  /// The row is scrubbed as a whole rather than cell by cell. A table parser
  /// splits `Date of birth : 01/01/1990` into two strings, discarding the
  /// separator that [containsHardCloudRisk] and the whole-line rules key on, so
  /// a cell-by-cell scrub can never recognise a demographic row.
  String _safeRow(DocumentResult result, Set<String> identity) {
    if (isIdentityRowLabel(result.label)) return '';
    final label = _safeField(result.label, identity);
    final value = _safeField(result.value, identity);
    if (label.isEmpty || value.isEmpty) return '';
    final unit = result.unit == null
        ? ''
        : _safeField(result.unit!, identity);
    final range = result.range == null
        ? ''
        : _safeField(result.range!, identity);
    final measured = unit.isEmpty ? value : '$value $unit';
    final row = '$label: $measured${range.isEmpty ? '' : ' ($range)'}';
    // Age and sex survive the assembled-row check by design; both cells were
    // already scrubbed above.
    if (isKeptDemographicRowLabel(result.label)) {
      return containsHardCloudRisk(measured) ? '' : row;
    }
    // Re-check the assembled row: the restored separator is what lets the
    // labelled-identity rules fire.
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

  /// The medical-line allowlist applied to [source], or [source] unchanged when
  /// the allowlist keeps nothing. A clinical summary is minimized; a note that
  /// is not clinical prose at all still gets the ordinary scrub.
  String _preferMedicalLines(String source, String title) {
    final minimized = keepMedicalLines(source, title: title);
    return minimized.trim().isEmpty ? source : minimized;
  }

  /// Sanitizes document narrative line by line: line/inline scrubs, name-run
  /// deletion, then with [dropOnHighRatio] a whole-block fallback to structured
  /// facts when too much of what survives is non-clinical. Scan refinement
  /// passes it `false`, since parseScanExtraction re-validates anyway.
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
      var scrubbed = redactForCloud(
        stripKnownIdentity(line, identity),
      ).trim();
      if (scrubbed.isEmpty || containsHardCloudRisk(scrubbed)) continue;
      // Delete bare name-shaped runs riding on the kept medical line.
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

// A few title-specific tokens that make a *single-word* title safe on their own
// (a lone unknown Title-case word could be a surname; a lone known term is not).
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

/// A stored title goes verbatim unless it carries identity: a person-name shape,
/// a place, an organisation, a record id, or a patient label. Detecting the
/// finite set of PII shapes beats allowlisting every legitimate medical title.
bool _isTitleSafeToSend(String title) {
  final t = title.trim();
  if (t.isEmpty) return false;
  // Identifiers / phone / email / patient-id labels.
  if (containsHardCloudRisk(t)) return false;
  // Person-name run ("Amber Brown", "Grace Quinn").
  if (deleteNameRuns(t).runs > 0) return false;
  // Organisation / address / place / patient-context words.
  if (containsIdentityContext(t)) return false;
  // A single Title-case unknown word could be a bare surname, so one-word titles
  // need a recognised anchor: acronyms and known clinical terms pass.
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
  // Title first, then the excerpt: an equal match in the title outranks one in
  // the body, so "MRI brain, compared with prior CT" stays MRI, not CT.
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
  // Lowest match index wins (title text precedes the excerpt).
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

/// First anatomy word in [lower], or null, so canonical imaging titles stay
/// distinguishable ("Ultrasound — abdomen" vs "Ultrasound — neck").
String? _firstAnatomyTerm(String lower) {
  for (final m in RegExp(r'[a-z]+').allMatches(lower)) {
    if (kAnatomyTerms.contains(m.group(0))) return m.group(0);
  }
  return null;
}
