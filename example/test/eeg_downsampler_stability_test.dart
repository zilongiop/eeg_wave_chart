import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:flutter_test/flutter_test.dart';

List<EegSample> _makeSamples(double fromSec, int count) {
  final List<EegSample> out = <EegSample>[];
  for (int i = 0; i < count; i++) {
    final double t = fromSec + i / 250.0;
    out.add(EegSample(
      rawAdc: 0,
      rawUv: 20 * math.sin(2 * math.pi * 10 * t),
      filteredUv: 20 * math.sin(2 * math.pi * 10 * t),
      timeSec: t,
      channelIndex: 0,
    ));
  }
  return out;
}

double? _interp(List<FlSpot> spots, double x) {
  if (x < spots.first.x || x > spots.last.x) {
    return null;
  }
  for (int i = 1; i < spots.length; i++) {
    final FlSpot p0 = spots[i - 1];
    final FlSpot p1 = spots[i];
    if (x >= p0.x && x <= p1.x) {
      final double dx = p1.x - p0.x;
      if (dx == 0) {
        return p0.y;
      }
      return p0.y + (p1.y - p0.y) * (x - p0.x) / dx;
    }
  }
  return spots.last.y;
}

/// 在重叠区中段 80% 上比较两条折线的平均差异（µV）。
double _meanDiff(List<FlSpot> a, List<FlSpot> b) {
  final double left = math.max(a.first.x, b.first.x);
  final double right = math.min(a.last.x, b.last.x);
  final double margin = (right - left) * 0.1;
  final double from = left + margin;
  final double to = right - margin;

  double sum = 0;
  int count = 0;
  for (int i = 0; i <= 400; i++) {
    final double x = from + (to - from) * i / 400;
    final double? ya = _interp(a, x);
    final double? yb = _interp(b, x);
    if (ya == null || yb == null) {
      continue;
    }
    sum += (ya - yb).abs();
    count++;
  }
  return count == 0 ? 0 : sum / count;
}

void main() {
  test('按绝对时间分桶（均值）时，相邻帧的波形几乎不跳变', () {
    const double window = 10.0;
    final int count = (window * 250).round();
    final List<EegSample> prev = _makeSamples(2.0, count);

    final EegDownSampler sampler = EegDownSampler(groupPointCount: 5);
    final double bucketSec = window / 600;

    // 每帧进点数并不固定（定时器抖动/掉帧），取几个非整数倍偏移分别验证。
    for (final int shift in <int>[3, 7, 11, 13]) {
      final List<EegSample> next = _makeSamples(2.0 + shift / 250.0, count);

      final double byTime = _meanDiff(
        sampler.downsampleByTime(prev, bucketSec),
        sampler.downsampleByTime(next, bucketSec),
      );

      expect(byTime, lessThan(0.05),
          reason: '进 $shift 点时按时间分桶均值应几乎无跳变，实际 $byTime');
    }
  });

  test('时间分桶不会输出最后一个未填满的桶', () {
    final List<EegSample> samples = _makeSamples(0, 250);
    // 桶宽 0.1s，250 点覆盖 0~1.0s，最后一个桶 [0.9, 1.0) 未走完。
    final List<FlSpot> spots =
        EegDownSampler().downsampleByTime(samples, 0.1);
    expect(spots, isNotEmpty);
    expect(spots.last.x, lessThan(0.9));
  });
}
