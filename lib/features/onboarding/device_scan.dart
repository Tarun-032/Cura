import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../ai/ai_models.dart';
import '../ai/remote/remote_ai_store.dart' show AiEngine;

/// Native bridge to [MainActivity] for the *true* hardware readout (RAM + SoC).
/// The Vulkan probe alone can't be trusted for RAM — see [scanDevice].
const _deviceChannel = MethodChannel('com.cura.cura/device');

/// A one-shot snapshot of the device's AI-relevant hardware, read at onboarding
/// to recommend on-device vs cloud. Everything is best-effort: a field is
/// "unknown" (`<= 0` / empty) rather than absent, so callers never hit nulls.
class DeviceProfile {
  const DeviceProfile({
    required this.totalRamBytes,
    required this.freeRamBytes,
    required this.cores,
    required this.socName,
    required this.gpuName,
    required this.vulkan,
    required this.ramKnown,
  });

  /// Total physical system RAM in bytes (ActivityManager.totalMem), or `<= 0`
  /// when the probe couldn't read it.
  final int totalRamBytes;

  /// Free RAM in bytes, or `<= 0` when unknown.
  final int freeRamBytes;

  /// Logical CPU cores, or `0` when unknown.
  final int cores;

  /// Processor / SoC name, e.g. "Exynos 1380" / "Snapdragon 8 Gen 2". Empty
  /// when unknown.
  final String socName;

  /// GPU name, e.g. "Mali-G68" / "Adreno (TM) 740". Empty or "None" when unknown.
  final String gpuName;

  final bool vulkan;

  /// Whether [totalRamBytes] is a real reading (drives the recommendation).
  final bool ramKnown;

  double get totalRamGb => totalRamBytes / (1024 * 1024 * 1024);

  /// The RAM figure shown to the user, in whole GB, matching the retail spec.
  /// `advertisedMem` is already exact; a kernel `totalMem` reading is snapped up
  /// to the nearest tier by [snapRamGb].
  int get displayRamGb => ramKnown ? snapRamGb(totalRamGb) : 0;

  /// One-line spec for the transparency row, e.g.
  /// "Exynos 1380 · 6 GB RAM · 8 cores · Mali-G68". Only includes the parts that
  /// were actually read.
  String get summary {
    final parts = <String>[];
    final soc = socName.trim();
    if (soc.isNotEmpty) parts.add(soc);
    if (ramKnown) parts.add('$displayRamGb GB RAM');
    if (cores > 0) parts.add('$cores cores');
    final g = gpuName.trim();
    if (g.isNotEmpty && g.toLowerCase() != 'none') parts.add(g);
    return parts.isEmpty ? 'Device details unavailable' : parts.join(' · ');
  }

  /// Fallback used when the probe can't run at all (nothing readable).
  static const unknown = DeviceProfile(
    totalRamBytes: -1,
    freeRamBytes: -1,
    cores: 0,
    socName: '',
    gpuName: '',
    vulkan: false,
    ramKnown: false,
  );
}

