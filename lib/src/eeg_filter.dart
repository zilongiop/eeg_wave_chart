import 'dart:collection';

import 'package:iirjdart/butterworth.dart';

/// 单导联实时滤波器：去趋势 → 高通 → 陷波 → 低通。
///
/// 全程因果 IIR，不使用未来数据，因此可直接用于 BLE 流式输入。
class EegChannelFilter {
  EegChannelFilter({
    required this.fs,
    this.hpCut = 0.5,
    this.lpCut = 45.0,
    required this.notchFreq,
    required this.order,
    this.meanWindowSize = 125,
  }) {
    // 高通巴特沃斯。
    _hpFilter = Butterworth();
    _hpFilter.highPass(order, fs, hpCut);

    // 低通巴特沃斯。
    _lpFilter = Butterworth();
    _lpFilter.lowPass(order, fs, lpCut);

    // 陷波滤波器：bandStop(阶数, 采样率, 中心频率, 带宽)。
    _notchFilter = Butterworth();
    _notchFilter.bandStop(order, fs, notchFreq, 2.0);
  }

  final double fs;
  final double hpCut;
  final double lpCut;
  final double notchFreq;
  final int order;

  late final Butterworth _hpFilter;
  late final Butterworth _lpFilter;
  late final Butterworth _notchFilter;

  /// 滑动窗口做 detrend 去直流。
  ///
  /// 用 Queue + 滑动和而不是 List.removeAt(0) + reduce：后者每样本都要
  /// 搬移元素并重新累加整个窗口（O(n)），多导联高频下会明显吃掉 CPU、
  /// 拖垮帧率；滑动和是 O(1)。
  final ListQueue<double> _meanWindow = ListQueue<double>();
  double _meanSum = 0.0;
  final int meanWindowSize;

  /// 单样本实时处理。
  double processSample(double rawUv) {
    // 1. 滑动均值去直流 detrend（O(1) 滑动和）。
    _meanWindow.addLast(rawUv);
    _meanSum += rawUv;
    if (_meanWindow.length > meanWindowSize) {
      _meanSum -= _meanWindow.removeFirst();
    }
    final double mean = _meanSum / _meanWindow.length;
    double out = rawUv - mean;

    // 2~4. 高通 → 陷波（消除工频）→ 低通。
    out = _hpFilter.filter(out);
    out = _notchFilter.filter(out);
    out = _lpFilter.filter(out);
    return out;
  }

  /// 重置滤波器状态，切换采集或通道重启时调用。
  void reset() {
    _hpFilter.reset();
    _lpFilter.reset();
    _notchFilter.reset();
    _meanWindow.clear();
    _meanSum = 0.0;
  }
}
