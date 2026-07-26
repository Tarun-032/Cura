import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../document.dart';

/// A single document in a list: category tile + title + "date · type" metadata +
/// chevron. Shared by the Library, Timeline and export screens.
class DocumentRow extends StatelessWidget {
  const DocumentRow({
    super.key,
    required this.document,
    required this.onTap,
    this.metadata,
    this.showChevron = true,
    this.trailing,
  });

  final CuraDocument document;
  final VoidCallback onTap;

  /// Secondary line under the title. Defaults to "date · type".
  final String? metadata;

  /// Whether to show the trailing chevron (Timeline hides it).
  final bool showChevron;

  /// Replaces the chevron when set (the export screen puts a checkbox here).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.hairline),
            boxShadow: [
              BoxShadow(
                color: AppColors.ink.withValues(alpha: 0.04),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // Category tile.
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: document.type.tileColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  document.type.icon,
                  size: 21,
                  color: document.type.accentColor,
                ),
              ),
              const SizedBox(width: 14),
              // Title + metadata.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.title,
                      style: textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      metadata ??
                          '${document.dateLabel} · ${document.type.label}',
                      style: textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ] else if (showChevron) ...[
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right, color: AppColors.chevron),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
