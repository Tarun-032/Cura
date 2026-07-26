import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/widgets/document_image.dart';
import '../scan/scan_service.dart';
import 'document.dart';

/// Manual record entry, for visits that produce no printed document. The user
/// types a title and summary, picks a date and type, and can photograph the paper
/// as evidence. Those photos are **kept as pictures only, never OCR'd**.
///
/// Also the edit screen for these records (routed by the `manual-` id prefix),
/// since the scan review screen has no editable summary field. Returns the
/// [CuraDocument] via `Navigator.pop`; the caller persists.
class ManualEntryScreen extends ConsumerStatefulWidget {
  const ManualEntryScreen({super.key, this.existing});

  /// The record being edited, or null to create a new one.
  final CuraDocument? existing;

  @override
  ConsumerState<ManualEntryScreen> createState() => _ManualEntryScreenState();
}

class _ManualEntryScreenState extends ConsumerState<ManualEntryScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _summaryController;
  late DocumentType _type;
  late DateTime _date;
  late List<String> _pages;

  /// Photos captured in this session — deleted again if the user backs out
  /// without saving, so a cancelled entry leaves no orphan files behind.
  final List<String> _newPaths = [];

  bool _busy = false; // scanner open

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _titleController = TextEditingController(text: existing?.title ?? '');
    _summaryController = TextEditingController(
      text: existing?.resultsNote ?? '',
    );
    _type = existing?.type ?? DocumentType.visit;
    _date = existing?.date ?? DateTime.now();
    _pages = [...?existing?.pages];
    // Save enables/disables with the title text.
    _titleController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _summaryController.dispose();
    super.dispose();
  }

  String get _dateLabel {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[_date.month - 1]} ${_date.day}, ${_date.year}';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  /// Opens the document scanner and appends the captured pages. The scanner is
  /// only used for its camera + cropping — recognizePages is never called, so
  /// the photos stay exactly what the user shot.
  Future<void> _addPhotos() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final paths = await ref.read(scanServiceProvider).captureDocument();
      if (paths.isEmpty || !mounted) return;
      setState(() {
        _pages = [..._pages, ...paths];
        _newPaths.addAll(paths);
      });
    } catch (_) {
      if (mounted) _toast('Couldn\'t open the camera');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    final summary = _summaryController.text.trim();
    final doc = CuraDocument(
      id:
          widget.existing?.id ??
          'manual-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      type: _type,
      date: _date,
      resultsNote: summary.isEmpty ? null : summary,
      pages: _pages,
      tags: widget.existing?.tags ?? const [],
    );
    Navigator.of(context).pop(doc);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final canSave = !_busy && _titleController.text.trim().isNotEmpty;
    final editing = widget.existing != null;

    return PopScope(
      // Popping with a document means Save ran; any other pop is a discard, so
      // photos captured this session are removed again (saved ones are kept).
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && result == null && _newPaths.isNotEmpty) {
          ref.read(scanServiceProvider).deleteImages(List.of(_newPaths));
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: AppColors.canvas,
        ),
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                        color: AppColors.ink,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        editing ? 'Edit record' : 'Add record',
                        style: textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    children: [
                      _label('Title'),
                      const SizedBox(height: 8),
                      _FieldBox(
                        child: TextField(
                          controller: _titleController,
                          style: textTheme.bodyLarge,
                          decoration: InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            hintText: 'e.g. Clinic visit for fever',
                            hintStyle: textTheme.bodyLarge?.copyWith(
                              color: AppColors.faint,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      _label('Type'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final t in DocumentType.values)
                            _TypeChip(
                              label: t.label,
                              selected: _type == t,
                              onTap: () => setState(() => _type = t),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      _label('Date'),
                      const SizedBox(height: 8),
                      _FieldBox(
                        onTap: _pickDate,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.calendar_today_outlined,
                              size: 18,
                              color: AppColors.secondary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _dateLabel,
                                style: textTheme.bodyLarge,
                              ),
                            ),
                            const Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: AppColors.faint,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      _label('Summary'),
                      const SizedBox(height: 8),
                      _FieldBox(
                        child: TextField(
                          controller: _summaryController,
                          style: textTheme.bodyMedium?.copyWith(height: 1.5),
                          maxLines: null,
                          minLines: 4,
                          decoration: InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            hintText:
                                'What happened, medicines given, advice, '
                                'symptoms…',
                            hintStyle: textTheme.bodyMedium?.copyWith(
                              color: AppColors.faint,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      _label('Photos (optional)'),
                      const SizedBox(height: 8),
                      if (_pages.isNotEmpty) ...[
                        DocumentPages(
                          paths: _pages,
                          height: 172,
                          openOnTap: !_busy,
                        ),
                        const SizedBox(height: 10),
                      ],
                      InkWell(
                        onTap: _busy ? null : _addPhotos,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.photo_camera_outlined,
                                size: 18,
                                color: AppColors.accent,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _pages.isEmpty
                                    ? 'Add photos'
                                    : 'Add more photos',
                                style: const TextStyle(
                                  fontFamily: 'PlusJakartaSans',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  fontVariations: [FontVariation('wght', 500)],
                                  color: AppColors.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Kept as pictures with the record. Nothing is read '
                        'from them.',
                        style: textTheme.labelSmall?.copyWith(
                          color: AppColors.faint,
                        ),
                      ),
                      const SizedBox(height: 28),

                      SizedBox(
                        height: 54,
                        child: ElevatedButton(
                          onPressed: canSave ? _save : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: AppColors.canvas,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            textStyle: const TextStyle(
                              fontFamily: 'PlusJakartaSans',
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              fontVariations: [FontVariation('wght', 500)],
                            ),
                          ),
                          child: Text(
                            editing ? 'Save changes' : 'Save to device',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'PlusJakartaSans',
        fontSize: 13,
        color: AppColors.secondary,
      ),
    );
  }
}

/// White rounded field container (same look as the review screen's wells).
class _FieldBox extends StatelessWidget {
  const _FieldBox({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: box,
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : AppColors.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.hairline,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontVariations: const [FontVariation('wght', 500)],
              color: selected ? AppColors.canvas : AppColors.secondary,
            ),
          ),
        ),
      ),
    );
  }
}
