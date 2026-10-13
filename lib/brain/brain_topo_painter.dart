import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/brain/brain_data.dart';

class BrainTopoPainter extends CustomPainter {
  final BandData data;
  final double headRadius;
  final double gridStep;
  final bool showElectrodeText;

  BrainTopoPainter({
    required this.data,
    this.headRadius = 120,
    this.gridStep = 6.0,
    this.showElectrodeText = false,
  });

  static final List<Color> _heatLut = () {
    final lut = List<Color>.filled(256, Colors.black);
    for (int i = 0; i < 256; i++) {
      final ratio = i / 255.0;
      lut[i] = _rawHeatColor(ratio);
    }
    return lut;
  }();

  static Color _rawHeatColor(double ratio) {
    final r = ratio.clamp(0.0, 1.0);
    if (r < 0.25) {
      return Color.lerp(Colors.blue, Colors.cyan, r / 0.25)!;
    } else if (r < 0.50) {
      return Color.lerp(Colors.cyan, Colors.green, (r - 0.25) / 0.25)!;
    } else if (r < 0.75) {
      return Color.lerp(Colors.green, Colors.yellow, (r - 0.50) / 0.25)!;
    } else {
      return Color.lerp(Colors.yellow, Colors.red, (r - 0.75) / 0.25)!;
    }
  }

  static Color getHeatmapLut(double ratio) {
    int idx = (ratio.clamp(0.0, 1.0) * 255).round();
    return _heatLut[idx];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2 - 20, size.height / 2 + 10);

    final headFillPaint = Paint()
    ..isAntiAlias = true
      ..color = Colors.white.withOpacity(0.1)
      ..style = PaintingStyle.fill;
    final headStrokePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: headRadius * 2,
        height: headRadius * 2.2,
      ),
      headFillPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: headRadius * 2,
        height: headRadius * 2.2,
      ),
      headStrokePaint,
    );

    Path nosePath = Path()
      ..moveTo(center.dx, center.dy - headRadius * 1.1)
      ..lineTo(center.dx - 8, center.dy - headRadius * 1.25)
      ..lineTo(center.dx + 8, center.dy - headRadius * 1.25)
      ..close();
    canvas.drawPath(nosePath, headStrokePaint);

    final Paint cellPaint = Paint();
    for (double y = -headRadius * 1.1; y <= headRadius * 1.1; y += gridStep) {
      for (double x = -headRadius; x <= headRadius; x += gridStep) {
        final px = center.dx + x;
        final py = center.dy + y;

        final ellipse = (x / headRadius) * (x / headRadius) +
            (y / (headRadius * 1.1)) * (y / (headRadius * 1.1));
        if (ellipse > 1.0) continue;

        double numerator = 0.0;
        double denominator = 0.0;
        for (final ele in data.electrodes) {
          final ex = ele.dx * headRadius * 2 - headRadius;
          final ey = ele.dy * headRadius * 2.2 - headRadius * 1.1;
          final dist = sqrt(
            pow(px - (center.dx + ex), 2) + pow(py - (center.dy + ey), 2),
          );
          final weight = 1.0 / pow(dist + 0.1, 2);
          numerator += ele.value * weight;
          denominator += weight;
        }

        final val = denominator == 0 ? 0 : numerator / denominator;
        var ratio = (val - data.minVal) / (data.maxVal - data.minVal);
        ratio = ratio.clamp(0.0, 1.0);

        cellPaint.color = getHeatmapLut(ratio).withOpacity(0.85);
        canvas.drawRect(
          Rect.fromLTWH(px, py, gridStep, gridStep),
          cellPaint,
        );
      }
    }

    final dotPaint = Paint()..color = Colors.white;
    for (final ele in data.electrodes) {
      final px = center.dx + (ele.dx * headRadius * 2 - headRadius);
      final py = center.dy + (ele.dy * headRadius * 2.2 - headRadius * 1.1);
      canvas.drawCircle(Offset(px, py), 3, dotPaint);

      if (showElectrodeText) {
        final text = "${ele.name}\n${ele.value.toStringAsFixed(1)}";
        final tp = TextPainter(
          text: TextSpan(
            text: text,
            style: const TextStyle(color: Colors.white, fontSize: 10),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(px + 5, py - 10));
      }
    }

    final barX = size.width - 15;
    final barTop = center.dy - headRadius;
    final barHeight = headRadius * 2;
    final barPaint = Paint();
    for (int i = 0; i < barHeight; i++) {
      final r = 1.0 - i / barHeight;
      barPaint.color = getHeatmapLut(r);
      canvas.drawRect(Rect.fromLTWH(barX, barTop + i, 10, 1), barPaint);
    }

    // TextPainter 必须先 layout() 算出文字几何信息，才能 paint()，
    // 否则会抛 "Text geometry was not yet calculated"。
    (TextPainter(
      text: TextSpan(
        text: "${data.maxVal.toInt()}",
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout())
        .paint(canvas, Offset(barX + 12, barTop - 5));

    (TextPainter(
      text: TextSpan(
        text: "${data.minVal.toInt()}",
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout())
        .paint(canvas, Offset(barX + 12, barTop + barHeight));
  }

  @override
  bool shouldRepaint(covariant BrainTopoPainter oldDelegate) {
    return oldDelegate.data.revision != data.revision ||
        oldDelegate.gridStep != gridStep ||
        oldDelegate.showElectrodeText != showElectrodeText ||
        oldDelegate.headRadius != headRadius;
  }
}
