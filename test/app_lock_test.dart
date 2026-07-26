// The one bit of the biometric app lock that's testable off-device: the
// persisted flag round-trip. BiometricAuth/the prompt/UI need a real device.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cura/features/security/app_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app lock is off by default', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await isAppLockEnabled(), isFalse);
  });

  test('enabling then reading returns true', () async {
    SharedPreferences.setMockInitialValues({});
    await setAppLockEnabled(true);
    expect(await isAppLockEnabled(), isTrue);
  });

  test('disabling turns it back off', () async {
    SharedPreferences.setMockInitialValues({kAppLockKey: true});
    await setAppLockEnabled(false);
    expect(await isAppLockEnabled(), isFalse);
  });
}
