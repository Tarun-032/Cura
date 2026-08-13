import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../library/result_range.dart';
import 'trend_series.dart';

/// Evenly spaced points (not time-scaled); dates under each.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.series, this.compact = false});

  final TrendSeries series;

  /// Home sparkline: shape only.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 22 : 138,
      child: CustomPaint(
        size: Size.infinite,
        painter: _TrendPainter(series, compact),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.series, this.compact);

  final TrendSeries series;
  final bool compact;

  /// Space for two-line date labels.
  static const _labelBand = 34.0;

  @override
  void paint(Canvas canvas, Size size) {
    final points = series.points;
    final inset = compact ? 4.0 : 6.0;
    final plot = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset - (compact ? inset : _labelBand),
    );
    // Normal band when range parses.
    final band = compact ? null : rangeBounds(series.latest.result);

    var lo = points.map((p) => p.value).reduce(math.min);
    var hi = points.map((p) => p.value).reduce(math.max);
    if (band?.low != null) lo = math.min(lo, band!.low!);
    if (band?.high != null) hi = math.max(hi, band!.high!);
    final pad = (hi - lo) * 0.18;
    lo -= pad == 0 ? math.max(hi.abs() * 0.1, 1) : pad;
    hi += pad == 0 ? math.max(hi.abs() * 0.1, 1) : pad;

    // Always ≥2 points.
    final step = plot.width / (points.length - 1);
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
    double x(int i) => plot.left + step * i;

    if (band != null && (band.low != null || band.high != null)) {
      final top = band.high == null ? plot.top : y(band.high!);
      final bottom = band.low == null ? plot.bottom : y(band.low!);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(plot.left, top, plot.right, bottom),
          const Radius.circular(6),
        ),
        Paint()..color = AppColors.mint.withValues(alpha: 0.12),
      );
      // Label the band.
      if (bottom - top >= 16) {
        final tag = _text('normal', 10.5, AppColors.secondary);
        tag.paint(
          canvas,
          Offset(plot.left + 7, (top + bottom) / 2 - tag.height / 2),
        );
      }
    }

    final line = Path()..moveTo(x(0), y(points.first.value));
    for (var i = 1; i < points.length; i++) {
      line.lineTo(x(i), y(points[i].value));
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = AppColors.accent
        ..strokeWidth = compact ? 1.6 : 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Ends always labelled; middles if they fit.
    final everyLabel = step >= 50;

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final verdict = verdictFor(p.result);
      final flagged =
          verdict == RangeVerdict.low ||
          verdict == RangeVerdict.high ||
          (bandFor(p.result)?.abnormal ?? false);
      final centre = Offset(x(i), y(p.value));
      // Sparkline: end point only.
      if (compact && i != points.length - 1) continue;
      canvas.drawCircle(centre, compact ? 3.5 : 4.5, Paint()..color = AppColors.surface);
      canvas.drawCircle(
        centre,
        compact ? 2.5 : 3.5,
        Paint()..color = flagged ? AppColors.destructive : AppColors.mint,
      );
      if (!compact && (everyLabel || i == 0 || i == points.length - 1)) {
        _label(canvas, p, x(i), plot.bottom + 5, plot);
      }
    }
  }

  TextPainter _text(String text, double size, Color color) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'PlusJakartaSans',
        fontSize: size,
        height: 1.25,
        color: color,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout();

  void _label(Canvas canvas, TrendPoint p, double cx, double top, Rect plot) {
    final painter = _text(
      '${p.dateLabel}\n${p.date.year}',
      11.5,
      AppColors.faint,
    );
    final left = (cx - painter.width / 2).clamp(
      plot.left - 6,
      math.max(plot.left - 6, plot.right + 6 - painter.width),
    );
    painter.paint(canvas, Offset(left.toDouble(), top));
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.series != series || old.compact != compact;
}
