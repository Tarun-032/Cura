import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../app/theme/app_colors.dart';
import '../reminders/widgets/reminder_bell.dart';
import '../reminders/widgets/today_medicines_card.dart';
import '../trends/trends_card.dart';
import 'document.dart';
import 'document_search.dart';
import 'widgets/ask_records_card.dart';
import 'widgets/document_row.dart';

/// Home list: greeting, search, filters, docs.
class LibraryView extends StatefulWidget {
  const LibraryView({
    super.key,
    required this.documents,
    required this.homeAskExample,
    required this.onOpenDocument,
    required this.onOpenAsk,
    required this.onOpenTrends,
  });

  final List<CuraDocument> documents;
  final String homeAskExample;
  final ValueChanged<CuraDocument> onOpenDocument;
  final VoidCallback onOpenAsk;
  final VoidCallback onOpenTrends;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  // null = "All".
  DocumentType? _filter;
  final _searchController = TextEditingController();
  String _query = '';

  static const Duration _enter = Duration(milliseconds: 250);
  static const Curve _curve = Curves.easeOutCubic;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _searching => _query.trim().isNotEmpty;

  /// Type chip, then text query.
  List<CuraDocument> get _filtered {
    var list = widget.documents;
    final f = _filter;
    if (f != null) list = list.where((d) => d.type == f).toList();
    if (_searching) list = searchDocuments(list, _query);
    return list;
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final rows = _filtered;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
      children: [
        // Header + bell.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _greeting,
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.secondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('Your records', style: textTheme.headlineMedium),
                ],
              ),
            ),
            const ReminderBell(),
          ],
        ).animate().fadeIn(duration: _enter).slideY(begin: 0.15, curve: _curve),

        const SizedBox(height: 18),
        _SearchField(
          controller: _searchController,
          onChanged: (q) => setState(() => _query = q),
        )
            .animate()
            .fadeIn(duration: _enter, delay: 40.ms)
            .slideY(begin: 0.15, curve: _curve),

        const SizedBox(height: 14),
        _FilterChips(
          selected: _filter,
          onSelect: (f) => setState(() => _filter = f),
        ).animate().fadeIn(duration: _enter, delay: 80.ms).slideY(
              begin: 0.15,
              curve: _curve,
            ),

        const SizedBox(height: 18),
        AskRecordsCard(example: widget.homeAskExample, onTap: widget.onOpenAsk)
            .animate()
            .fadeIn(duration: _enter, delay: 120.ms)
            .slideY(begin: 0.15, curve: _curve),

        // Hides itself when empty.
        const TodayMedicinesCard(),

        // Trends card when something repeats.
        TrendsCard(
          documents: widget.documents,
          onTap: widget.onOpenTrends,
        ),

        const SizedBox(height: 22),
        Text(_searching ? 'Results' : 'Recent', style: textTheme.bodySmall)
            .animate()
            .fadeIn(duration: _enter, delay: 160.ms),

        const SizedBox(height: 12),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _searching
                  ? 'No records match “${_query.trim()}”.'
                  : 'No records in this category yet.',
              style: textTheme.bodyMedium?.copyWith(color: AppColors.faint),
            ),
          )
        else
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _row(rows[i], i),
          ],
      ],
    );
  }

  // Animate on load; skip while searching.
  Widget _row(CuraDocument doc, int i) {
    final row = DocumentRow(
      document: doc,
      onTap: () => widget.onOpenDocument(doc),
    );
    // Animate first screenful only.
    if (_searching || i > 6) return row;
    return row
        .animate()
        .fadeIn(duration: _enter, delay: (200 + i * 40).ms)
        .slideY(begin: 0.15, curve: _curve);
  }
}

/// Search field (filters live in [LibraryView]).
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 20, color: AppColors.faint),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: textTheme.bodyMedium,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search your records',
                hintStyle:
                    textTheme.bodyMedium?.copyWith(color: AppColors.faint),
              ),
            ),
          ),
          // Clear when non-empty.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox(width: 4)
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      controller.clear();
                      onChanged('');
                    },
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.close, size: 18, color: AppColors.faint),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Filter chip row. null selection = "All".
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onSelect});

  final DocumentType? selected;
  final ValueChanged<DocumentType?> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _chip(context, 'All', null),
          _chip(context, 'Prescriptions', DocumentType.prescription),
          _chip(context, 'Labs', DocumentType.lab),
          _chip(context, 'Receipts', DocumentType.receipt),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, DocumentType? value) {
    final active = selected == value;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: active ? AppColors.accent : AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: () => onSelect(value),
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            decoration: BoxDecoration(
              color: active ? AppColors.accent : AppColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: active ? AppColors.accent : AppColors.hairline,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontVariations: const [FontVariation('wght', 500)],
                color: active ? AppColors.canvas : AppColors.secondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