/// Runs the hardware probe. Never throws: any failure returns a [DeviceProfile]
/// with `ramKnown: false`, so the caller falls back to the privacy default.
///
/// RAM and processor come from the native [_deviceChannel]; GPU and Vulkan from
/// `detectGpu()` on a throwaway controller. The Vulkan device-local heap is not
/// used for RAM, since unified-memory SoCs report far below physical.
Future<DeviceProfile> scanDevice() async {
  // --- GPU (Vulkan probe) ---
  GpuInfo? g;
  final probe = LlamaController();
  try {
    g = await probe.detectGpu();
  } catch (_) {
    g = null;
  }
  try {
    await probe.dispose();
  } catch (_) {
    // A probe that never loaded a model may not need disposing — ignore.
  }

  // --- RAM + SoC (native channel) ---
  Map<Object?, Object?>? info;
  try {
    info = await _deviceChannel.invokeMapMethod<Object?, Object?>('getInfo');
  } catch (_) {
    info = null;
  }

  // Prefer advertisedMem (retail RAM, e.g. exactly 6 GB); fall back to the
  // kernel totalMem; and only if the native channel is unreachable, the Vulkan
  // heap (a poor RAM proxy on unified-memory SoCs).
  var totalRam = (info?['advertisedRamBytes'] as num?)?.toInt() ?? 0;
  if (totalRam <= 0) totalRam = (info?['totalRamBytes'] as num?)?.toInt() ?? -1;
  var freeRam = (info?['availRamBytes'] as num?)?.toInt() ?? -1;
  if (totalRam <= 0) totalRam = g?.deviceLocalMemoryBytes ?? -1;
  if (freeRam <= 0) freeRam = g?.freeRamBytes ?? -1;

  final cores = ((info?['cores'] as num?)?.toInt() ?? 0) > 0
      ? (info!['cores'] as num).toInt()
      : _safeCores();

  final socName = _friendlySoc(
    manufacturer: (info?['socManufacturer'] as String?) ?? '',
    model: (info?['socModel'] as String?) ?? '',
    hardware: (info?['hardware'] as String?) ?? '',
    cpuLine: (info?['cpuHardwareLine'] as String?) ?? '',
  );

  return DeviceProfile(
    totalRamBytes: totalRam,
    freeRamBytes: freeRam,
    cores: cores,
    socName: socName,
    gpuName: g?.gpuName ?? '',
    vulkan: g?.vulkanSupported ?? false,
    ramKnown: totalRam > 0,
  );
}

int _safeCores() {
  try {
    final n = Platform.numberOfProcessors;
    return n > 0 ? n : 0;
  } catch (_) {
    return 0;
  }
}

/// SoC codenames to marketing names, since Android exposes only codes. Keys are
/// lowercased; anything unmapped falls back to a cleaned manufacturer+model.
const _kSocCodenames = <String, String>{
  // Samsung Exynos
  's5e8835': 'Exynos 1380',
  's5e8845': 'Exynos 1480',
  's5e8825': 'Exynos 1280',
  's5e9925': 'Exynos 2200',
  's5e9935': 'Exynos 2300',
  's5e9945': 'Exynos 2400',
  's5e9840': 'Exynos 990',
  's5e3830': 'Exynos 850',
  'exynos850': 'Exynos 850',
  'universal9611': 'Exynos 9611',
  // Qualcomm Snapdragon
  'sm8750': 'Snapdragon 8 Elite',
  'sm8650': 'Snapdragon 8 Gen 3',
  'sm8550': 'Snapdragon 8 Gen 2',
  'sm8475': 'Snapdragon 8+ Gen 1',
  'sm8450': 'Snapdragon 8 Gen 1',
  'sm7675': 'Snapdragon 7 Gen 3',
  'sm7550': 'Snapdragon 7 Gen 3',
  'sm7450': 'Snapdragon 7 Gen 1',
  'sm7435': 'Snapdragon 7s Gen 2',
  'sm7325': 'Snapdragon 778G',
  'sm6450': 'Snapdragon 6 Gen 1',
  'sm6375': 'Snapdragon 695',
  'sm6225': 'Snapdragon 680',
  'sm6115': 'Snapdragon 662',
  // MediaTek Dimensity / Helio
  'mt6989': 'Dimensity 9300',
  'mt6985': 'Dimensity 9200',
  'mt6983': 'Dimensity 9000',
  'mt6897': 'Dimensity 8300',
  'mt6896': 'Dimensity 8200',
  'mt6895': 'Dimensity 8100',
  'mt6886': 'Dimensity 7200',
  'mt6877': 'Dimensity 900',
  'mt6833': 'Dimensity 700',
  'mt6789': 'Helio G99',
  'mt6785': 'Helio G90',
  'mt6769': 'Helio G80',
  // Google Tensor
  'gs101': 'Google Tensor',
  'gs201': 'Google Tensor G2',
  'zuma': 'Google Tensor G3',
  'zumapro': 'Google Tensor G4',
};

