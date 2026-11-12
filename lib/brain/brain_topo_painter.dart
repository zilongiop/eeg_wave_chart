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
    final double radiusX = headRadius;
    final double radiusY = headRadius * 1.1;
    final Rect headRect = Rect.fromCenter(
      center: center,
      width: radiusX * 2,
      height: radiusY * 2,
    );
    // 填充、裁剪、描边复用同一条轮廓，保证热力区域边界与圆圈严格重合。
    final Path headPath = Path()..addOval(headRect);

    final headFillPaint = Paint()
      ..isAntiAlias = true
      ..color = Colors.white.withOpacity(0.1)
      ..style = PaintingStyle.fill;
    // 描边放到热力格子之后画；半透明白只淡淡勾出头部轮廓，不抢热力图。
    final headStrokePaint = Paint()
      ..isAntiAlias = true
      ..color = const Color(0xB3FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawPath(headPath, headFillPaint);

    // 逐格矩形直接画到椭圆外会形成台阶状锯齿。按轮廓做抗锯齿裁剪后，
    // 越界的格子被椭圆曲线切掉，边缘与描边一致。
    canvas.save();
    canvas.clipPath(headPath);

    // 电极坐标与格点无关，提到循环外只算一次。
    final List<Offset> electrodeOffsets = <Offset>[
      for (final Electrode ele in data.electrodes)
        Offset(ele.dx * radiusX * 2 - radiusX, ele.dy * radiusY * 2 - radiusY),
    ];
    final Paint cellPaint = Paint();
    for (double y = -radiusY; y <= radiusY; y += gridStep) {
      for (double x = -radiusX; x <= radiusX; x += gridStep) {
        // 用格子中心判定归属：原来按左上角判定，格子会整体向右下外扩一格。
        final double cx = x + gridStep / 2;
        final double cy = y + gridStep / 2;
        final ellipse =
            (cx / radiusX) * (cx / radiusX) + (cy / radiusY) * (cy / radiusY);
        if (ellipse > 1.0) continue;

        double numerator = 0.0;
        double denominator = 0.0;
        for (int i = 0; i < electrodeOffsets.length; i++) {
          final Offset ele = electrodeOffsets[i];
          final double dx = cx - ele.dx;
          final double dy = cy - ele.dy;
          final double dist = sqrt(dx * dx + dy * dy) + 0.1;
          final double weight = 1.0 / (dist * dist);
          numerator += data.electrodes[i].value * weight;
          denominator += weight;
        }

        final val = denominator == 0 ? 0 : numerator / denominator;
        final double ratio =
            ((val - data.minVal) / (data.maxVal - data.minVal)).clamp(0.0, 1.0);

        cellPaint.color = getHeatmapLut(ratio).withOpacity(0.85);
        // 略大于步长，消除相邻矩形因浮点取整留下的细缝。
        canvas.drawRect(
          Rect.fromLTWH(
            center.dx + x,
            center.dy + y,
            gridStep + 0.5,
            gridStep + 0.5,
          ),
          cellPaint,
        );
      }
    }
    canvas.restore();

    final dotPaint = Paint()..color = Colors.white;
    for (int i = 0; i < data.electrodes.length; i++) {
      final Electrode ele = data.electrodes[i];
      final px = center.dx + electrodeOffsets[i].dx;
      final py = center.dy + electrodeOffsets[i].dy;
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

    // 轮廓与鼻子最后画，避免被热力格子覆盖；抗锯齿描边同时压住裁剪后
    // 可能残留的半像素毛边。
    canvas.drawPath(headPath, headStrokePaint);
    final Path nosePath = Path()
      ..moveTo(center.dx, center.dy - radiusY)
      ..lineTo(center.dx - 8, center.dy - radiusY - headRadius * 0.15)
      ..lineTo(center.dx + 8, center.dy - radiusY - headRadius * 0.15)
      ..close();
    canvas.drawPath(nosePath, headStrokePaint);

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
