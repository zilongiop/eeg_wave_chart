import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/brain/brain_data.dart';

/// 默认热力色表，从左到右由低到高：绿 → 黄 → 橙 → 红。
///
/// 热力图插值与底部色条共用这份色表，外部可以通过
/// `BrainHeatMapWidget(colors: ...)` 或 [BrainTopoPainter.colors] 覆盖。
const List<Color> defaultHeatColors = <Color>[
  Color(0xFF4FD96E), // Low  绿
  Color(0xFFFFE03D), //      黄
  Color(0xFFFF9A3D), //      橙
  Color(0xFFF5443C), // High 红
];

/// 热力图画笔：绘制椭圆（width == height 时退化为正圆）热力区域与底部水平色条，
/// 可选在电极点绘制通道名。越界的插值格子由椭圆轮廓裁剪。
class BrainTopoPainter extends CustomPainter {
  /// 频段数据（电极归一化坐标、实时功率、量程）
  final BandData data;

  /// 热力色表，从左到右由低到高；热力图与色条共用
  final List<Color> colors;

  /// 插值网格步长（逻辑像素），越小越细腻、计算量越大
  final double gridStep;

  /// 是否绘制内置图例标题（内容取自 [BandData.title]）
  final bool showLegend;

  /// 是否在电极点绘制通道名（CH1~CH8）
  final bool showElectrodeText;

  /// 通道名字体颜色（仅 [showElectrodeText] 为真时生效）
  final Color electrodeTextColor;

  /// 横向偏移量（逻辑像素）：把整个热场、电极与色条在画布内水平平移，
  /// 便于把热场对齐到非居中的狗脸；默认 0 表示水平居中于画布。
  final double offsetX;

  /// 构造时记录 revision 快照。BandData 是原地更新的，新旧 painter 持有
  /// 同一个对象，直接比较字段会永远相等、导致热力图不重绘。
  final int _revision;

  BrainTopoPainter({
    required this.data,
    this.colors = defaultHeatColors,
    this.gridStep = 6.0,
    this.showLegend = false,
    this.showElectrodeText = false,
    this.electrodeTextColor = Colors.white,
    this.offsetX = 0.0,
  }) : _revision = data.revision;

  static const double _barHeight = 12.0;
  static const double _barGap = 14.0;
  static const double _barBottom = 10.0;
  static const double _legendHeight = 22.0;

  List<Color> get _palette => colors.isEmpty ? defaultHeatColors : colors;

  /// 256 级颜色查表，避免每个格子都做 Color.lerp
  late final List<Color> _lut = _buildLut(_palette);

  static List<Color> _buildLut(List<Color> palette) {
    final List<Color> lut = List<Color>.filled(256, Colors.transparent);
    for (int i = 0; i < 256; i++) {
      lut[i] = _lerpColor(palette, i / 255.0);
    }
    return lut;
  }

  static Color _lerpColor(List<Color> palette, double ratio) {
    if (palette.length == 1) return palette.first;
    final double r = ratio < 0 ? 0.0 : (ratio > 1 ? 1.0 : ratio);
    final double scaled = r * (palette.length - 1);
    int i = scaled.floor();
    if (i < 0) i = 0;
    if (i > palette.length - 2) i = palette.length - 2;
    return Color.lerp(palette[i], palette[i + 1], scaled - i)!;
  }

