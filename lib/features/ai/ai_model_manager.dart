import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_models.dart';

/// Manages the on-device model file: a streamed HTTP GET into app-private
/// storage, which llama.cpp then loads directly. There is no install step, so
/// "the file exists on disk" is the source of truth for what is installed.
class AiModelManager {
  static const _activeKey = 'cura_active_ai_model';
  static const _thinkKey = 'cura_think_harder';

  /// The user's "Think harder" preference, for models with `AiModel.canThink`.
  /// Off by default, since reasoning is slower.
  Future<bool> thinkHarder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_thinkKey) ?? false;
  }

  /// Persists the "Think harder" preference. Takes effect on the next question
  /// (the service reads it fresh each time), so no model reload is needed.
  Future<void> setThinkHarder(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_thinkKey, value);
  }

  /// Whether [model]'s file is fully present on disk.
  Future<bool> isInstalled(AiModel model) async {
    final file = await _modelFile(model);
    return file.exists();
  }

  /// Absolute path to [model]'s file on disk (whether or not it exists yet).
  Future<String> modelPath(AiModel model) async =>
      (await _modelFile(model)).path;

  /// The downloaded model to use, if any: prefers the last-selected one, else
  /// any catalog model whose file is present. Null if nothing is downloaded.
  Future<AiModel?> installedModel() async {
    final prefs = await SharedPreferences.getInstance();
    final preferred = aiModelById(prefs.getString(_activeKey));
    if (preferred != null && await isInstalled(preferred)) return preferred;
    for (final m in kAiModelCatalog) {
      if (await isInstalled(m)) return m;
    }
    return null;
  }

  /// Switches the active selection to [model] (must already be downloaded).
  Future<void> activate(AiModel model) async {
    final file = await _modelFile(model);
    if (!await file.exists()) {
      throw const ModelDownloadException('Model is not downloaded yet.');
    }
    await _remember(model);
  }

  /// Downloads [model] to private storage and marks it active. [onProgress]
  /// receives 0–100; throws [ModelDownloadException] on failure. Retries with a
  /// short backoff, since Hugging Face's CDN 403s transiently on a first hit.
  Future<void> download(AiModel model, {void Function(int)? onProgress}) async {
    final dest = await _modelFile(model);
    if (await dest.exists()) {
      await _remember(model);
      return;
    }
    await dest.parent.create(recursive: true);

    const maxAttempts = 4;
    ModelDownloadException? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _downloadOnce(model, dest, onProgress);
        await _remember(model);
        return;
      } on ModelDownloadException catch (e) {
        lastError = e;
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
        }
      }
    }
    throw lastError ??
        const ModelDownloadException('Download failed. Please try again later.');
  }

  /// A single download attempt: streamed GET into a `.part` temp, atomically
  /// renamed on success and cleaned up on any failure.
  Future<void> _downloadOnce(
    AiModel model,
    File dest,
    void Function(int)? onProgress,
  ) async {
    final temp = File('${dest.path}.part');
    if (await temp.exists()) await temp.delete();

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(model.url))
        ..headers['User-Agent'] = 'Cura/1.0 (Android)'
        ..headers['Accept'] = '*/*';
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw ModelDownloadException(
          'Server returned ${response.statusCode}. Please try again later.',
        );
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      var lastPct = -1;
      final sink = temp.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            final pct = (received * 100 ~/ total);
            if (pct != lastPct) {
              lastPct = pct;
              onProgress?.call(pct);
            }
          }
        }
      } finally {
        await sink.close();
      }
      await temp.rename(dest.path);
    } on ModelDownloadException {
      if (await temp.exists()) await temp.delete();
      rethrow;
    } catch (e) {
      if (await temp.exists()) await temp.delete();
      throw ModelDownloadException('Download failed: $e');
    } finally {
      client.close();
    }
  }

  /// Persists [model] as the active selection.
  Future<void> _remember(AiModel model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, model.id);
  }

  /// Removes the downloaded model from the device.
  Future<void> delete(AiModel model) async {
    final file = await _modelFile(model);
    if (await file.exists()) await file.delete();
  }

  /// Removes every downloaded model from the device and clears the active
  /// selection. Deletes the whole models directory so orphaned files (e.g. a
  /// model dropped from the catalog, or leftover .part temp files) go too.
  Future<void> deleteAll() async {
    final dir = await getApplicationSupportDirectory();
    final modelsDir = Directory(p.join(dir.path, 'models'));
    if (await modelsDir.exists()) {
      await modelsDir.delete(recursive: true);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeKey);
  }

  Future<File> _modelFile(AiModel model) async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'models', model.fileName));
  }
}

/// Readable download failure surfaced to the UI.
class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}
