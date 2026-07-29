import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/widgets/cura_spark.dart';
import '../ai/ai_models.dart';
import '../ai/ai_providers.dart';
import '../ai/model_download.dart';
import '../ai/remote/provider_selector.dart';
import '../ai/remote/remote_ai_config.dart';
import '../ai/remote/remote_ai_store.dart';
import '../ai/remote/remote_chat_backend.dart';
import '../ai/widgets/model_download_sheet.dart';
import '../ask/voice_input_controller.dart';
import '../ask/voice_model_sheet.dart';
import '../security/app_lock.dart';
import 'privacy_policy_screen.dart';
import 'storage_info.dart';
import 'storage_screen.dart';

/// Settings: data controls, AI model settings,
/// voice input, and about/privacy details. Grouped white cards with hairline
/// row dividers.
class SettingsView extends ConsumerWidget {
  const SettingsView({
    super.key,
    required this.onExport,
    required this.onDeleteAll,
  });

  final VoidCallback onExport;
  final VoidCallback onDeleteAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
      children:
          [
                Text('Settings', style: textTheme.headlineMedium),
                const SizedBox(height: 20),

                // App-level settings stay together at the top, ahead of the
                // model cards. Storage first, then the data lifecycle, with the
                // destructive action last.
                SettingsGroup(
                  label: 'General',
                  rows: [
                    const _NotificationsRow(),
                    SettingsRow(
                      icon: Icons.donut_small_outlined,
                      iconColor: AppColors.accent,
                      tileColor: AppColors.softTint,
                      title: 'Storage',
                      subtitle: switch (ref
                          .watch(storageBreakdownProvider)
                          .value) {
                        null => 'Checking…',
                        final b => '${formatBytes(b.total)} used',
                      },
                      trailing: const SettingsChevron(),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const StorageScreen(),
                        ),
                      ),
                    ),
                    SettingsRow(
                      icon: Icons.file_upload_outlined,
                      iconColor: AppColors.secondary,
                      tileColor: AppColors.divider,
                      title: 'Export all data',
                      trailing: const SettingsChevron(),
                      onTap: onExport,
                    ),
                    SettingsRow(
                      icon: Icons.delete_outline,
                      iconColor: AppColors.destructive,
                      tileColor: AppColors.destructiveTint,
                      title: 'Delete all data',
                      titleColor: AppColors.destructive,
                      trailing: const SettingsChevron(),
                      onTap: onDeleteAll,
                    ),
                  ],
                ),
                const SizedBox(height: 22),

                // Opt-in biometric app lock, off by default.
                const _SecuritySection(),
                const SizedBox(height: 22),

                // On-device AI model — real download / switch / delete management.
                const _AiModelSection(),
                const SizedBox(height: 22),

                // Optional cloud model, off by default.
                const _CloudModelSection(),
                const SizedBox(height: 22),

                // On-device voice input model (Whisper), download / delete.
                const _VoiceModelSection(),
                const SizedBox(height: 22),

                // About keeps the static app details together without adding
                // another navigation layer to this already scrollable screen.
                SettingsGroup(
                  label: 'About',
                  rows: [
                    SettingsRow(
                      icon: Icons.info_outline,
                      iconColor: AppColors.secondary,
                      tileColor: AppColors.divider,
                      title: 'Version',
                      trailing: Text(
                        '1.0.0',
                        style: textTheme.bodyMedium?.copyWith(
                          color: AppColors.faint,
                        ),
                      ),
                    ),
                    SettingsRow(
                      icon: Icons.shield_outlined,
                      iconColor: AppColors.accent,
                      tileColor: AppColors.softTint,
                      title: 'Privacy policy',
                      subtitle: 'Read more',
                      trailing: const SettingsChevron(),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PrivacyPolicyScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Cura organizes and explains your documents. It does not provide '
                  'medical advice. Always consult a qualified healthcare professional.',
                  style: textTheme.bodySmall?.copyWith(height: 1.5),
                ),
              ]
              .animate(interval: 60.ms)
              .fadeIn(duration: 350.ms)
              .slideY(begin: 0.1, curve: Curves.easeOutCubic),
    );
  }
}

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.label, required this.rows});

  final String label;

  /// Not `List<SettingsRow>`: a row that owns state, like the notification
  /// permission, is a widget of its own that returns one.
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.bodySmall?.copyWith(color: AppColors.secondary),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    indent: 64,
                    color: AppColors.divider,
                  ),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.tileColor,
    required this.title,
    this.titleColor = AppColors.ink,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final Color tileColor;
  final String title;
  final Color titleColor;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: tileColor,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.bodyMedium?.copyWith(color: titleColor),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: textTheme.bodySmall),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: content,
    );
  }
}

