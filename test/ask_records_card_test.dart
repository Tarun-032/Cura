import 'package:cura/app/theme/app_theme.dart';
import 'package:cura/features/ask/ask_prompt_rotation.dart';
import 'package:cura/features/library/widgets/ask_records_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Ask records card shows the complete example on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final example in kHomeAskExamples) {
      await tester.pumpWidget(
        MaterialApp(
          theme: CuraTheme.light,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: AskRecordsCard(example: example, onTap: () {}),
            ),
          ),
        ),
      );

      expect(find.text('"$example"'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
