import 'dart:async';
import 'package:flutter/material.dart';
import '../models/brain/brain_data.dart';
import 'brain_topo_painter.dart';

class BrainHeatMapWidget extends StatefulWidget {
  final BandData initData;
  final ValueNotifier<List<double>>? rawPowerNotifier;

  /// 画布宽高；为空时取父约束（都没有约束时退化为 240×240）。
  /// 热力图为椭圆：rx = width/2，ry = (height - 底部色条区 - 图例)/2；
  /// width 与 height 相等时退化为正圆，不等则为椭圆。
  final double? width;
  final double? height;

  /// 热力色表，从左到右由低到高；热力图与底部色条共用
  final List<Color> colors;

  /// 是否显示内置图例标题，内容取自 [BandData.title]；默认不显示
  final bool showLegend;

  /// 是否在电极点绘制通道名（CH1~CH8）；默认不显示
  final bool showElectrodeText;

  /// 通道名字体颜色（需 [showElectrodeText] 为真才生效）；默认白色
  final Color electrodeTextColor;

  /// 横向偏移量（逻辑像素）：把整个热场、电极与色条在画布内水平平移，
  /// 便于对齐非居中的狗脸；默认 0 居中。
  final double offsetX;

  final double emaAlpha;
  final int throttleMs;
  final double gridStep;

  const BrainHeatMapWidget({
    super.key,
    required this.initData,
    this.rawPowerNotifier,
    this.width,
    this.height,
    this.colors = defaultHeatColors,
    this.showLegend = false,
    this.showElectrodeText = false,
    this.electrodeTextColor = Colors.white,
    this.offsetX = 0.0,
    this.emaAlpha = 0.2,
    this.throttleMs = 250,
    this.gridStep = 6.0,
  });

  @override
  State<BrainHeatMapWidget> createState() => _BrainHeatMapWidgetState();
}

class _BrainHeatMapWidgetState extends State<BrainHeatMapWidget> {
  late BandData _bandData;
  late List<double> _emaBuffer;
  late Timer _throttleTimer;
  List<double>? _pendingRawPower;
  bool _isDisposed = false; // 标记state是否已经销毁

  @override
  void initState() {
    super.initState();
    _isDisposed = false;
    _bandData = widget.initData;
    _emaBuffer = List<double>.filled(_bandData.electrodes.length, 0.0);

    //注册监听
    if (widget.rawPowerNotifier != null) {
      widget.rawPowerNotifier!.addListener(_onPowerUpdate);
    }

    _throttleTimer = Timer.periodic(Duration(milliseconds: widget.throttleMs), (_) {
      _applyPending();
    });
  }

  /// notifier回调
  void _onPowerUpdate() {
    if (_isDisposed) return; // 已经销毁直接返回，禁止执行setState
    final list = widget.rawPowerNotifier!.value;
    if (list.isNotEmpty) {
      _pendingRawPower = list;
    }
  }

  void _applyPending() {
    if (_isDisposed) return;
    final raw = _pendingRawPower;
    if (raw == null) return;

    for (int i = 0; i < raw.length; i++) {
      _emaBuffer[i] = widget.emaAlpha * raw[i] + (1.0 - widget.emaAlpha) * _emaBuffer[i];
    }
    setState(() {
      _bandData.updatePowerList(_emaBuffer);
    });
    _pendingRawPower = null;
  }

  @override
  Widget build(BuildContext context) {
    final Widget canvas = CustomPaint(
      size: Size.infinite,
      painter: BrainTopoPainter(
        data: _bandData,
        colors: widget.colors,
        showLegend: widget.showLegend,
        showElectrodeText: widget.showElectrodeText,
        electrodeTextColor: widget.electrodeTextColor,
        offsetX: widget.offsetX,
        gridStep: widget.gridStep,
      ),
    );

    // 两个尺寸都给了就用固定画布；否则按父约束自适应。
    if (widget.width != null && widget.height != null) {
      return SizedBox(width: widget.width, height: widget.height, child: canvas);
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SizedBox(
          width: widget.width ??
              (constraints.hasBoundedWidth ? constraints.maxWidth : 240),
          height: widget.height ??
              (constraints.hasBoundedHeight ? constraints.maxHeight : 240),
          child: canvas,
        );
      },
    );
  }

  @override
  void dispose() {
    _isDisposed = true; // 标记销毁
    //移除监听！！防止dispose之后继续回调
    if (widget.rawPowerNotifier != null) {
      widget.rawPowerNotifier!.removeListener(_onPowerUpdate);
    }
    _throttleTimer.cancel();
    super.dispose();
  }
}
