import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_models.dart';
import 'model_download.dart';

/// Subdirectory of application support the model files live in.
const kModelsDirectory = 'models';

/// Manages the on-device model file, which llama.cpp loads directly. No install
/// step, so "the file exists on disk" is the source of truth.
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, model.id);
  }

  /// Queues [model]. Returns once the transfer is accepted, not finished, or
  /// false if the file was already here so nothing started.
  Future<bool> download(AiModel model, ModelDownloader downloader) async {
    final dest = await _modelFile(model);
    if (await dest.exists()) {
      await activate(model);
      return false;
    }
    await dest.parent.create(recursive: true);
    await downloader.start(
      url: model.url,
      fileName: model.fileName,
      directory: kModelsDirectory,
      displayName: model.displayName,
      kind: kLlmDownload,
    );
    return true;
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
    final modelsDir = Directory(p.join(dir.path, kModelsDirectory));
    if (await modelsDir.exists()) {
      await modelsDir.delete(recursive: true);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeKey);
  }

  Future<File> _modelFile(AiModel model) async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, kModelsDirectory, model.fileName));
  }
}
