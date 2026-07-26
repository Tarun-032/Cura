// Tests for the pure recommendation logic behind the onboarding hardware scan.
// The scan itself is thin I/O (detectGpu) verified on-device; the decisions here
// are deterministic and must be right across RAM tiers.

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/ai/ai_models.dart';
import 'package:cura/features/ai/remote/remote_ai_store.dart';
import 'package:cura/features/onboarding/device_scan.dart';

DeviceProfile _profile({
  double? ramGb,
  int cores = 8,
  String soc = '',
  String gpu = 'Mali-G68',
}) {
  final known = ramGb != null;
  return DeviceProfile(
    totalRamBytes: known ? (ramGb * 1024 * 1024 * 1024).round() : -1,
    freeRamBytes: known ? (ramGb * 0.5 * 1024 * 1024 * 1024).round() : -1,
    cores: cores,
    socName: soc,
    gpuName: gpu,
    vulkan: true,
    ramKnown: known,
  );
}

void main() {
  group('snapRamGb', () {
    test('snaps low kernel readings up to the retail tier', () {
      expect(snapRamGb(5.6), 6); // 6 GB phone via totalMem
      expect(snapRamGb(6.0), 6); // 6 GB via advertisedMem
      expect(snapRamGb(3.6), 4); // 4 GB phone
      expect(snapRamGb(2.7), 3); // 3 GB phone
      expect(snapRamGb(7.4), 8); // 8 GB phone
      expect(snapRamGb(11.2), 12); // 12 GB phone
      expect(snapRamGb(15.4), 16); // 16 GB phone
    });
  });

  group('adviseEngine', () {
    test('6 GB+ phones → on-device, not slow', () {
      // Whether reported as 6.0 (advertisedMem) or ~5.6 (totalMem), snaps to 6.
      for (final gb in [8.0, 7.4, 6.0, 5.6]) {
        final a = adviseEngine(_profile(ramGb: gb));
        expect(a.recommended, AiEngine.local, reason: '$gb GB');
        expect(a.onDeviceSlow, isFalse, reason: '$gb GB');
      }
    });

    test('4 GB-class and lower phones → cloud, on-device flagged slow', () {
      // A "4 GB" phone reports ~3.6 GB; these should be steered to cloud.
      for (final gb in [4.0, 3.6, 3.0, 2.0, 1.5]) {
        final a = adviseEngine(_profile(ramGb: gb));
        expect(a.recommended, AiEngine.remote, reason: '$gb GB');
        expect(a.onDeviceSlow, isTrue, reason: '$gb GB');
      }
    });

    test('unreadable RAM → on-device (privacy default), not slow', () {
      final a = adviseEngine(_profile(ramGb: null));
      expect(a.recommended, AiEngine.local);
      expect(a.onDeviceSlow, isFalse);
      expect(a.reason, contains('downloaded model'));
    });
  });

  group('recommendModel', () {
    test('roomy phones get the balanced default (LFM2.5)', () {
      expect(recommendModel(_profile(ramGb: 8)).id, kDefaultModel.id);
      expect(recommendModel(_profile(ramGb: 5.6)).id, kDefaultModel.id);
    });

    test('low-RAM phones get the lightest model (Qwen 0.5B)', () {
      expect(recommendModel(_profile(ramGb: 4)).id, 'qwen2_5_0_5b_gguf');
      expect(recommendModel(_profile(ramGb: 3)).id, 'qwen2_5_0_5b_gguf');
      expect(recommendModel(_profile(ramGb: 2)).id, 'qwen2_5_0_5b_gguf');
    });

    test('unreadable RAM falls back to the default', () {
      expect(recommendModel(_profile(ramGb: null)).id, kDefaultModel.id);
    });
  });

  group('DeviceProfile.summary', () {
    test('formats the parts it has', () {
      expect(_profile(ramGb: 8).summary, '8 GB RAM · 8 cores · Mali-G68');
    });
    test('leads with the processor when known', () {
      expect(
        _profile(ramGb: 6, soc: 'Exynos 1380').summary,
        'Exynos 1380 · 6 GB RAM · 8 cores · Mali-G68',
      );
    });
    test('degrades gracefully when nothing is known', () {
      expect(DeviceProfile.unknown.summary, 'Device details unavailable');
    });
  });
}
