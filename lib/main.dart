import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme/app_colors.dart';
import 'app/theme/app_theme.dart';
import 'features/ask/ask_prompt_rotation.dart';
import 'features/library/home_screen.dart';
import 'features/onboarding/onboarding_flow.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/security/app_lock.dart';

void main() {
  runApp(const ProviderScope(child: CuraApp()));
}

class CuraApp extends StatelessWidget {
  const CuraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cura',
      debugShowCheckedModeBanner: false,
      theme: CuraTheme.light,
      home: const _RootGate(),
    );
  }
}

/// Chooses the first screen from the [kOnboardedKey] flag: onboarding on first
/// launch, Home after. Shows a plain canvas while reading, and defaults to
/// onboarding if the flag can't be read.
class _RootGate extends StatefulWidget {
  const _RootGate();

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  bool? _onboarded;
  String _homeAskExample = kHomeAskExamples.first;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final onboarded = await hasOnboarded();
      final example = onboarded
          ? await askPromptRotation.takeNextHomeExample()
          : kHomeAskExamples.first;
      if (!mounted) return;
      setState(() {
        _onboarded = onboarded;
        _homeAskExample = example;
      });
    } catch (_) {
      if (mounted) setState(() => _onboarded = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onboarded = _onboarded;
    if (onboarded == null) {
      return const Scaffold(
        backgroundColor: AppColors.canvas,
        body: SizedBox.shrink(),
      );
    }
    return onboarded
        ? AppLockGate(child: HomeScreen(homeAskExample: _homeAskExample))
        : const OnboardingScreen();
  }
}