class SettingsChevron extends StatelessWidget {
  const SettingsChevron({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.chevron_right, color: AppColors.chevron, size: 22);
  }
}

/// The biometric app-lock toggle. Turning it on needs a screen lock and one
/// successful auth.
class _SecuritySection extends StatefulWidget {
  const _SecuritySection();

  @override
  State<_SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<_SecuritySection> {
  final BiometricAuth _auth = BiometricAuth();
  bool _enabled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    isAppLockEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _onToggle(bool wantOn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (wantOn) {
        if (!await _auth.canAuthenticate()) {
          if (mounted) {
            _toast(
              'Set up a fingerprint or screen lock in your phone settings first',
            );
          }
          return;
        }
        if (!await _auth.authenticate('Confirm to turn on Cura app lock')) {
          return; // cancelled — leave it off
        }
      }
      await setAppLockEnabled(wantOn);
      if (mounted) setState(() => _enabled = wantOn);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      label: 'Security',
      rows: [
        SettingsRow(
          icon: Icons.fingerprint,
          iconColor: AppColors.accent,
          tileColor: AppColors.softTint,
          title: 'App lock',
          subtitle: 'Require fingerprint to open Cura',
          trailing: Switch(
            value: _enabled,
            onChanged: _busy ? null : _onToggle,
            activeThumbColor: AppColors.accent,
          ),
        ),
      ],
    );
  }
}

/// Whether Cura may post notifications
class _NotificationsRow extends StatefulWidget {
  const _NotificationsRow();

  @override
  State<_NotificationsRow> createState() => _NotificationsRowState();
}

class _NotificationsRowState extends State<_NotificationsRow>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.cura.cura/device');

  bool _granted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The user turns this on in a different app, so re-read it on the way back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final status = await FileDownloader().permissions.status(
      PermissionType.notifications,
    );
    if (mounted) {
      setState(() => _granted = status == PermissionStatus.granted);
    }
  }

  Future<void> _onTap() async {
    if (!_granted) {
      await FileDownloader().permissions.request(PermissionType.notifications);
      await _refresh();
      if (_granted) return; // the system prompt did it
    }
    // Already on, or refused often enough that Android no longer prompts.
    await _channel.invokeMethod<void>('openNotificationSettings');
  }

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      icon: _granted
          ? Icons.notifications_active_outlined
          : Icons.notifications_none,
      iconColor: _granted ? AppColors.accent : AppColors.secondary,
      tileColor: _granted ? AppColors.softTint : AppColors.divider,
      title: 'Notifications',
      subtitle: _granted
          ? 'Tap to change'
          : 'Off, Tap to allow',
      trailing: const SettingsChevron(),
      onTap: _onTap,
    );
  }
}

/// On-device AI model management
class _AiModelSection extends ConsumerStatefulWidget {
  const _AiModelSection();

  @override
  ConsumerState<_AiModelSection> createState() => _AiModelSectionState();
}

class _AiModelSectionState extends ConsumerState<_AiModelSection> {
  bool _expanded = false;

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _download(AiModel model) async {
    // Only one at a time, so note it rather than open a dead sheet.
    if (await warnIfAnotherModelIsDownloading(context, ref, model)) return;
    if (!mounted) return;
    final ok = await ModelDownloadSheet.show(context, model) ?? false;
    if (ok) {
      ref.invalidate(aiServiceProvider);
      ref.invalidate(aiModelStateProvider);
    }
  }

  Future<void> _use(AiModel model) async {
    await ref.read(aiModelManagerProvider).activate(model);
    // Making an on-device model the main one also switches the engine off cloud
    // (the cloud toggle reflects this via activeEngineProvider).
    await ref.read(remoteAiStoreProvider).setEngine(AiEngine.local);
    ref.invalidate(aiServiceProvider);
    ref.invalidate(aiModelStateProvider);
    ref.invalidate(activeEngineProvider);
    _toast('Now using ${model.displayName}');
  }