/// Turns raw Android SoC identifiers into a friendly processor name.
/// Best-effort: prefers the codename map, then the /proc/cpuinfo "Hardware"
/// line, then a tidied manufacturer+model, and finally "". Never throws.
String _friendlySoc({
  required String manufacturer,
  required String model,
  required String hardware,
  required String cpuLine,
}) {
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');

  // 1) Codename map, tried against SOC_MODEL then HARDWARE.
  for (final key in [norm(model), norm(hardware)]) {
    if (key.isEmpty) continue;
    final hit = _kSocCodenames[key];
    if (hit != null) return hit;
  }

  // 2) A readable /proc/cpuinfo "Hardware" line (common on Qualcomm/MediaTek).
  final cl = cpuLine.trim();
  if (cl.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(cl)) return cl;

  // 3) Fall back to manufacturer + model when both look presentable.
  final man = manufacturer.trim();
  final mod = model.trim();
  if (mod.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(mod)) {
    if (man.isNotEmpty && !norm(mod).contains(norm(man))) return '$man $mod';
    return mod;
  }
  final hw = hardware.trim();
  if (hw.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(hw)) return hw;
  return '';
}

/// Standard retail RAM tiers (GB). Phones ship with these sizes, so snapping a
/// low kernel reading up to the nearest tier recovers the advertised number.
const _kRamTiers = <int>[1, 2, 3, 4, 6, 8, 12, 16, 18, 24, 32];

/// Snaps a raw RAM reading up to the nearest retail tier (5.6 → 6, 7.4 → 8).
/// The 0.15 tolerance keeps a reading sitting just under a tier on that tier.
/// Plain rounding above the largest known tier.
int snapRamGb(double gb) {
  for (final tier in _kRamTiers) {
    if (gb <= tier + 0.15) return tier;
  }
  return gb.round();
}

/// The RAM tier at or above which on-device is recommended, matching the UI copy
/// "best on phones with 6 GB+ RAM". Compared against the snapped retail figure.
const _kOnDeviceRamGb = 6;

/// Which engine to recommend, with a short reason and whether the on-device path
/// is likely to feel slow on this device.
class EngineAdvice {
  const EngineAdvice({
    required this.recommended,
    required this.reason,
    required this.onDeviceSlow,
  });

  final AiEngine recommended;
  final String reason;
  final bool onDeviceSlow;

  bool get recommendsOnDevice => recommended == AiEngine.local;
}

/// Pure, total mapping from a [DeviceProfile] to an engine recommendation.
/// Privacy-first: keep users on-device whenever it's viable, and only steer to
/// cloud on genuinely low-RAM devices. Unreadable RAM defaults to on-device,
/// the private option.
EngineAdvice adviseEngine(DeviceProfile p) {
  if (!p.ramKnown) {
    return const EngineAdvice(
      recommended: AiEngine.local,
      reason:
          "Couldn't fully read your device. The downloaded model is the default.",
      onDeviceSlow: false,
    );
  }
  if (p.displayRamGb >= _kOnDeviceRamGb) {
    return const EngineAdvice(
      recommended: AiEngine.local,
      reason: 'Enough memory. The downloaded model should run well here.',
      onDeviceSlow: false,
    );
  }
  return const EngineAdvice(
    recommended: AiEngine.remote,
    reason:
        "Limited memory. A cloud model is faster and won't strain your phone.",
    onDeviceSlow: true,
  );
}

/// Pure: the on-device model best suited to this device — the balanced default
/// when there's memory to spare, the lightest model on constrained devices.
AiModel recommendModel(DeviceProfile p) {
  if (p.ramKnown && p.displayRamGb < _kOnDeviceRamGb) {
    return aiModelById('qwen2_5_0_5b_gguf') ?? kDefaultModel;
  }
  return kDefaultModel; // LFM2.5 (1.2B) — balanced, the catalog default
}

/// One-shot cached hardware scan for the onboarding UI (runs once, reused).
final deviceProfileProvider = FutureProvider<DeviceProfile>(
  (ref) => scanDevice(),
);
