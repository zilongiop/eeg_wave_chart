import 'dart:async';
import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eeg_wave_chart_example/main.dart';

/// 驱动 widget 跑 [totalSec] 秒仿真数据，累计所有出现过的绘制点。
///
/// 窗口在滚动，旧点会被回收，所以每一帧都要把当前可见点合并进 [seen]，
/// 靠 Map 去重积累出完整的波形。
Future<Map<double, double>> _collectPoints(
  WidgetTester tester, {
  required double totalSec,
  double windowDuration = 10,
  double? warmupSec,
}) async {
  final DemoEegSignal sig = DemoEegSignal(noiseUv: 0);
  final StreamController<EegSample> controller =
      StreamController<EegSample>.broadcast();

  // warmupSec 为 null 时沿用 EegWaveConfig 的默认值，因此本文件始终在
  // 校验真实的出厂默认，而不是测试里硬编码的副本。
  final double warmup =
      warmupSec ??
      EegWaveConfig(sampleRate: 250, channelCount: 1).filterWarmupSec;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: EegWaveChartWidget(
            config: EegWaveConfig(
              sampleRate: 250,
              channelCount: 1,
              windowDuration: windowDuration,
              displayUvRange: 30.0,
              filterWarmupSec: warmup,
            ),
            sampleStream: controller.stream,
          ),
        ),
      ),
    ),
  );

  final Map<double, double> seen = <double, double>{};
  const double stepSec = 0.5;
  final int steps = (totalSec / stepSec).round();
  for (int n = 0; n < steps; n++) {
    for (int i = 0; i < (stepSec * 250).round(); i++) {
      final double t = n * stepSec + i / 250.0;
      controller.add(
        EegSample(
          rawAdc: 0,
          rawUv: sig.generate(t, 0),
          filteredUv: 0,
          timeSec: t,
          channelIndex: 0,
        ),
      );
    }
    await tester.pump(const Duration(milliseconds: 500));
    final List<LineChartBarData> bars = tester
        .widget<LineChart>(find.byType(LineChart))
        .data
        .lineBarsData;
    if (bars.isNotEmpty) {
      for (final FlSpot sp in bars.first.spots) {
        seen[sp.x] = sp.y;
      }
    }
  }
  return seen;
}

/// 统计 [from, to) 区间内 y 的峰峰值。
double _peakToPeak(Map<double, double> pts, double from, double to) {
  double lo = double.infinity;
  double hi = -double.infinity;
  for (final MapEntry<double, double> e in pts.entries) {
    if (e.key < from || e.key >= to) {
      continue;
    }
    if (e.value < lo) lo = e.value;
    if (e.value > hi) hi = e.value;
  }
  return hi - lo;
}

