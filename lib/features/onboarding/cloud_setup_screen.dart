import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../ai/ai_providers.dart';
import '../ai/remote/provider_selector.dart';
import '../ai/remote/remote_ai_config.dart';
import '../ai/remote/remote_ai_store.dart';
import '../ai/remote/remote_chat_backend.dart';
import 'voice_setup_screen.dart';

/// Onboarding cloud path: connect an OpenAI-compatible provider with your own
/// key. The Settings cloud form full-screen, always in fresh-setup mode. Saving
/// enables the cloud engine and finishes onboarding.
class CloudSetupScreen extends ConsumerStatefulWidget {
  const CloudSetupScreen({super.key});

  @override
  ConsumerState<CloudSetupScreen> createState() => _CloudSetupScreenState();
}

class _CloudSetupScreenState extends ConsumerState<CloudSetupScreen> {
  bool _obscureKey = true;
  bool _testing = false;

  String _providerId = kRemoteProviders.first.id;
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _modelId = TextEditingController();

  RemoteAiStore get _store => ref.read(remoteAiStoreProvider);

  @override
  void initState() {
    super.initState();
    _baseUrl.text = kRemoteProviders.first.baseUrl;
    _load();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _modelId.dispose();
    super.dispose();
  }

  // Prefill from any previously-saved config (usually empty during onboarding).
  Future<void> _load() async {
    final cfg = await _store.config();
    if (!mounted) return;
    setState(() {
      _providerId = cfg.providerId;
      _baseUrl.text = cfg.baseUrl;
      _apiKey.text = cfg.apiKey;
      _modelId.text = cfg.modelId;
    });
  }

  RemoteAiConfig _current() => RemoteAiConfig(
    providerId: _providerId,
    baseUrl: _baseUrl.text,
    apiKey: _apiKey.text,
    modelId: _modelId.text,
  );

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  void _onProvider(String? id) {
    if (id == null) return;
    final preset = providerById(id);
    setState(() {
      _providerId = id;
      if (!preset.isCustom) _baseUrl.text = preset.baseUrl;
    });
  }

  Future<void> _test() async {
    final cfg = _current();
    if (!cfg.isComplete) {
      _toast('Add an API key and a model id first');
      return;
    }
    setState(() => _testing = true);
    final backend = RemoteChatBackend(cfg);
    try {
      await backend.testConnection();
      if (mounted) _toast('Connection OK');
    } on RemoteAiException catch (e) {
      if (mounted) _toast(e.message);
    } catch (_) {
      if (mounted) _toast('Could not reach the provider');
    } finally {
      backend.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final cfg = _current();
    if (!cfg.isComplete) {
      _toast('Add an API key and a model id first');
      return;
    }
    await _store.saveConfig(cfg);
    // One-time consent — sending text off-device is a real change of posture.
    if (!await _store.consented()) {
      final ok = await _consentDialog(cfg.providerLabel);
      if (ok != true) return;
      await _store.setConsented(true);
    }
    await _store.setEngine(AiEngine.remote);
    if (!mounted) return;
    // Cloud is set up — continue to the optional voice-input step (voice is
    // always on-device, independent of the cloud choice).
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const VoiceSetupScreen()));
  }

  Future<bool?> _consentDialog(String provider) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use a cloud model?'),
        content: Text(
          'Your questions and the document text needed to answer them will be '
          'sent to $provider over the internet. Personal details are stripped '
          'first, but this data leaves your device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final preset = providerById(_providerId);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: AppColors.canvas,
      ),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                      color: AppColors.ink,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Text('Connect a cloud model', style: textTheme.titleLarge),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  children: [
                    Text(
                      'Bring your own API key. Works with OpenRouter, OpenAI, '
                      'Groq, NVIDIA NIM, or any OpenAI-compatible endpoint.',
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppColors.secondary,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _label('Provider', textTheme),
                    RemoteProviderSelector(
                      value: _providerId,
                      decoration: _fieldDecoration(),
                      onChanged: _onProvider,
                    ),
                    const SizedBox(height: 16),
                    _label('Base URL', textTheme),
                    TextField(
                      controller: _baseUrl,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enabled: preset.isCustom,
                      decoration: _fieldDecoration(
                        hint: 'https://…/v1',
                        enabled: preset.isCustom,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _label('API key', textTheme),
                    TextField(
                      controller: _apiKey,
                      obscureText: _obscureKey,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: _fieldDecoration(
                        hint: 'sk-…',
                        suffix: IconButton(
                          icon: Icon(
                            _obscureKey
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 20,
                            color: AppColors.chevron,
                          ),
                          onPressed: () =>
                              setState(() => _obscureKey = !_obscureKey),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _label('Model', textTheme),
                    TextField(
                      controller: _modelId,
                      autocorrect: false,
                      decoration: _fieldDecoration(hint: preset.hint),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Sends your questions and the medical text needed to answer '
                      'them to ${preset.label} over the internet. It leaves this '
                      'device. Personal details (name, address, IDs) are stripped '
                      'first.',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.faint,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton(
                        onPressed: _testing ? null : _test,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.ink,
                          side: const BorderSide(color: AppColors.hairline),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _testing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.secondary,
                                ),
                              )
                            : const Text('Test connection'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.canvas,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          textStyle: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500,
                            fontVariations: [FontVariation('wght', 500)],
                          ),
                        ),
                        child: const Text('Save & use'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text, TextTheme textTheme) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: textTheme.bodySmall),
  );

  InputDecoration _fieldDecoration({
    String? hint,
    Widget? suffix,
    bool enabled = true,
  }) {
    return InputDecoration(
      isDense: true,
      hintText: hint,
      suffixIcon: suffix,
      filled: true,
      fillColor: enabled ? AppColors.surface : AppColors.divider,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent),
      ),
    );
  }
}
