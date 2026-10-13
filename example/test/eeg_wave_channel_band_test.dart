import 'dart:async';
import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻 DemoEegPage 的信号：alpha + beta + 漂移，每 8 秒一次 +70µV 眨眼。
///
/// 眨眼经 4 阶滤波后峰值约 88µV，远超 displayUvRange=60，是最容易触发
/// 「波形画进相邻通道」的场景。
double _demoSignal(double t) {
  double uv = 14 * math.sin(2 * math.pi * 10 * t) +
      6 * math.sin(2 * math.pi * 20 * t) +
      10 * math.sin(2 * math.pi * 0.15 * t);
  final double cycle = t % 8.0;
  if (cycle > 7.0 && cycle < 7.3) {
    uv += 70.0;
  }
  return uv;
}

void main() {
  testWidgets('大伪迹也不会画进相邻通道', (WidgetTester tester) async {
    final StreamController<EegSample> controller =
        StreamController<EegSample>.broadcast();

    const double range = 60.0;
    const int channelCount = 4;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: EegWaveChartWidget(
            config: const EegWaveConfig(
              sampleRate: 250,
              channelCount: channelCount,
              windowDuration: 10,
              displayUvRange: range,
              // 本用例验证通道带限幅，不需要等待滤波器进入稳态。
              filterWarmupSec: 0,
            ),
            sampleStream: controller.stream,
          ),
        ),
      ),
    ));

    final double chOffset = range * 1.3;
    int seq = 0;
    bool sawClipping = false;

    // 跑 12 秒，覆盖第一次眨眼（7.0~7.3s）及其后的窗口滚动。
    for (int frame = 0; frame < 60 * 12; frame++) {
      for (int i = 0; i < 4; i++) {
        final double t = seq / 250.0;
        for (int ch = 0; ch < channelCount; ch++) {
          controller.add(EegSample(
            rawAdc: 0,
            rawUv: _demoSignal(t),
            filteredUv: 0,
            timeSec: t,
            channelIndex: ch,
          ));
        }
        seq++;
      }
      await tester.pump(const Duration(milliseconds: 16));

      if (frame * 0.016 < 6.0) {
        continue;
      }

      final List<LineChartBarData> bars =
          tester.widget<LineChart>(find.byType(LineChart)).data.lineBarsData;
      expect(bars, isNotEmpty);

      for (int ch = 0; ch < bars.length; ch++) {
        final double lo = ch * chOffset - range;
        final double hi = ch * chOffset + range;
        for (final FlSpot sp in bars[ch].spots) {
          expect(sp.y, greaterThanOrEqualTo(lo - 1e-9),
              reason: '通道 $ch 的点越过了下边界');
          expect(sp.y, lessThanOrEqualTo(hi + 1e-9),
              reason: '通道 $ch 的点越过了上边界');
          if ((sp.y - hi).abs() < 1e-9 || (sp.y - lo).abs() < 1e-9) {
            sawClipping = true;
          }
        }
      }
    }

    // 同时确认大伪迹确实发生了（否则上面对每个点的断言没有意义）。
    expect(sawClipping, isTrue, reason: '眨眼伪迹应被削平在通道带边缘');
  });
}
