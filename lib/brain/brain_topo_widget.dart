import 'dart:async';
import 'package:flutter/material.dart';
import '../models/brain/brain_data.dart';
import 'brain_topo_painter.dart';

class BrainHeatMapWidget extends StatefulWidget {
  final BandData initData;
  final ValueNotifier<List<double>>? rawPowerNotifier;

  final double emaAlpha;
  final int throttleMs;
  final double headRadius;
  final double gridStep;
  final bool showElectrodeText;

  const BrainHeatMapWidget({
    super.key,
    required this.initData,
    this.rawPowerNotifier,
    this.emaAlpha = 0.2,
    this.throttleMs = 250,
    this.headRadius = 120,
    this.gridStep = 6.0,
    this.showElectrodeText = false,
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
    return CustomPaint(
      size: Size.infinite,
      painter: BrainTopoPainter(
        data: _bandData,
        headRadius: widget.headRadius,
        gridStep: widget.gridStep,
        showElectrodeText: widget.showElectrodeText,
      ),
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