  Future<void> _delete(AiModel model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this model?'),
        content: Text(
          '${model.displayName} (${model.sizeLabel}) will be removed from this '
          'device. You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(aiModelManagerProvider).delete(model);
    ref.invalidate(aiServiceProvider);
    ref.invalidate(aiModelStateProvider);
    _toast('Model deleted');
  }

  Future<void> _deleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all models?'),
        content: const Text(
          'Every downloaded model will be removed from this device, freeing up '
          'storage. You can download them again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Release any loaded model before deleting its file.
    ref.invalidate(aiServiceProvider);
    await ref.read(aiModelManagerProvider).deleteAll();
    ref.invalidate(aiModelStateProvider);
    _toast('All models deleted');
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Reactive install/active state, shared with the Ask screen — so a download
    // or switch there is reflected here without reopening the app.
    final state = ref.watch(aiModelStateProvider).value;
    final loading = state == null;
    final active = state?.active;
    final installed = state?.installed ?? const <String>{};
    // When cloud is the active engine, no on-device model is "in use" — so we
    // don't flag any as active and every downloaded model offers a "Use" button
    final onCloud = ref.watch(activeEngineProvider).value?.isRemote ?? false;
    final localActive = onCloud ? null : active;
    // Watched here, not per row, so the card can say so while collapsed.
    final download = ref.watch(llmDownloadProvider);
    final downloadingModel = (download?.running ?? false)
        ? aiModelByFileName(download!.fileName)
        : null;

    final (String headline, String? detail) = switch ((
      downloadingModel,
      loading,
      active,
    )) {
      // First, since collapsed hides the rows' bars.
      (final m?, _, _) => (m.displayName, 'Downloading… ${download!.percent}%'),
      (_, true, _) => ('Checking…', null),
      (_, _, final a?) => (a.displayName, a.sizeLabel),
      _ => ('No model', 'Not downloaded yet'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'On-device Model',
          style: textTheme.bodySmall?.copyWith(color: AppColors.secondary),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            children: [
              // Header — current model + expand toggle.
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.softTint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const CuraSpark(size: 32),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(headline, style: textTheme.bodyMedium),
                            if (detail != null) ...[
                              const SizedBox(height: 2),
                              Text(detail, style: textTheme.bodySmall),
                            ],
                          ],
                        ),
                      ),
                      if (localActive != null && !_expanded) ...[
                        const _StatusPill(),
                        const SizedBox(width: 8),
                      ],
                      AnimatedRotation(
                        turns: _expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: const Icon(
                          Icons.chevron_right,
                          color: AppColors.chevron,
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Expanded catalog.
              if (_expanded)
                for (final model in kAiModelCatalog) ...[
                  const Divider(
                    height: 1,
                    thickness: 1,
                    indent: 16,
                    endIndent: 16,
                    color: AppColors.divider,
                  ),
                  _ModelRow(
                    model: model,
                    installed: installed.contains(model.id),
                    active: localActive?.id == model.id,
                    downloading: downloadingModel?.id == model.id
                        ? download!.percent
                        : null,
                    onCancel: () =>
                        ref.read(modelDownloaderProvider).cancel(kLlmDownload),
                    onDownload: () => _download(model),
                    onUse: () => _use(model),
                    onDelete: () => _delete(model),
                  ),
                ],
              // Wipe every downloaded model at once — only worth showing when
              // there's at least one on disk.
              if (_expanded && installed.isNotEmpty) ...[
                const Divider(
                  height: 1,
                  thickness: 1,
                  indent: 16,
                  endIndent: 16,
                  color: AppColors.divider,
                ),
                InkWell(
                  onTap: _deleteAll,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: AppColors.destructive,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Delete all models',
                          style: textTheme.bodyMedium?.copyWith(
                            color: AppColors.destructive,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// On-device voice-input model (Whisper). One model, so this is a single card —
/// status plus a Download or Delete action. Voice always runs fully on-device.
class _VoiceModelSection extends ConsumerStatefulWidget {
  const _VoiceModelSection();

  @override
  ConsumerState<_VoiceModelSection> createState() => _VoiceModelSectionState();
}

class _VoiceModelSectionState extends ConsumerState<_VoiceModelSection> {
  final VoiceInputController _voice = VoiceInputController();

  @override
  void dispose() {
    _voice.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _download() async {
    final ok = await VoiceModelSheet.show(context, _voice) ?? false;
    if (ok) ref.invalidate(voiceModelReadyProvider);
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete the voice model?'),
        content: const Text(
          'The voice model (${VoiceInputController.modelSizeLabel}) will be '
          'removed from this device. You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _voice.deleteModel();
    ref.invalidate(voiceModelReadyProvider);
    _toast('Voice model deleted');
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Watch shared state so a download from the Ask mic (or onboarding) shows
    // up here even though this tab stays mounted in the IndexedStack. null =
    // still checking.
    final ready = ref.watch(voiceModelReadyProvider).value;
    // Shows here wherever it was started: this row, Ask, or onboarding.
    final download = ref.watch(voiceDownloadProvider);
    final percent = (download?.running ?? false) ? download!.percent : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Voice input',
          style: textTheme.bodySmall?.copyWith(color: AppColors.secondary),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.softTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.mic_none,
                  size: 20,
                  color: AppColors.mint,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Whisper for Voice Input',
                      style: textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    if (percent != null) ...[
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          // Indeterminate until the first real tick.
                          value: percent > 0 ? percent / 100 : null,
                          minHeight: 4,
                          backgroundColor: AppColors.hairline,
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        percent > 0 ? 'Downloading… $percent%' : 'Starting…',
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.accent,
                        ),
                      ),
                    ] else
                      Text(
                        ready == null
                            ? 'Checking…'
                            : ready
                            ? 'Downloaded · ${VoiceInputController.modelSizeLabel}'
                            : 'Not downloaded yet',
                        style: textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              // Cancel here as well as on the notification, since this is where
              // the user is watching the bar.
              if (percent != null)
                TextButton(
                  onPressed: () =>
                      ref.read(modelDownloaderProvider).cancel(kVoiceDownload),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.secondary,
                  ),
                  child: const Text('Cancel'),
                )
              else if (ready == false)
                TextButton(
                  onPressed: _download,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                  ),
                  child: const Text('Download'),
                )
              else if (ready == true)
                IconButton(
                  onPressed: _delete,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppColors.destructive,
                    size: 22,
                  ),
                  tooltip: 'Delete',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One catalog model row inside the expanded model section.
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.installed,
    required this.active,
    required this.downloading,
    required this.onCancel,
    required this.onDownload,
    required this.onUse,
    required this.onDelete,
  });

  final AiModel model;
  final bool installed;
  final bool active;

  /// 0-100 while this model is the one being fetched, else null.
  final int? downloading;

  final VoidCallback onCancel;
  final VoidCallback onDownload;
  final VoidCallback onUse;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final percent = downloading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(model.displayName, style: textTheme.bodyMedium),
                const SizedBox(height: 2),
                if (percent != null) ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      // Indeterminate until the first real tick.
                      value: percent > 0 ? percent / 100 : null,
                      minHeight: 4,
                      backgroundColor: AppColors.hairline,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    percent > 0 ? 'Downloading… $percent%' : 'Starting…',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.accent,
                    ),
                  ),
                ] else
                  Text(
                    active
                        ? 'In use · ${model.sizeLabel}'
                        : installed
                        ? 'Downloaded · ${model.sizeLabel}'
                        : model.sizeLabel,
                    style: textTheme.bodySmall?.copyWith(
                      color: active ? AppColors.accent : AppColors.faint,
                    ),
                  ),
              ],
            ),
          ),
          // Cancel here as well as on the notification, since this is where the
          // user is watching the bar.
          if (percent != null)
            TextButton(
              onPressed: onCancel,
              style: TextButton.styleFrom(foregroundColor: AppColors.secondary),
              child: const Text('Cancel'),
            )
          else if (!installed)
            TextButton(
              onPressed: onDownload,
              style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              child: const Text('Download'),
            )
          else ...[
            if (!active)
              TextButton(
                onPressed: onUse,
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
                child: const Text('Use'),
              ),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(
                Icons.delete_outline,
                color: AppColors.destructive,
                size: 22,
              ),
              tooltip: 'Delete',
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.softTint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 14, color: AppColors.accent),
          SizedBox(width: 4),
          Text(
            'Ready',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              fontVariations: [FontVariation('wght', 500)],
              color: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }
}

