import 'dart:async';
import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double kRange = 100.0;

Future<List<FlSpot>> _run(WidgetTester tester, double Function(double) sig,
    {double seconds = 8, double warmup = 0}) async {
  final StreamController<EegSample> c = StreamController<EegSample>.broadcast();
  // 必须在用例结束时释放：残留的订阅与 Ticker 会干扰后续用例。
  addTearDown(c.close);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 200,
        child: EegWaveChartWidget(
          config: EegWaveConfig(
            sampleRate: 250,
            channelCount: 1,
            windowDuration: 10,
            displayUvRange: kRange,
            filterWarmupSec: warmup,
          ),
          sampleStream: c.stream,
        ),
      ),
    ),
  ));

  const double step = 0.5;
  for (int n = 0; n < (seconds / step).round(); n++) {
    for (int i = 0; i < (step * 250).round(); i++) {
      final double t = n * step + i / 250.0;
      final double uv = sig(t);
      c.add(EegSample(
        rawAdc: 0,
        rawUv: uv,
        filteredUv: uv,
        timeSec: t,
        channelIndex: 0,
      ));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  final List<FlSpot> spots = <FlSpot>[];
  for (final LineChartBarData bar in tester
      .widget<LineChart>(find.byType(LineChart))
      .data
      .lineBarsData) {
    spots.addAll(bar.spots);
  }
  return spots;
}

void main() {
  testWidgets('Y 轴范围就是 -100 ~ +100µV', (WidgetTester tester) async {
    await _run(tester, (double t) => 20 * math.sin(t));
    final LineChartData data =
        tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(data.minY, -100.0, reason: 'Y 轴下界应为 -100µV');
    expect(data.maxY, 100.0, reason: 'Y 轴上界应为 +100µV');
  });

  testWidgets('5 倍量程的数据也必须夹在 ±100µV 以内', (WidgetTester tester) async {
    // 故意灌 ±500µV，覆盖眨眼、肌电这类大伪迹的量级。
    final List<FlSpot> spots =
        await _run(tester, (double t) => 500 * math.sin(2 * math.pi * 3 * t));

    expect(spots, isNotEmpty, reason: '应当有波形输出');
    for (final FlSpot sp in spots) {
      expect(sp.y, greaterThanOrEqualTo(-100.0),
          reason: '点 ${sp.y} 低于 -100µV 下界');
      expect(sp.y, lessThanOrEqualTo(100.0),
          reason: '点 ${sp.y} 高于 +100µV 上界');
    }
  });

  testWidgets('正常幅度的数据完整保留，不被误削', (WidgetTester tester) async {
    // 峰峰值 40µV，远在量程内，应原样保留。
    // 预热 2 秒跳过滤波器启动瞬态，否则测到的是被瞬态抬高的幅度。
    final List<FlSpot> spots = await _run(
        tester, (double t) => 20 * math.sin(2 * math.pi * 10 * t),
        warmup: 2.0);

    double lo = double.infinity;
    double hi = -double.infinity;
    for (final FlSpot sp in spots) {
      if (sp.y < lo) lo = sp.y;
      if (sp.y > hi) hi = sp.y;
    }
    expect(hi - lo, closeTo(40.0, 2.0),
        reason: '量程内的信号不应被削平，实际峰峰值 ${(hi - lo).toStringAsFixed(1)}');
  });
}