  Color _colorOf(double ratio) {
    final double r = ratio < 0 ? 0.0 : (ratio > 1 ? 1.0 : ratio);
    return _lut[(r * 255).round()];
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 顶部按需给内置标题留位，底部留出水平色条的空间，其余区域画正圆
    // 热力图；直径由传入的 width / height 中较小者决定。
    final double legendHeight = (showLegend && data.title.isNotEmpty) ? _legendHeight : 0.0;
    final double reserved = _barHeight + _barGap + _barBottom;
    final double heatAreaH = size.height - reserved - legendHeight;
    // 热场形状由画布宽高决定为「椭圆」：rx 取宽度一半，ry 取热区高度一半。
    // width == height-36 时退化为正圆；两者不等即椭圆。
    final double rx = size.width / 2;
    final double ry = heatAreaH / 2;
    if (rx <= 0 || ry <= 0) return;
    final Offset center = Offset(size.width / 2 + offsetX, legendHeight + heatAreaH / 2);

    final Path heatPath = Path()
      ..addOval(Rect.fromCenter(center: center, width: rx * 2, height: ry * 2));
    canvas.save();
    canvas.clipPath(heatPath);

    // 电极的 dx/dy 是 [0,1] 归一化坐标，映射到以椭圆中心为原点的范围。
    final List<Offset> electrodeOffsets = <Offset>[
      for (final Electrode ele in data.electrodes)
        Offset((ele.dx - 0.5) * rx * 2, (ele.dy - 0.5) * ry * 2),
    ];
    final double span = data.maxVal - data.minVal;
    final Paint cellPaint = Paint();

    for (double y = -ry; y <= ry; y += gridStep) {
      for (double x = -rx; x <= rx; x += gridStep) {
        // 按格心判定归属；椭圆外的格子交给上面的 clipPath 裁剪。
        final double cx = x + gridStep / 2;
        final double cy = y + gridStep / 2;
        if ((cx / rx) * (cx / rx) + (cy / ry) * (cy / ry) > 1.0) continue;

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

        final double val = denominator == 0 ? 0 : numerator / denominator;
        final double ratio = span == 0 ? 0 : (val - data.minVal) / span;
        cellPaint.color = _colorOf(ratio);
        // 略大于步长，消除相邻矩形因浮点取整留下的细缝。
        canvas.drawRect(
          Rect.fromLTWH(center.dx + x, center.dy + y, gridStep + 0.5, gridStep + 0.5),
          cellPaint,
        );
      }
    }
    canvas.restore();

    // 电极点与通道名：画在裁剪之外，避免被椭圆边缘切掉。
    if (showElectrodeText) {
      final Paint dotPaint = Paint()..color = Colors.white;
      final TextPainter tp = TextPainter(textDirection: TextDirection.ltr);
      for (final Electrode ele in data.electrodes) {
        final Offset p = Offset(
          center.dx + (ele.dx - 0.5) * rx * 2,
          center.dy + (ele.dy - 0.5) * ry * 2,
        );
        canvas.drawCircle(p, 3, dotPaint);
        tp.text = TextSpan(
          text: ele.name,
          style: TextStyle(
            color: electrodeTextColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            shadows: const <Shadow>[Shadow(color: Colors.black54, blurRadius: 2)],
          ),
        );
        tp.layout();
        tp.paint(canvas, Offset(p.dx + 5, p.dy - 8));
      }
    }

    _paintLegend(canvas, size, center, legendHeight);

    // 色条放底部，从左到右 = colors 的 Low → High，与热力图同一套色表。
    final Rect barRect = Rect.fromLTWH(
      center.dx - rx,
      legendHeight + heatAreaH + _barGap,
      rx * 2,
      _barHeight,
    );
    final List<Color> palette = _palette;
    final Paint barPaint = Paint()
      ..shader = LinearGradient(
        colors: palette.length == 1 ? <Color>[palette.first, palette.first] : palette,
      ).createShader(barRect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(barRect, const Radius.circular(_barHeight / 2)),
      barPaint,
    );
  }

  /// 内置图例标题：内容取自 [BandData.title]，居中画在顶部预留区。
  /// TextPainter 必须先 layout() 才能 paint()，否则会抛文字几何未计算的异常。
  void _paintLegend(Canvas canvas, Size size, Offset center, double legendHeight) {
    if (!showLegend || data.title.isEmpty || legendHeight <= 0) return;
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: data.title,
        style: const TextStyle(color: Color(0xFF37474F), fontSize: 12, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: size.width);
    tp.paint(canvas, Offset(center.dx - tp.width / 2, (legendHeight - tp.height) / 2 - 40));
  }

  @override
  bool shouldRepaint(covariant BrainTopoPainter oldDelegate) {
    return oldDelegate._revision != _revision ||
        oldDelegate.gridStep != gridStep ||
        oldDelegate.showLegend != showLegend ||
        oldDelegate.showElectrodeText != showElectrodeText ||
        oldDelegate.electrodeTextColor != electrodeTextColor ||
        oldDelegate.offsetX != offsetX ||
        !_sameColors(oldDelegate.colors, colors);
  }

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
