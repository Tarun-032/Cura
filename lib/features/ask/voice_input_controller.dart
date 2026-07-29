import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../ai/model_download.dart';

/// On-device voice input for Ask: records the mic to a 16 kHz mono WAV and
/// transcribes it with Whisper.cpp on the phone.
///
/// Batch, not streaming, since Whisper's live mode falls behind real time. The
/// text lands in the composer for review; nothing is auto-sent.
///
/// Runs the q5_1-quantized `base.en` model (≈57 MB): same weights as fp16, but
/// faster and under half the download. `whisper_ggml` only knows the fp16
/// filename, so this file is managed here and its path passed to [Whisper].
class VoiceInputController {
  /// Filename / download URL for the quantized model.
  static const String _modelFileName = 'ggml-base.en-q5_1.bin';
  static const String _modelUrl =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/'
      'ggml-base.en-q5_1.bin';

  /// The fp16 model file (142 MB), deleted when found so an upgrading install
  /// doesn't keep a large orphaned model on disk.
  static const String _legacyModelFileName = 'ggml-base.en.bin';

  /// Passed only to the [Whisper] constructor; its transcribe path takes the
  /// explicit `modelPath`, so the enum's own filename/URL are unused.
  static const WhisperModel model = WhisperModel.baseEn;

  /// Human-readable size for the one-time download prompt.
  static const String modelSizeLabel = '≈ 57 MB';

  final AudioRecorder _recorder = AudioRecorder();

  String? _wavPath;
  bool _recording = false;

  bool get isRecording => _recording;

  /// Whether we have (or were just granted) microphone permission. `record`
  /// prompts the OS RECORD_AUDIO dialog itself on first call.
  Future<bool> hasMicPermission() => _recorder.hasPermission();

  /// Absolute path to the quantized model file (present or not). Lives in the
  /// same app-support dir `whisper_ggml` uses, just under our own filename.
  static Future<String> _resolveModelPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/$_modelFileName';
  }

  Future<String> _modelPath() => _resolveModelPath();

  /// Whether the Whisper model file is already on disk. Static so a provider
  /// can check readiness without constructing a controller (and its recorder).
  static Future<bool> isModelDownloaded() async =>
      File(await _resolveModelPath()).exists();

  /// The model file location, for storage accounting (Settings → Storage).
  static Future<File> modelFile() async => File(await _resolveModelPath());

  /// Whether the Whisper model file is already on disk.
  Future<bool> isModelReady() => isModelDownloaded();

  /// Queues the Whisper model into the path `whisper_ggml` loads from. Returns
  /// once the transfer is accepted, or false if the file was already here.
  Future<bool> downloadModel(ModelDownloader downloader) async {
    final dest = File(await _modelPath());
    if (await dest.exists()) return false;
    await dest.parent.create(recursive: true);
    try {
      await downloader.start(
        url: _modelUrl,
        fileName: _modelFileName,
        // Root of app support, not the models subdirectory the LLM uses.
        directory: '',
        displayName: 'Voice input model',
        kind: kVoiceDownload,
      );
    } on ModelDownloadException catch (e) {
      throw VoiceInputException(e.message);
    }
    return true;
  }

  /// Removes the downloaded Whisper model from the device (Settings "delete").
  Future<void> deleteModel() async {
    final file = File(await _modelPath());
    if (await file.exists()) await file.delete();
    await deleteLegacyModel();
  }

  /// Deletes the legacy fp16 model file if a previous build left one behind.
  /// Best-effort — never throws.
  static Future<void> deleteLegacyModel() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final legacy = File('${dir.path}/$_legacyModelFileName');
      if (await legacy.exists()) await legacy.delete();
    } catch (_) {
      // Orphan cleanup is best-effort; never fail the caller over it.
    }
  }

  /// Begins recording to a fresh temp WAV. Assumes permission was granted.
  Future<void> startRecording() async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/cura_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    _wavPath = path;
    _recording = true;
  }

  /// Live input level (0–1-ish, derived from dBFS) for the recording waveform.
  /// Polled fairly quickly so the bars visibly react to speech.
  Stream<double> amplitudeStream() =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 120)).map((a) {
        // Map ~[-45, 0] dBFS onto [0, 1] so the ring reacts to speech.
        const floor = -45.0;
        final norm = ((a.current - floor) / -floor).clamp(0.0, 1.0);
        return norm;
      });

  /// Stops recording and transcribes on-device. Returns the trimmed text, or
  /// null if nothing usable was captured. Always cleans up the temp audio.
  Future<String?> stopAndTranscribe({
    void Function(int percent)? onProgress,
  }) async {
    _recording = false;
    final recordedPath = await _recorder.stop() ?? _wavPath;
    _wavPath = null;
    if (recordedPath == null) return null;
    final sw = Stopwatch()..start();
    try {
      // The low-level API, not WhisperController.transcribe, which hardcodes
      // `isRealtime: true` and re-runs the encoder repeatedly. A finished clip
      // needs one batch pass for the same result. `noContext` stops the decoder
      // repeating itself, and `noFallback` skips the temperature-fallback loop,
      // which only costs time on short clean dictation.
      final modelPath = await _modelPath();
      final response = await Whisper(model: model).transcribe(
        transcribeRequest: TranscribeRequest(
          audio: recordedPath,
          language: 'en',
          isRealtime: false,
          isNoTimestamps: true,
          noContext: true,
          noFallback: true,
          threads: _threads,
        ),
        modelPath: modelPath,
        onProgress: onProgress,
      );
      final text = response.text.trim();
      debugPrint(
        '[Cura.voice] transcribe ms=${sw.elapsedMilliseconds} '
        'threads=$_threads chars=${text.length}',
      );
      return text.isEmpty ? null : text;
    } catch (e) {
      debugPrint(
        '[Cura.voice] transcribe failed after '
        '${sw.elapsedMilliseconds}ms: $e',
      );
      return null;
    } finally {
      // The recorded WAV plus the converter's `<path>.wav` output.
      await _deleteQuietly(recordedPath);
      await _deleteQuietly('$recordedPath.wav');
    }
  }

  // Match thread count to the fast cores. On a big.LITTLE phone (e.g. the A35's
  // 2 performance + 6 efficiency cores) piling threads onto the slow little
  // cores hurts more than it helps, so cap at 4.
  int get _threads {
    final n = Platform.numberOfProcessors;
    return n <= 4 ? n : 4;
  }

  /// Discards an in-progress recording without transcribing.
  Future<void> cancelRecording() async {
    _recording = false;
    try {
      await _recorder.cancel();
    } catch (_) {
      // Best-effort — a cancel with nothing recording is harmless.
    }
    final path = _wavPath;
    _wavPath = null;
    if (path != null) await _deleteQuietly(path);
  }

  Future<void> dispose() async {
    await _recorder.dispose();
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Temp cleanup is best-effort; never fail a completed transcription.
    }
  }
}

/// Readable voice-input failure surfaced to the UI.
class VoiceInputException implements Exception {
  const VoiceInputException(this.message);
  final String message;
  @override
  String toString() => message;
}
