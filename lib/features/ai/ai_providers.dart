import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ask/voice_input_controller.dart';
import '../settings/storage_info.dart';
import 'ai_model_manager.dart';
import 'ai_models.dart';
import 'ai_service.dart';
import 'model_download.dart';
import 'remote/remote_ai_store.dart';

/// Handles downloading / checking the on-device model.
final aiModelManagerProvider = Provider<AiModelManager>((ref) {
  return AiModelManager();
});

/// Starts and tracks model downloads. Not autoDispose, so it outlives the sheet
/// that started one and still runs [ModelDownloader.onFinished].
final modelDownloaderProvider = Provider<ModelDownloader>((ref) {
  final downloader = ModelDownloader(
    onFinished: (task, ok) async {
      if (!ok) return;
      if (task.metaData == kLlmDownload) {
        // Activate here, since download() no longer waits for the transfer.
        final model = aiModelByFileName(task.filename);
        if (model != null) {
          await ref.read(aiModelManagerProvider).activate(model);
        }
        // Drop the warm model so the next question loads the new one.
        ref.invalidate(aiServiceProvider);
        ref.invalidate(aiModelStateProvider);
        ref.invalidate(activeEngineProvider);
      } else {
        await VoiceInputController.deleteLegacyModel();
        ref.invalidate(voiceModelReadyProvider);
      }
      ref.invalidate(storageBreakdownProvider);
    },
  );
  ref.onDispose(downloader.dispose);
  return downloader;
});

/// Everything in flight, keyed by kind.
final modelDownloadsProvider = StreamProvider<Map<String, ModelDownload>>((
  ref,
) {
  return ref.watch(modelDownloaderProvider).progress;
});

/// The on-device LLM download in flight, or null.
final llmDownloadProvider = Provider<ModelDownload?>((ref) {
  return ref.watch(modelDownloadsProvider).value?[kLlmDownload];
});

/// The voice (Whisper) model download in flight, or null.
final voiceDownloadProvider = Provider<ModelDownload?>((ref) {
  return ref.watch(modelDownloadsProvider).value?[kVoiceDownload];
});

/// Stores the optional cloud-model config + which engine is active.
final remoteAiStoreProvider = Provider<RemoteAiStore>((ref) {
  return RemoteAiStore();
});

/// Runs document structuring on the active model. Released on dispose.
final aiServiceProvider = Provider<AiService>((ref) {
  final service = AiService(
    ref.watch(aiModelManagerProvider),
    ref.watch(remoteAiStoreProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Snapshot of on-device model state: which catalog models are downloaded and
/// which is active. Disk is the source of truth; this makes it reactive so
/// Settings and the Ask header stay in sync. Invalidate after every mutation.
class AiModelState {
  const AiModelState({required this.installed, required this.active});

  /// Catalog ids whose file is present on disk.
  final Set<String> installed;

  /// The active model (or null if none downloaded).
  final AiModel? active;
}

final aiModelStateProvider = FutureProvider<AiModelState>((ref) async {
  final mgr = ref.watch(aiModelManagerProvider);
  final installed = <String>{};
  for (final m in kAiModelCatalog) {
    if (await mgr.isInstalled(m)) installed.add(m.id);
  }
  final active = await mgr.installedModel();
  return AiModelState(installed: installed, active: active);
});

/// Whether the Whisper voice model is downloaded. Disk is the source of truth;
/// this makes it reactive so the Settings row, the Ask mic gate and the
/// onboarding step agree. Invalidate after every download or delete.
final voiceModelReadyProvider = FutureProvider<bool>((ref) async {
  return VoiceInputController.isModelDownloaded();
});

/// The user's "Think harder" preference (reasoning models only). The switcher
/// toggle watches this; the [AiService] reads the pref directly per question.
/// Invalidate it after a change so the toggle reflects the new value.
final thinkHarderProvider = FutureProvider<bool>((ref) async {
  return ref.watch(aiModelManagerProvider).thinkHarder();
});

/// Which engine will answer, plus the label for the Ask header and Settings.
/// Falls back to local when a selected cloud engine is misconfigured.
/// [remoteConfigured] gates whether the cloud option is offered at all.
class ActiveEngineInfo {
  const ActiveEngineInfo({
    required this.engine,
    required this.label,
    required this.remoteLabel,
    required this.remoteConfigured,
  });

  final AiEngine engine;

  /// Name of the *active* engine — the on-device model when local is active, the
  /// cloud model when remote is. Shown in the Ask header.
  final String label;

  /// Name of the configured cloud model, independent of which engine is active
  /// (empty when no cloud model is configured). The cloud row in the model
  /// switcher uses this, so switching to an on-device model can't overwrite it.
  final String remoteLabel;

  final bool remoteConfigured;

  bool get isRemote => engine == AiEngine.remote;
}

final activeEngineProvider = FutureProvider<ActiveEngineInfo>((ref) async {
  final store = ref.watch(remoteAiStoreProvider);
  final cfg = await store.config();
  final engine = await store.engine();
  if (engine == AiEngine.remote && cfg.isComplete) {
    return ActiveEngineInfo(
      engine: AiEngine.remote,
      label: cfg.displayName,
      remoteLabel: cfg.displayName,
      remoteConfigured: true,
    );
  }
  final local = await ref.watch(aiModelManagerProvider).installedModel();
  return ActiveEngineInfo(
    engine: AiEngine.local,
    label: local?.displayName ?? 'On-device model',
    remoteLabel: cfg.isComplete ? cfg.displayName : '',
    remoteConfigured: cfg.isComplete,
  );
});