/// The optional bring-your-own-key cloud model. Any OpenAI-compatible provider
/// can answer Ask and refine scans. It sends document text off-device, so it is
/// **off by default** and needs a one-time consent to turn on.
class _CloudModelSection extends ConsumerStatefulWidget {
  const _CloudModelSection();

  @override
  ConsumerState<_CloudModelSection> createState() => _CloudModelSectionState();
}

class _CloudModelSectionState extends ConsumerState<_CloudModelSection> {
  bool _expanded = false; // config form visible
  bool _cloudOn = false; // the on/off switch position (intent to use cloud)
  bool _loaded = false; // initial config pulled from the store
  bool _remoteActive = false; // engine == remote and config complete
  bool _editing = false; // fields unlocked for editing (else read-only)
  bool _dirty = false; // a field changed since load/save → show "Save changes"
  bool _testing = false;
  bool _obscureKey = true;

  String _providerId = kRemoteProviders.first.id;
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _modelId = TextEditingController();

  RemoteAiStore get _store => ref.read(remoteAiStoreProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _modelId.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await _store.config();
    final engine = await _store.engine();
    if (!mounted) return;
    setState(() {
      _providerId = cfg.providerId;
      _baseUrl.text = cfg.baseUrl;
      _apiKey.text = cfg.apiKey;
      _modelId.text = cfg.modelId;
      _remoteActive = engine == AiEngine.remote && cfg.isComplete;
      _cloudOn = _remoteActive;
      _editing = false;
      _dirty = false;
      _loaded = true;
    });
  }

