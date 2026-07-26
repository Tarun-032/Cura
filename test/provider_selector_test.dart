import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cura/app/theme/app_theme.dart';
import 'package:cura/features/ai/remote/provider_selector.dart';
import 'package:cura/features/ai/remote/remote_ai_config.dart';

void main() {
  test('NVIDIA NIM preset uses the hosted API base URL', () {
    final provider = providerById('nvidia');

    expect(provider.label, 'NVIDIA NIM');
    expect(provider.baseUrl, 'https://integrate.api.nvidia.com/v1');
    expect(provider.isCustom, isFalse);
  });

  testWidgets('provider selector uses Cura styling and changes provider', (
    tester,
  ) async {
    var selected = 'groq';

    await tester.pumpWidget(
      MaterialApp(
        theme: CuraTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return RemoteProviderSelector(
                    value: selected,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => setState(() => selected = value),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Groq'));
    await tester.pumpAndSettle();

    final openRouter = tester.widget<Text>(find.text('OpenRouter'));
    expect(openRouter.style?.fontFamily, 'PlusJakartaSans');
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('NVIDIA NIM'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);

    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();

    expect(selected, 'openai');
    expect(find.text('OpenAI'), findsOneWidget);
  });
}