void main() {
  test('默认预热时长为 8 秒（正好一个信号循环）', () {
    const EegWaveConfig cfg = EegWaveConfig(sampleRate: 250, channelCount: 1);
    expect(cfg.filterWarmupSec, 8.0);
    expect(
      cfg.filterWarmupSec,
      DemoEegSignal.cycleSec,
      reason: '预热时长应与仿真信号的循环周期一致',
    );
  });

  testWidgets('双通道默认预热后才开始绘制，避免开头大幅度重合', (WidgetTester tester) async {
    final DemoEegSignal sig = DemoEegSignal(noiseUv: 0);
    final StreamController<EegSample> controller =
        StreamController<EegSample>.broadcast();
    addTearDown(controller.close);

    const double range = 30.0;
    const int channelCount = 2;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 240,
            child: EegWaveChartWidget(
              config: const EegWaveConfig(
                sampleRate: 250,
                channelCount: channelCount,
                windowDuration: 10,
                displayUvRange: range,
              ),
              sampleStream: controller.stream,
            ),
          ),
        ),
      ),
    );

    for (int n = 0; n < 18; n++) {
      for (int i = 0; i < 125; i++) {
        final double t = n * 0.5 + i / 250.0;
        for (int ch = 0; ch < channelCount; ch++) {
          controller.add(
            EegSample(
              rawAdc: 0,
              rawUv: sig.generate(t, ch),
              filteredUv: 0,
              timeSec: t,
              channelIndex: ch,
            ),
          );
        }
      }
      await tester.pump(const Duration(milliseconds: 500));

      final List<LineChartBarData> bars = tester
          .widget<LineChart>(find.byType(LineChart))
          .data
          .lineBarsData;
      if (n < 16) {
        expect(bars, isEmpty, reason: '8 秒预热结束前不应绘制任何通道');
      }
    }

    final List<LineChartBarData> bars = tester
        .widget<LineChart>(find.byType(LineChart))
        .data
        .lineBarsData;
    expect(bars.length, channelCount);

    final double chOffset = range * 1.3;
    for (int ch = 0; ch < channelCount; ch++) {
      final double lo = ch * chOffset - range;
      final double hi = ch * chOffset + range;
      expect(bars[ch].spots, isNotEmpty);
      expect(bars[ch].spots.first.x, greaterThanOrEqualTo(8.0));
      for (final FlSpot sp in bars[ch].spots) {
        expect(sp.y, greaterThanOrEqualTo(lo - 1e-9));
        expect(sp.y, lessThanOrEqualTo(hi + 1e-9));
      }
    }
  });

  testWidgets('预热期内不绘制任何点', (WidgetTester tester) async {
    final Map<double, double> pts = await _collectPoints(tester, totalSec: 24);

    expect(pts, isNotEmpty);
    // 默认预热 8 秒：这段时间只喂滤波器、不出图。
    final double earliest = pts.keys.reduce(math.min);
    expect(
      earliest,
      greaterThanOrEqualTo(8.0),
      reason: '预热期不应有绘制点，最早的点却在 t=${earliest.toStringAsFixed(2)}',
    );
  });

  testWidgets('预热之后每个循环的幅度完全一致', (WidgetTester tester) async {
    final Map<double, double> pts = await _collectPoints(tester, totalSec: 48);

    // 预热恰好 8 秒，所以 [8,16) 就是画出来的第一个完整循环——它必须
    // 已经和后续循环同幅度，否则等于没预热。
    final double c1 = _peakToPeak(pts, 8.0, 16.0);
    final double c2 = _peakToPeak(pts, 16.0, 24.0);
    final double c3 = _peakToPeak(pts, 24.0, 32.0);
    final double c4 = _peakToPeak(pts, 32.0, 40.0);

    expect(c1, greaterThan(0), reason: '预热后应有波形');

    // 没有预热的版本第 1 个循环会比稳态高约 8%；加上预热后必须收敛到同一水平。
    expect(
      (c2 - c1).abs(),
      lessThan(c1 * 0.02),
      reason:
          '第 2 循环 ${c2.toStringAsFixed(2)} 与第 1 循环 '
          '${c1.toStringAsFixed(2)} 幅度不一致',
    );
    expect(
      (c3 - c1).abs(),
      lessThan(c1 * 0.02),
      reason: '第 3 循环 ${c3.toStringAsFixed(2)} 与第 1 循环不一致',
    );
    expect(
      (c4 - c1).abs(),
      lessThan(c1 * 0.02),
      reason: '第 4 循环 ${c4.toStringAsFixed(2)} 与第 1 循环不一致',
    );
  });

  testWidgets('关闭预热时首段幅度偏大，印证预热的必要性', (WidgetTester tester) async {
    final Map<double, double> pts = await _collectPoints(
      tester,
      totalSec: 24,
      warmupSec: 0,
    );

    // warmup=0 时能看到 t<2 的点。
    final double earliest = pts.keys.reduce(math.min);
    expect(earliest, lessThan(2.0));

    // 启动瞬态让头两秒冲得比稳态高。
    final double early = _peakToPeak(pts, 0.0, 2.0);
    final double steady = _peakToPeak(pts, 16.0, 24.0);
    expect(
      early,
      greaterThan(steady),
      reason:
          '关闭预热时首段(${early.toStringAsFixed(2)})应高于稳态'
          '(${steady.toStringAsFixed(2)})，这正是预热要消除的瞬态',
    );
  });
}
