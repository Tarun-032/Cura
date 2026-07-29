import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Which model a download is for. Travels as the task's `metaData`.
const kLlmDownload = 'llm';
const kVoiceDownload = 'voice';

/// A model download in flight.
class ModelDownload {
  const ModelDownload({
    required this.name,
    required this.fileName,
    required this.taskId,
    required this.percent,
    this.paused = false,
    this.error,
  });

  /// The model's display name, e.g. 'Qwen3 (1.7B)'.
  final String name;

  /// How a catalog row matches itself to this download.
  final String fileName;

  /// The enqueued task, so a progress bar can cancel it.
  final String taskId;

  /// 0-100. Stays 0 until the first real tick.
  final int percent;

  /// Waiting to resume, usually no connection.
  final bool paused;

  /// Set once the download failed; null while healthy.
  final String? error;

  /// Whether bytes are moving. A failed run stays on the stream for the sheet.
  bool get running => error == null;
}

/// Starts and tracks on-device model downloads. The transfer runs natively in a
/// foreground service, so it survives backgrounding and the 9 minute cap, and
/// closing the sheet that started one does not stop it.
class ModelDownloader {
  ModelDownloader({this.onFinished}) {
    _sub = FileDownloader().updates.listen(_onUpdate);
  }

  /// Called on a final state. [ok] is false for failed, cancelled, not-found.
  final void Function(Task task, bool ok)? onFinished;

  late final StreamSubscription<TaskUpdate> _sub;
  final _progress = StreamController<Map<String, ModelDownload>>.broadcast();

  /// Keyed by kind, not a single slot, so the two models stay independent.
  final _downloads = <String, ModelDownload>{};

  bool _configured = false;

  /// Broadcast, so a sheet can come and go without interrupting a download.
  Stream<Map<String, ModelDownload>> get progress => _progress.stream;

  void _emit() => _progress.add(Map.unmodifiable(_downloads));

  /// Enqueues [fileName] from [url] into app support under [directory] ('' for
  /// the root). One per [kind]: a second would only halve both their speeds.
  Future<void> start({
    required String url,
    required String fileName,
    required String directory,
    required String displayName,
    required String kind,
  }) async {
    final existing = _downloads[kind];
    if (existing != null && existing.running) {
      throw ModelDownloadException(
        '${existing.name} is already downloading. '
        'Wait for it to finish, or cancel it from its progress bar.',
      );
    }
    await _configure();
    final task = DownloadTask(
      url: url,
      filename: fileName,
      directory: directory,
      baseDirectory: BaseDirectory.applicationSupport,
      displayName: displayName,
      metaData: kind,
      // Explicit, or the package rewrites it and logs a warning.
      updates: Updates.statusAndProgress,
      // Hugging Face's CDN 403s transiently on a first hit.
      retries: 3,
      // Resume from where it stopped rather than restarting the file.
      allowPause: true,
    );
    _downloads[kind] = ModelDownload(
      name: displayName,
      fileName: fileName,
      taskId: task.taskId,
      percent: 0,
    );
    _emit();
    if (!await FileDownloader().enqueue(task)) {
      _downloads.remove(kind);
      _emit();
      throw const ModelDownloadException(
        'Could not start the download. Please try again.',
      );
    }
  }

  /// Stops the [kind] download and drops its progress. Dropped first so the bar
  /// that was tapped goes away now, not when the native side gets around to it.
  Future<void> cancel(String kind) async {
    final download = _downloads.remove(kind);
    if (download == null) return;
    _emit();
    await FileDownloader().cancelTaskWithId(download.taskId);
  }

  /// One-time setup. The `running` notification is what earns the foreground
  /// service, and with it exemption from the 9 minute limit.
  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    await FileDownloader().configure(
      globalConfig: [(Config.runInForeground, Config.always)],
    );
    FileDownloader().configureNotification(
      running: const TaskNotification(
        'Downloading {displayName}',
        '{progress}  ·  {timeRemaining} left',
      ),
      complete: const TaskNotification(
        '{displayName} is ready',
        'Download complete.',
      ),
      error: const TaskNotification(
        'Could not download {displayName}',
        'Open Cura to try again.',
      ),
      paused: const TaskNotification(
        'Downloading {displayName}',
        'Paused. Resumes when you are back online.',
      ),
      progressBar: true,
    );
    // A refusal is not fatal; the download just runs unseen.
    final permissions = FileDownloader().permissions;
    if (await permissions.status(PermissionType.notifications) ==
        PermissionStatus.undetermined) {
      await permissions.request(PermissionType.notifications);
    }
  }

  void _onUpdate(TaskUpdate update) {
    final name = update.task.displayName;
    final fileName = update.task.filename;
    final taskId = update.task.taskId;
    final kind = update.task.metaData;
    switch (update) {
      case TaskProgressUpdate():
        _downloads[kind] = ModelDownload(
          name: name,
          fileName: fileName,
          taskId: taskId,
          percent: percentOf(update.progress),
          paused: update.progress == progressPaused,
        );
        _emit();
      case TaskStatusUpdate():
        debugPrint('[Cura.download] $name ${update.status.name}');
        switch (update.status) {
          case TaskStatus.complete:
            _downloads.remove(kind);
            _emit();
            onFinished?.call(update.task, true);
          case TaskStatus.failed:
          case TaskStatus.notFound:
          case TaskStatus.canceled:
            // Already gone means I dropped it in cancel(), and I don't want to
            // report the user's own tap back to them as an error.
            if (_downloads.containsKey(kind)) {
              _downloads[kind] = ModelDownload(
                name: name,
                fileName: fileName,
                taskId: taskId,
                percent: 0,
                error: _message(update.status),
              );
              _emit();
            }
            onFinished?.call(update.task, false);
          case TaskStatus.enqueued:
          case TaskStatus.running:
          case TaskStatus.waitingToRetry:
          case TaskStatus.paused:
            break;
        }
    }
  }

  String _message(TaskStatus status) => switch (status) {
    TaskStatus.notFound =>
      'That model is no longer available at its download address.',
    TaskStatus.canceled => 'Download cancelled.',
    _ => 'Download failed. Check your connection and try again.',
  };

  void dispose() {
    _sub.cancel();
    _progress.close();
  }
}

/// Raw task progress to 0-100. Negatives are status sentinels, not fractions,
/// so they report as 0 instead of scaling to -100%.
int percentOf(double progress) =>
    progress < 0 ? 0 : (progress.clamp(0.0, 1.0) * 100).round();

/// Readable download failure surfaced to the UI.
class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}
