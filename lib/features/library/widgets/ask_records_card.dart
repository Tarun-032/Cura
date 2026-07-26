import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/widgets/cura_spark.dart';

/// The mint-tinted "Ask your records" hero card — the entry point into Ask.
class AskRecordsCard extends StatelessWidget {
  const AskRecordsCard({super.key, required this.example, required this.onTap});

  final String example;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: AppColors.mintCardFill,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.mintCardFill,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.mintCardBorder),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // Cura AI-mark tile.
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.canvas,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.mintCardBorder),
                ),
                alignment: Alignment.center,
                child: const CuraSpark(size: 36),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ask your records', style: textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(
                      '"$example"',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.secondary,
                      ),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: AppColors.mint),
            ],
          ),
        ),
      ),
    );
  }
}
