import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import 'remote_ai_config.dart';

/// The provider picker shared by onboarding and Settings. Flutter's stock
/// dropdown popup uses its own larger menu typography, so the trigger and popup
/// are built here to keep both surfaces on Cura's type and spacing.
class RemoteProviderSelector extends StatelessWidget {
  const RemoteProviderSelector({
    super.key,
    required this.value,
    required this.decoration,
    required this.onChanged,
  });

  final String value;
  final InputDecoration decoration;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final selected = providerById(value);

    return LayoutBuilder(
      builder: (context, constraints) {
        return PopupMenuButton<String>(
          initialValue: selected.id,
          enabled: onChanged != null,
          position: PopupMenuPosition.under,
          offset: const Offset(0, 6),
          constraints: BoxConstraints.tightFor(width: constraints.maxWidth),
          color: AppColors.surface,
          surfaceTintColor: AppColors.surface,
          shadowColor: const Color(0x260A3C30),
          elevation: 5,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppColors.hairline),
          ),
          onSelected: onChanged,
          itemBuilder: (context) => [
            for (final provider in kRemoteProviders)
              PopupMenuItem<String>(
                value: provider.id,
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        provider.label,
                        style: textTheme.bodyLarge?.copyWith(
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    if (provider.id == selected.id)
                      const Icon(
                        Icons.check_rounded,
                        size: 19,
                        color: AppColors.accent,
                      ),
                  ],
                ),
              ),
          ],
          child: InputDecorator(
            isEmpty: false,
            decoration: decoration.copyWith(
              suffixIcon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 21,
                color: AppColors.chevron,
              ),
            ),
            child: Text(
              selected.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyLarge?.copyWith(color: AppColors.ink),
            ),
          ),
        );
      },
    );
  }
}
