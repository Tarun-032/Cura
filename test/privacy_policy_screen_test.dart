import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cura/features/settings/privacy_policy_screen.dart';
import 'package:cura/features/settings/settings_view.dart';

void main() {
  test('privacy policy source contains no em dash or en dash', () {
    final source = File(
      'lib/features/settings/privacy_policy_screen.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('\u2014')));
    expect(source, isNot(contains('\u2013')));
  });

  testWidgets('privacy policy identifies Cura and the effective date', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PrivacyPolicyScreen()));

    expect(find.text('Privacy policy'), findsOneWidget);
    expect(
      find.text('Effective ${PrivacyPolicyScreen.effectiveDate}'),
      findsOneWidget,
    );
    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('1. Purpose and scope'), findsOneWidget);
  });

  testWidgets('Settings privacy policy row opens the policy page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SettingsView(onExport: _noop, onDeleteAll: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Privacy policy'),
      700,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Privacy policy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(
      find.text('Effective ${PrivacyPolicyScreen.effectiveDate}'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

void _noop() {}