  // Marks the form dirty so "Save changes" appears — only after a real edit.
  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  // The header on/off switch. Turning it ON pops the config menu open (the engine
  // only flips to cloud on Save, which owns the consent gate). Turning it OFF
  // switches straight back to the on-device model and collapses.
  Future<void> _onToggle(bool on) async {
    if (!on) {
      await _useOnDevice();
      return;
    }
    final complete =
        _apiKey.text.trim().isNotEmpty && _modelId.text.trim().isNotEmpty;
    if (complete) {
      // A saved config is ready — switch straight to it (consent may prompt once)
      // and collapse to the summary. No need to reopen the form.
      await _enable();
      // If the one-time consent was declined, flip the switch back off.
      if (mounted && !_remoteActive) setState(() => _cloudOn = false);
      return;
    }
    // Fresh setup — open the form, editable, to enter credentials.
    setState(() {
      _cloudOn = true;
      _expanded = true;
      _editing = true;
      _dirty = false;
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
      _dirty = true;
      // Prefill the base URL from the preset — except Custom, which the user owns.
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

  Future<void> _enable() async {
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
    ref.invalidate(aiServiceProvider);
    ref.invalidate(activeEngineProvider);
    if (!mounted) return;
    // Collapse to the compact "in use · model" summary.
    setState(() {
      _remoteActive = true;
      _cloudOn = true;
      _expanded = false;
      _editing = false;
      _dirty = false;
    });
    _toast('Now using ${cfg.displayName}');
  }

  Future<void> _useOnDevice() async {
    await _store.saveConfig(_current()); // keep any edits
    await _store.setEngine(AiEngine.local);
    ref.invalidate(aiServiceProvider);
    ref.invalidate(activeEngineProvider);
    if (!mounted) return;
    setState(() {
      _remoteActive = false;
      _cloudOn = false;
      _expanded = false;
    });
    _toast('Back to the on-device model');
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear cloud settings?'),
        content: const Text(
          'Your API key and cloud settings will be removed from this device and '
          'Cura will use the on-device model.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.clear();
    ref.invalidate(aiServiceProvider);
    ref.invalidate(activeEngineProvider);
    if (!mounted) return;
    setState(() {
      _apiKey.clear();
      _modelId.clear();
      _remoteActive = false;
      _cloudOn = false;
      _expanded = false;
    });
    _toast('Cloud model disconnected');
  }

  Future<bool?> _consentDialog(String provider) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use a cloud model?'),
        content: Text(
          'Your questions and the document text needed to answer them will be '
          'sent to $provider over the internet. That data leaves this device. '
          'Cura stays on-device by default and you can switch back anytime. '
          'Only enable this if you\'re comfortable with that.',
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
    // Keep the toggle in sync with the active engine when it changes elsewhere —
    // e.g. selecting an on-device model (here or on Ask) turns cloud off, so the
    // switch must visibly flip off too.
    ref.listen(activeEngineProvider, (prev, next) {
      final remote = next.value?.isRemote ?? false;
      if (!remote && _remoteActive) {
        setState(() {
          _remoteActive = false;
          _cloudOn = false;
          _expanded = false;
        });
      } else if (remote && !_remoteActive) {
        setState(() {
          _remoteActive = true;
          _cloudOn = true;
        });
      }
    });
    final subtitle = !_loaded
        ? 'Checking…'
        : !_cloudOn
        ? 'Off. Bring your own API key'
        : _remoteActive && !_expanded
        ? 'In use · ${_modelId.text}'
        : 'Enter your provider and key';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cloud model (optional)',
          style: textTheme.bodySmall?.copyWith(color: AppColors.secondary),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            children: [
              // Header — on/off switch is the primary control. When cloud is on
              // and saved, the text area is tappable to re-open the form to edit.
              InkWell(
                onTap: (_cloudOn && _remoteActive)
                    ? () => setState(() {
                        if (_expanded) {
                          _expanded = false;
                        } else {
                          // Open in read-only view mode; "Edit" unlocks fields.
                          _expanded = true;
                          _editing = false;
                          _dirty = false;
                        }
                      })
                    : null,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.softTint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.cloud_outlined,
                          size: 20,
                          color: AppColors.mint,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Cloud model',
                              style: textTheme.bodyMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: textTheme.bodySmall,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Chevron whenever there's a saved config to open/edit, so
                      // it's clear the row is tappable. Rotates when expanded.
                      if (_cloudOn && _remoteActive)
                        AnimatedRotation(
                          turns: _expanded ? 0.25 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: const Icon(
                            Icons.chevron_right,
                            color: AppColors.chevron,
                            size: 22,
                          ),
                        ),
                      Switch(
                        value: _cloudOn,
                        onChanged: _loaded ? _onToggle : null,
                        activeThumbColor: AppColors.accent,
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded) ...[
                const Divider(
                  height: 1,
                  thickness: 1,
                  indent: 16,
                  endIndent: 16,
                  color: AppColors.divider,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Provider preset.
                      Text('Provider', style: textTheme.bodySmall),
                      const SizedBox(height: 6),
                      RemoteProviderSelector(
                        value: _providerId,
                        decoration: _fieldDecoration(enabled: _editing),
                        onChanged: _editing ? _onProvider : null,
                      ),
                      const SizedBox(height: 12),
                      _label('Base URL', textTheme),
                      TextField(
                        controller: _baseUrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enabled: _editing && preset.isCustom,
                        onChanged: (_) => _markDirty(),
                        decoration: _fieldDecoration(
                          hint: 'https://…/v1',
                          enabled: _editing && preset.isCustom,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _label('API key', textTheme),
                      TextField(
                        controller: _apiKey,
                        obscureText: _obscureKey,
                        autocorrect: false,
                        enableSuggestions: false,
                        enabled: _editing,
                        onChanged: (_) => _markDirty(),
                        decoration: _fieldDecoration(
                          hint: 'sk-…',
                          enabled: _editing,
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
                      const SizedBox(height: 12),
                      _label('Model', textTheme),
                      TextField(
                        controller: _modelId,
                        autocorrect: false,
                        enabled: _editing,
                        onChanged: (_) => _markDirty(),
                        decoration: _fieldDecoration(
                          hint: preset.hint,
                          enabled: _editing,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Sends your questions and document text to '
                        '${preset.label} over the internet. It leaves this '
                        'device. On-device stays the default.',
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.faint,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Primary action: "Save changes" once an edit is pending
                      // (it saves + switches to cloud + collapses); otherwise
                      // "Edit" to unlock a saved config for changes.
                      if (_editing && _dirty)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _enable,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.accent,
                            ),
                            child: Text(
                              _remoteActive
                                  ? 'Save changes'
                                  : 'Use cloud model',
                            ),
                          ),
                        )
                      else if (!_editing)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () => setState(() {
                              _editing = true;
                              _dirty = false;
                            }),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.accent,
                            ),
                            child: const Text('Edit'),
                          ),
                        ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _testing ? null : _test,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.ink,
                            side: const BorderSide(color: AppColors.hairline),
                          ),
                          child: _testing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.secondary,
                                  ),
                                )
                              : const Text('Test connection'),
                        ),
                      ),
                      // Secondary actions on one line: switch back to on-device
                      // (left) and clear the saved key/settings (right).
                      if (_remoteActive ||
                          (_loaded &&
                              (_apiKey.text.trim().isNotEmpty ||
                                  _modelId.text.trim().isNotEmpty))) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (_remoteActive)
                              TextButton(
                                onPressed: _useOnDevice,
                                style: TextButton.styleFrom(
                                  foregroundColor: AppColors.secondary,
                                  padding: EdgeInsets.zero,
                                ),
                                child: const Text('Use on-device instead'),
                              ),
                            const Spacer(),
                            if (_loaded &&
                                (_apiKey.text.trim().isNotEmpty ||
                                    _modelId.text.trim().isNotEmpty))
                              TextButton(
                                onPressed: _disconnect,
                                style: TextButton.styleFrom(
                                  foregroundColor: AppColors.destructive,
                                  padding: EdgeInsets.zero,
                                ),
                                child: const Text('Clear config'),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
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
      fillColor: enabled ? AppColors.canvas : AppColors.divider,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
