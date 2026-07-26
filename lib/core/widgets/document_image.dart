import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Shows a saved scan image in a rounded, hairline-bordered frame. Tapping opens
/// a full-screen zoomable viewer. Used on the Review and Detail screens in place
/// of the hatched placeholder once a real image exists.
class DocumentImage extends StatelessWidget {
  const DocumentImage({
    super.key,
    required this.path,
    required this.height,
    this.openOnTap = true,
  });

  final String path;
  final double height;

  /// Whether tapping opens the full-screen viewer (off during, e.g., re-scan).
  final bool openOnTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: openOnTap
          ? () => openPagesViewer(context, [path], initialIndex: 0)
          : null,
      child: _framed(height: height, child: _image(path, height)),
    );
  }
}

/// Shows a multi-page record: a single [DocumentImage] when there's one page, or
/// a swipeable [PageView] with a "page x of n" pill when there are several.
/// Tapping any page opens the full-screen viewer at that page.
class DocumentPages extends StatefulWidget {
  const DocumentPages({
    super.key,
    required this.paths,
    required this.height,
    this.openOnTap = true,
  });

  final List<String> paths;
  final double height;
  final bool openOnTap;

  @override
  State<DocumentPages> createState() => _DocumentPagesState();
}

class _DocumentPagesState extends State<DocumentPages> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.paths.length <= 1) {
      return DocumentImage(
        path: widget.paths.first,
        height: widget.height,
        openOnTap: widget.openOnTap,
      );
    }
    return Column(
      children: [
        Stack(
          children: [
            SizedBox(
              height: widget.height,
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.paths.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => GestureDetector(
                  onTap: widget.openOnTap
                      ? () => openPagesViewer(context, widget.paths,
                          initialIndex: i)
                      : null,
                  child: _framed(
                    height: widget.height,
                    child: _image(widget.paths[i], widget.height),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: _PagePill(text: '${_index + 1} of ${widget.paths.length}'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Dots(count: widget.paths.length, index: _index),
      ],
    );
  }
}

/// Opens the full-screen, swipeable, zoomable page viewer at [initialIndex].
void openPagesViewer(
  BuildContext context,
  List<String> paths, {
  required int initialIndex,
}) {
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (context, animation, secondary) =>
          _FullScreenPages(paths: paths, initialIndex: initialIndex),
    ),
  );
}

Widget _framed({required double height, required Widget child}) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      child: child,
    ),
  );
}

Widget _image(String path, double height) {
  return Image.file(
    File(path),
    height: height,
    width: double.infinity,
    fit: BoxFit.cover,
    errorBuilder: (context, error, stack) => Container(
      color: AppColors.mintCardFill,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image_outlined, color: AppColors.faint),
    ),
  );
}

class _PagePill extends StatelessWidget {
  const _PagePill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'PlusJakartaSans',
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontVariations: [FontVariation('wght', 500)],
          color: Colors.white,
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? AppColors.accent : AppColors.hairline,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
      ],
    );
  }
}

class _FullScreenPages extends StatefulWidget {
  const _FullScreenPages({required this.paths, required this.initialIndex});

  final List<String> paths;
  final int initialIndex;

  @override
  State<_FullScreenPages> createState() => _FullScreenPagesState();
}

class _FullScreenPagesState extends State<_FullScreenPages> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.paths.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Center(child: Image.file(File(widget.paths[i]))),
              ),
            ),
          ),
          if (widget.paths.length > 1)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 0,
              right: 0,
              child: Center(
                child: _PagePill(
                    text: '${_index + 1} of ${widget.paths.length}'),
              ),
            ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}
