import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/data/providers.dart';
import '../library/document.dart';
import 'trends_view.dart';

/// Full Trends dashboard; watches live docs.
class TrendsScreen extends ConsumerWidget {
  const TrendsScreen({super.key, required this.onOpenDocument});

  final ValueChanged<CuraDocument> onOpenDocument;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documents = ref.watch(documentsProvider).value ?? const [];

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.ink),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: TrendsView(
          documents: documents,
          onOpenDocument: onOpenDocument,
        ),
      ),
    );
  }
}
