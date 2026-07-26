import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_providers.dart';
import '../ask/ask_prompt_rotation.dart';
import '../library/home_screen.dart';

/// Persisted flag: has the user been through onboarding (engine/model choice)?
const kOnboardedKey = 'cura_onboarded';

/// True once onboarding has been completed. Read once at launch by the root gate.
Future<bool> hasOnboarded() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kOnboardedKey) ?? false;
}

/// Marks onboarding done and replaces the stack with Home. Refreshes the
/// engine/model providers so Home reflects what was set up.
Future<void> finishOnboarding(BuildContext context, WidgetRef ref) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kOnboardedKey, true);
  ref.invalidate(activeEngineProvider);
  ref.invalidate(aiModelStateProvider);
  final homeAskExample = await askPromptRotation.takeNextHomeExample();
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(
      builder: (_) => HomeScreen(homeAskExample: homeAskExample),
    ),
    (route) => false,
  );
}
