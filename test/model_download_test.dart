import 'package:background_downloader/background_downloader.dart';
import 'package:cura/features/ai/ai_models.dart';
import 'package:cura/features/ai/ai_providers.dart';
import 'package:cura/features/ai/model_download.dart';
import 'package:cura/features/ai/widgets/model_download_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ModelDownload _download({
  String name = 'Qwen3 (1.7B)',
  String fileName = 'Qwen_Qwen3-1.7B-Q4_K_M.gguf',
  int percent = 42,
  String? error,
}) => ModelDownload(
  name: name,
  fileName: fileName,
  taskId: 'task-$fileName',
  percent: percent,
  error: error,
);

void main() {
  group('percentOf', () {
    test('scales a fraction to whole percent', () {
      expect(percentOf(0), 0);
      expect(percentOf(0.456), 46);
      expect(percentOf(0.5), 50);
      expect(percentOf(1), 100);
    });

    test('never turns a status sentinel into a percentage', () {
      // Scaling these would put the bar at -100% and never leave "downloading".
      for (final sentinel in [
        progressFailed,
        progressCanceled,
        progressNotFound,
        progressWaitingToRetry,
        progressPaused,
      ]) {
        expect(sentinel < 0, isTrue, reason: 'guarding the assumption');
        expect(percentOf(sentinel), 0, reason: '$sentinel');
      }
    });

    test('clamps anything past the ends', () {
      expect(percentOf(1.5), 100);
    });
  });

  // Completion and the row's downloading check both match on file name.
  group('aiModelByFileName', () {
    test('finds the catalog entry a finished download refers to', () {
      for (final model in kAiModelCatalog) {
        expect(aiModelByFileName(model.fileName)?.id, model.id);
      }
    });

    test('every catalog file name is distinct', () {
      expect(
        kAiModelCatalog.map((m) => m.fileName).toSet(),
        hasLength(kAiModelCatalog.length),
      );
    });

    test('is null for anything else', () {
      expect(aiModelByFileName(null), isNull);
      // The voice model shares the downloader and must light up no row.
      expect(aiModelByFileName('ggml-base.en-q5_1.bin'), isNull);
    });
  });

  // Sharing one slot made the voice step show the LLM's progress, then finish
  // itself when the LLM landed and skip the user past it.
  group('a download is only visible to its own kind', () {
    Future<ProviderContainer> containerWith(
      Map<String, ModelDownload> downloads,
    ) async {
      final container = ProviderContainer(
        overrides: [
          modelDownloadsProvider.overrideWith((ref) => Stream.value(downloads)),
        ],
      );
      addTearDown(container.dispose);
      // Without a listener the provider is torn down before its first value.
      final sub = container.listen(modelDownloadsProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(modelDownloadsProvider.future);
      return container;
    }

    test('an LLM download is invisible to the voice screen', () async {
      final container = await containerWith({kLlmDownload: _download()});

      expect(container.read(llmDownloadProvider)?.percent, 42);
      expect(container.read(voiceDownloadProvider), isNull);
    });

    test('a voice download is invisible to the model rows', () async {
      final container = await containerWith({
        kVoiceDownload: _download(
          name: 'Voice input model',
          fileName: 'ggml-base.en-q5_1.bin',
          percent: 7,
        ),
      });

      expect(container.read(voiceDownloadProvider)?.percent, 7);
      expect(container.read(llmDownloadProvider), isNull);
    });

    test('both can run at once without colliding', () async {
      final container = await containerWith({
        kLlmDownload: _download(percent: 42),
        kVoiceDownload: _download(
          name: 'Voice input model',
          fileName: 'ggml-base.en-q5_1.bin',
          percent: 7,
        ),
      });

      expect(container.read(llmDownloadProvider)?.name, 'Qwen3 (1.7B)');
      expect(container.read(voiceDownloadProvider)?.name, 'Voice input model');
    });

    test('nothing running reads as null for both', () async {
      final container = await containerWith(const {});

      expect(container.read(llmDownloadProvider), isNull);
      expect(container.read(voiceDownloadProvider), isNull);
    });
  });

  // Cancel drops the entry before asking the native side, so the bar goes away
  // on tap; the canceled status that follows must not put an error back.
  group('ModelDownloader.cancel', () {
    test('is a no-op when that kind is not downloading', () async {
      final downloader = ModelDownloader();
      addTearDown(downloader.dispose);
      final seen = <Map<String, ModelDownload>>[];
      downloader.progress.listen(seen.add);

      await downloader.cancel(kLlmDownload);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
    });
  });

  group('ModelDownload.running', () {
    test('is false once it has failed, so rows stop showing a bar', () {
      expect(_download().running, isTrue);
      expect(_download(error: 'Download failed.').running, isFalse);
    });
  });

  // Tapping Download on a second model used to open the sheet and render the
  // first model's percent under the second model's name.
  group('warnIfAnotherModelIsDownloading', () {
    final lfm = kAiModelCatalog.firstWhere((m) => m.id == 'lfm2_5_1_2b_gguf');
    final qwenSmall = kAiModelCatalog.firstWhere(
      (m) => m.id == 'qwen2_5_0_5b_gguf',
    );

    /// Pumps a button that runs the guard for [wanted] and records its answer.
    Future<List<bool>> tapGuard(
      WidgetTester tester, {
      required AiModel wanted,
      ModelDownload? inFlight,
    }) async {
      final answers = <bool>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [llmDownloadProvider.overrideWithValue(inFlight)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () async => answers.add(
                    await warnIfAnotherModelIsDownloading(context, ref, wanted),
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return answers;
    }

    testWidgets('notes the running model without showing its progress', (
      tester,
    ) async {
      final answers = await tapGuard(
        tester,
        wanted: qwenSmall,
        inFlight: _download(name: lfm.displayName, fileName: lfm.fileName),
      );

      // A centred note, not another bottom sheet that reads as a download.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('One model at a time'), findsOneWidget);
      expect(
        find.textContaining('${lfm.displayName} is still downloading'),
        findsOneWidget,
      );
      // A percent here is what made it look like the tapped model was running.
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('Downloading'), findsNothing);
      // Points at the Cancel button on the row, which is where I put it.
      expect(find.textContaining('progress bar'), findsOneWidget);

      // It only answers once dismissed, and the answer is what skips the sheet.
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(answers, [true]);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('stays out of the way when nothing is running', (tester) async {
      final answers = await tapGuard(tester, wanted: qwenSmall);

      expect(answers, [false]);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('stays out of the way for the model already running', (
      tester,
    ) async {
      final answers = await tapGuard(
        tester,
        wanted: lfm,
        inFlight: _download(name: lfm.displayName, fileName: lfm.fileName),
      );

      expect(answers, [false]);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a failed run does not block a different model', (
      tester,
    ) async {
      final answers = await tapGuard(
        tester,
        wanted: qwenSmall,
        inFlight: _download(
          name: lfm.displayName,
          fileName: lfm.fileName,
          error: 'Download failed.',
        ),
      );

      expect(answers, [false]);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('the download sheet', () {
    final lfm = kAiModelCatalog.firstWhere((m) => m.id == 'lfm2_5_1_2b_gguf');

    Future<void> pumpSheet(
      WidgetTester tester, {
      required AiModel model,
      ModelDownload? inFlight,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [llmDownloadProvider.overrideWithValue(inFlight)],
          child: MaterialApp(
            home: Scaffold(body: ModelDownloadSheet(model: model)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('reports progress for the model it was opened for', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        model: lfm,
        inFlight: _download(name: lfm.displayName, fileName: lfm.fileName),
      );

      expect(find.text('Downloading ${lfm.displayName}… 42%'), findsOneWidget);
      expect(find.text('Continue in background'), findsOneWidget);
    });

    testWidgets('offers Download when nothing is running', (tester) async {
      await pumpSheet(tester, model: lfm);

      expect(find.text('Download (${lfm.sizeLabel})'), findsOneWidget);
    });
  });
}
