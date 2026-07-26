import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ask/voice_input_controller.dart';

/// On-disk bytes per storage category, computed from the real files — the same
/// locations the features own (models dir, whisper file, scans/imports + DB,
/// temp dir). Disk is the source of truth; nothing here is persisted.
class StorageBreakdown {
  const StorageBreakdown({
    required this.aiModels,
    required this.documents,
    required this.voiceModel,
    required this.cache,
  });

  final int aiModels;
  final int documents;
  final int voiceModel;
  final int cache;

  int get total => aiModels + documents + voiceModel + cache;
}

/// Recomputed from disk on every read. Every delete/clear must
/// `ref.invalidate(storageBreakdownProvider)` so the donut and rows refresh.
final storageBreakdownProvider = FutureProvider<StorageBreakdown>((ref) async {
  final support = await getApplicationSupportDirectory();
  final docs = await getApplicationDocumentsDirectory();
  final temp = await getTemporaryDirectory();

  final aiModels = await _dirSize(Directory(p.join(support.path, 'models')));

  final voiceFile = await VoiceInputController.modelFile();
  final voiceModel = await voiceFile.exists() ? await voiceFile.length() : 0;

  // Scanned pages + imported PDFs + the Drift database (cura.sqlite and its
  // -wal/-shm siblings; drift_flutter places it in the documents dir, but we
  // also check app-support so a future default change can't hide it).
  var documents =
      await _dirSize(Directory(p.join(docs.path, 'scans'))) +
      await _dirSize(Directory(p.join(docs.path, 'imports')));
  for (final dir in [docs, support]) {
    documents += await _dbFilesSize(dir);
  }

  final cache = await _dirSize(temp);

  return StorageBreakdown(
    aiModels: aiModels,
    documents: documents,
    voiceModel: voiceModel,
    cache: cache,
  );
});

/// Deletes the *contents* of the temp directory (never the directory itself —
/// the OS and scan/voice code recreate files in it on demand). Per-entry
/// failures are ignored: a file can be held open by an in-flight scan.
Future<void> clearCache() async {
  final temp = await getTemporaryDirectory();
  if (!await temp.exists()) return;
  await for (final entity in temp.list(followLinks: false)) {
    try {
      await entity.delete(recursive: true);
    } catch (_) {}
  }
}

/// "600 MB" / "1.2 GB" style labels, matching the model sizeLabel formatting.
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) {
    final v = bytes / gb;
    return '${v.toStringAsFixed(v < 10 ? 1 : 0)} GB';
  }
  if (bytes >= mb) {
    final v = bytes / mb;
    return '${v.toStringAsFixed(v < 10 ? 1 : 0)} MB';
  }
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}

Future<int> _dirSize(Directory dir) async {
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += await entity.length();
      } catch (_) {}
    }
  }
  return total;
}

Future<int> _dbFilesSize(Directory dir) async {
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is File &&
        p.basename(entity.path).startsWith('cura.sqlite')) {
      try {
        total += await entity.length();
      } catch (_) {}
    }
  }
  return total;
}
