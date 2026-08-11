import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme/app_colors.dart';
import 'app/theme/app_theme.dart';
import 'features/ask/ask_prompt_rotation.dart';
import 'core/data/providers.dart';
import 'features/library/home_screen.dart';
import 'features/onboarding/onboarding_flow.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/reminders/reminder_service.dart';
import 'features/security/app_lock.dart';

void main() {
  // Needed before reminder plugin init.
  WidgetsFlutterBinding.ensureInitialized();
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

/// First screen from onboarded flag.
class _RootGate extends ConsumerStatefulWidget {
  const _RootGate();

  @override
  ConsumerState<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<_RootGate>
    with WidgetsBindingObserver {
  bool? _onboarded;
  String _homeAskExample = kHomeAskExamples.first;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _restoreReminders();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Taken writes from another isolate; refresh on resume.
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(remindersProvider);
    }
  }

  /// Clear finished + rebook (fire-and-forget).
  Future<void> _restoreReminders() async {
    try {
      final reminders = ref.read(reminderRepositoryProvider);
      await reminders.deleteFinished(DateTime.now());
      await ref.read(reminderServiceProvider).sync(await reminders.all());
    } catch (error) {
      // Don't block startup.
      debugPrint('[Cura.reminders] restore failed: $error');
    }
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
