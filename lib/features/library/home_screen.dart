import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/data/providers.dart';
import '../../core/widgets/cura_bottom_nav.dart';
import '../ai/ai_providers.dart';
import '../ask/ask_screen.dart';
import '../ask/ask_prompt_rotation.dart';
import '../export/export_selection_screen.dart';
import '../pdf_import/pdf_import_service.dart';
import '../reminders/reminder_service.dart';
import '../scan/document_shape.dart';
import '../scan/review_document_screen.dart';
import '../scan/scan_service.dart';
import '../scan/summary_rewriter.dart';
import '../settings/settings_view.dart';
import '../timeline/timeline_view.dart';
import 'document.dart';
import 'document_detail_screen.dart';
import 'empty_state_view.dart';
import 'library_view.dart';
import 'manual_entry_screen.dart';

/// App shell with bottom nav and scan FAB.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.homeAskExample});

  final String homeAskExample;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  CuraTab _currentTab = CuraTab.home;
  bool _openingAsk = false;

  @override
  void initState() {
    super.initState();
    // Sweep pending summaries.
    unawaited(_sweepSummaries());
  }

  /// Queue old summaries and sweep them.
  Future<void> _sweepSummaries() async {
    final repo = ref.read(documentRepositoryProvider);
    final ids = [
      for (final d in await repo.summaryRewriteCandidates())
        if (needsSummaryRewrite(
          type: d.type,
          extractedText: d.extractedText,
          note: d.resultsNote,
        ))
          d.id,
    ];
    await repo.queuePendingSummaries(ids);
    await ref.read(summaryRewriterProvider).sweep();
  }

  Future<void> _onAdd() async {
    final action = await showModalBottomSheet<_AddDocumentAction>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.document_scanner_outlined),
                title: const Text('Scan document'),
                subtitle: const Text('Use the camera or choose page images'),
                onTap: () => Navigator.of(context).pop(_AddDocumentAction.scan),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Import PDF'),
                subtitle: const Text('Choose a PDF already on this phone'),
                onTap: () => Navigator.of(context).pop(_AddDocumentAction.pdf),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note_outlined),
                title: const Text('Add manually'),
                subtitle: const Text('Type a note; attach photos if you like'),
                onTap: () =>
                    Navigator.of(context).pop(_AddDocumentAction.manual),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _AddDocumentAction.scan:
        await _onScan();
      case _AddDocumentAction.pdf:
        await _onImportPdf();
      case _AddDocumentAction.manual:
        await _onAddManually();
      case null:
        return;
    }
  }

  // Manual entry flow.
  Future<void> _onAddManually() async {
    final doc = await Navigator.of(context).push<CuraDocument>(
      MaterialPageRoute(builder: (_) => const ManualEntryScreen()),
    );
    if (doc != null) {
      await ref.read(documentRepositoryProvider).add(doc);
    }
  }

  Future<void> _onScan() async {
    try {
      final result = await _captureAndReadScan();
      if (result == null) return;
      await _reviewNewSource(
        result,
        replacement: _captureAndReadScan,
        replaceActionLabel: 'Re-scan',
      );
    } catch (error, stack) {
      debugPrint('[Cura.scan] failed: $error\n$stack');
      if (mounted) _toast('Cura could not read that scan. Please try again.');
    }
  }

  Future<void> _onImportPdf() async {
    try {
      final result = await _pickAndReadPdf();
      if (result == null) return;
      await _reviewNewSource(
        result,
        replacement: _pickAndReadPdf,
        replaceActionLabel: 'Re-import',
      );
    } on PdfImportException catch (error) {
      if (mounted) _toast(error.message);
    } catch (error, stack) {
      debugPrint('[Cura.pdfImport] failed: $error\n$stack');
      if (mounted) _toast('Cura could not import that PDF.');
    }
  }

  Future<ScanResult?> _captureAndReadScan() async {
    final svc = ref.read(scanServiceProvider);
    final paths = await svc.captureDocument();
    if (paths.isEmpty) return null;
    try {
      return await _withProgress((update) async {
        final readout = await svc.recognizePages(
          paths,
          onProgress: (current, total) => update(
            PdfImportProgress(
              PdfImportStage.reading,
              current: current,
              total: total,
            ).label,
          ),
        );
        return ScanResult(
          paths,
          readout.text,
          results: readout.results,
          tableEvidence: readout.tableEvidence,
        );
      });
    } catch (_) {
      await svc.deleteImages(paths);
      rethrow;
    }
  }

  Future<ScanResult?> _pickAndReadPdf() async {
    final pdfService = ref.read(pdfImportServiceProvider);
    final scanService = ref.read(scanServiceProvider);
    final pending = await pdfService.pickPdf();
    if (pending == null) return null;
    try {
      return await _withProgress((update) async {
        final rendered = await pdfService.render(
          pending,
          onProgress: (progress) => update(progress.label),
        );
        final readout = await scanService.recognizePages(
          rendered.pagePaths,
          onProgress: (current, total) => update(
            PdfImportProgress(
              PdfImportStage.reading,
              current: current,
              total: total,
            ).label,
          ),
        );
        return ScanResult(
          rendered.pagePaths,
          readout.text,
          results: readout.results,
          tableEvidence: readout.tableEvidence,
          sourcePdfPath: rendered.sourcePdfPath,
        );
      });
    } catch (_) {
      await pdfService.discardPending(pending);
      rethrow;
    }
  }

  Future<void> _reviewNewSource(
    ScanResult first, {
    required Future<ScanResult?> Function() replacement,
    required String replaceActionLabel,
  }) async {
    var current = first;
    final draft = _draftFrom(current);
    final useRemote = await ref.read(remoteAiStoreProvider).remoteActive();
    // Start scan refinement.
    final refinement = ref
        .read(aiServiceProvider)
        .startDocumentRefinement(
          current.text,
          draftType: draft.type,
          useRemote: useRemote,
          title: draft.title,
          tableEvidence: current.tableEvidence,
          deterministicResults: current.results,
        );
    if (!mounted) {
      await _discardSource(current);
      return;
    }

    final doc = await Navigator.of(context).push<CuraDocument>(
      MaterialPageRoute(
        builder: (_) => ReviewDocumentScreen(
          draft: draft,
          refinement: refinement,
          replaceActionLabel: replaceActionLabel,
          onRescan: () async {
            try {
              final next = await replacement();
              if (next != null) current = next;
              return next;
            } on PdfImportException catch (error) {
              if (mounted) _toast(error.message);
              return null;
            } catch (error, stack) {
              debugPrint('[Cura.import] replacement failed: $error\n$stack');
              if (mounted) _toast('Cura could not read that document.');
              return null;
            }
          },
        ),
      ),
    );
    if (doc != null) {
      // Queue a readable rewrite when needed.
      final queued =
          needsSummaryRewrite(
            type: doc.type,
            extractedText: doc.extractedText,
            note: doc.resultsNote,
            deterministicNote: draft.resultsNote,
          ) &&
          (await ref.read(remoteAiStoreProvider).remoteActive() ||
              await ref.read(aiModelManagerProvider).installedModel() != null);
      final saved = queued ? doc.copyWith(summaryState: kSummaryPending) : doc;
      await ref.read(documentRepositoryProvider).add(saved);
      if (queued) unawaited(ref.read(summaryRewriterProvider).sweep());
      // Point to the saved record for reminders.
      if (mounted &&
          saved.type == DocumentType.prescription &&
          saved.results.isNotEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: const Text(
                'Saved. Set reminders on any medicine, or from the bell on '
                'Home.',
              ),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 6),
              action: SnackBarAction(
                label: 'Open',
                onPressed: () => _openDocument(saved),
              ),
            ),
          );
      }
    } else {
      await _discardSource(current);
    }
  }

  CuraDocument _draftFrom(ScanResult result) {
    final svc = ref.read(scanServiceProvider);
    final type = svc.detectType(result.text);
    final summaryShaped = isSummaryDocument(type, result.text);
    // Handle prescriptions and receipts separately.
    final List<DocumentResult> results;
    final String? resultsNote;
    if (type == DocumentType.prescription) {
      final rx = svc.parsePrescription(result.text);
      results = rx.medicines;
      resultsNote = rx.summary;
    } else {
      results = summaryShaped ? const <DocumentResult>[] : result.results;
      resultsNote = type == DocumentType.receipt
          ? null
          : summaryShaped
          ? svc.extractFindingsSummary(result.text)
          : (results.isNotEmpty
                ? svc.summarize(results, type: type)
                : svc.extractFindingsSummary(result.text));
    }
    return CuraDocument(
      id:
          '${result.sourcePdfPath == null ? 'scan' : 'pdf'}-'
          '${DateTime.now().microsecondsSinceEpoch}',
      title: svc.detectTitle(result.text),
      type: type,
      date: svc.extractDate(result.text) ?? DateTime.now(),
      extractedText: result.text,
      results: results,
      resultsNote: resultsNote,
      pages: result.imagePaths,
      sourcePdfPath: result.sourcePdfPath,
    );
  }

  Future<void> _discardSource(ScanResult result) async {
    if (result.sourcePdfPath != null) {
      await ref
          .read(pdfImportServiceProvider)
          .deleteImportedPdf(result.sourcePdfPath);
    } else {
      await ref.read(scanServiceProvider).deleteImages(result.imagePaths);
    }
  }

  Future<T> _withProgress<T>(
    Future<T> Function(ValueChanged<String> update) task,
  ) async {
    final message = ValueNotifier<String>('Reading document…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Card(
          color: AppColors.surface,
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 16),
                ValueListenableBuilder<String>(
                  valueListenable: message,
                  builder: (_, value, _) => Text(
                    value,
                    style: const TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      fontSize: 15,
                      color: AppColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      return await task((value) => message.value = value);
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      message.dispose();
    }
  }

  void _openDocument(CuraDocument doc) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DocumentDetailScreen(
          document: doc,
          onUpdate: _updateDocument,
          onDelete: _deleteDocument,
        ),
      ),
    );
  }

  void _updateDocument(CuraDocument doc) {
    ref.read(documentRepositoryProvider).update(doc);
  }

  Future<void> _deleteDocument(CuraDocument doc) async {
    await ref.read(documentRepositoryProvider).delete(doc.id);
    // Clear reminders with the doc.
    final reminders = ref.read(reminderRepositoryProvider);
    await reminders.deleteForDocument(doc.id);
    await ref.read(reminderServiceProvider).sync(await reminders.all());
    if (doc.sourcePdfPath != null) {
      await ref
          .read(pdfImportServiceProvider)
          .deleteImportedPdf(doc.sourcePdfPath);
    } else {
      await ref.read(scanServiceProvider).deleteImages(doc.pages);
    }
  }

  void _onSelectTab(CuraTab tab) {
    // Ask opens full-screen.
    if (tab == CuraTab.ask) {
      _openAsk();
      return;
    }
    setState(() => _currentTab = tab);
  }

  Future<void> _openAsk() async {
    // Guard against double taps.
    if (_openingAsk) return;
    _openingAsk = true;
    try {
      final prompts = await askPromptRotation.takeNextAskSet();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AskScreen(
            prompts: prompts,
            onOpenDocument: _openDocument,
            onOpenSettings: () =>
                setState(() => _currentTab = CuraTab.settings),
          ),
        ),
      );
    } finally {
      _openingAsk = false;
    }
  }

  // Export all data flow.
  void _openExport() {
    final current = ref.read(documentsProvider).value ?? const [];
    if (current.isEmpty) {
      _toast('No documents to export');
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ExportSelectionScreen()));
  }

  Future<void> _deleteAllDocuments() async {
    final current = ref.read(documentsProvider).value ?? const [];
    if (current.isEmpty) {
      _toast('No documents to delete');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all data?'),
        content: const Text(
          'Every document will be removed from this device. This can\'t be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(documentRepositoryProvider).deleteAll();
      await ref.read(reminderRepositoryProvider).deleteAll();
      await ref.read(reminderServiceProvider).sync(const []);
      await ref.read(scanServiceProvider).deleteAllImages();
      await ref.read(pdfImportServiceProvider).deleteAllImports();
      // Wipe the cloud key too.
      await ref.read(remoteAiStoreProvider).clear();
      ref.invalidate(aiServiceProvider);
      ref.invalidate(activeEngineProvider);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  // Confirm exit on Home back.
  Future<bool> _confirmQuit() async {
    final quit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quit Cura?'),
        content: const Text('Do you want to close the app?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
    return quit ?? false;
  }

  @override
  Widget build(BuildContext context) {
    // Show empty state while DB opens.
    final documents = ref
        .watch(documentsProvider)
        .maybeWhen(data: (d) => d, orElse: () => const <CuraDocument>[]);

    return PopScope(
      // Intercept back at the shell.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_currentTab != CuraTab.home) {
          setState(() => _currentTab = CuraTab.home);
          return;
        }
        if (await _confirmQuit()) SystemNavigator.pop();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: AppColors.surface,
        ),
        child: Scaffold(
          body: SafeArea(
            bottom: false,
            child: IndexedStack(
              index: _currentTab.index,
              children: [
                // Home.
                documents.isEmpty
                    ? EmptyStateView(onAdd: _onAdd)
                    : LibraryView(
                        documents: documents,
                        homeAskExample: widget.homeAskExample,
                        onOpenDocument: _openDocument,
                        onOpenAsk: _openAsk,
                      ),
                // Timeline.
                TimelineView(
                  documents: documents,
                  onOpenDocument: _openDocument,
                ),
                // Ask slot — never shown (Ask opens as a pushed screen).
                const SizedBox.shrink(),
                // Settings.
                SettingsView(
                  onExport: _openExport,
                  onDeleteAll: _deleteAllDocuments,
                ),
              ],
            ),
          ),
          bottomNavigationBar: CuraBottomNavBar(
            current: _currentTab,
            onSelect: _onSelectTab,
          ),
          floatingActionButton: CuraAddFab(onPressed: _onAdd),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerDocked,
        ),
      ),
    );
  }
}

enum _AddDocumentAction { scan, pdf, manual }
