// Basic smoke test for the Cura app.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cura/main.dart';

void main() {
  testWidgets('Onboarding screen shows the wordmark and CTA', (tester) async {
    // The root gate reads the onboarding flag from SharedPreferences before it
    // can render; back it with an empty mock store (nothing onboarded) and
    // wrap in the ProviderScope that main() supplies at runtime.
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const ProviderScope(child: CuraApp()));
    // The first pump flushes the SharedPreferences microtask so the root gate
    // mounts OnboardingScreen; pumpAndSettle then runs its entrance animations
    // to completion, leaving no timer pending at teardown.
    await tester.pump();
    await tester.pumpAndSettle();

    // Key onboarding content is present.
    expect(find.text('Cura'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
  });
}
