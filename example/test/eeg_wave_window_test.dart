import 'dart:async';
import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 推送 [seconds] 秒的模拟数据，并让 UI 定时器跑几帧。
Future<void> _feedAndPump(
  WidgetTester tester,
  StreamController<EegSample> controller,
  double seconds,
) async {
  for (int i = 0; i < (seconds * 250).round(); i++) {
    final double t = i / 250.0;
    controller.add(EegSample(
      rawAdc: 0,
      rawUv: 20 * math.sin(2 * math.pi * 10 * t),
      filteredUv: 0,
      timeSec: t,
      channelIndex: 0,
    ));
  }
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  testWidgets('X 轴窗口始终跟着最新数据滚动', (WidgetTester tester) async {
    final StreamController<EegSample> controller =
        StreamController<EegSample>.broadcast();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: EegWaveChartWidget(
            config: const EegWaveConfig(
              sampleRate: 250,
              channelCount: 1,
              windowDuration: 25,
              filterWarmupSec: 0,
            ),
            sampleStream: controller.stream,
          ),
        ),
      ),
    ));

    // 覆盖「窗口时长之内」与「远超窗口时长」两种情形：
    // 后者曾因 X 轴边界只增不回绕而彻底画不出波形。
    for (final double elapsed in <double>[5, 25, 40, 120]) {
      await _feedAndPump(tester, controller, elapsed);

      final LineChartData data =
          tester.widget<LineChart>(find.byType(LineChart)).data;
      final List<FlSpot> spots = data.lineBarsData.first.spots;
      final int visible = spots
          .where((FlSpot s) => s.x >= data.minX && s.x <= data.maxX)
          .length;

      expect(spots, isNotEmpty, reason: '$elapsed 秒时应有降采样点');
      expect(visible, greaterThan(100),
          reason: '$elapsed 秒时窗口内应能看到波形点');
      expect(data.maxX - data.minX,
          moreOrLessEquals(25.0, epsilon: 0.2),
          reason: '窗口宽度应恒为 windowDuration');
    }
  });

  testWidgets('坐标轴显示通道名与时间，且点数受预算约束',
      (WidgetTester tester) async {
    final StreamController<EegSample> controller =
        StreamController<EegSample>.broadcast();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: EegWaveChartWidget(
            config: const EegWaveConfig(
              sampleRate: 250,
              channelCount: 2,
              windowDuration: 10,
              channelNames: <String>['Fp1', 'O1'],
              filterWarmupSec: 0,
            ),
            sampleStream: controller.stream,
          ),
        ),
      ),
    ));

    // 12 秒数据，两个通道。
    for (int i = 0; i < 3000; i++) {
      final double t = i / 250.0;
      for (int ch = 0; ch < 2; ch++) {
        controller.add(EegSample(
          rawAdc: 0,
          rawUv: 20 * math.sin(2 * math.pi * 10 * t + ch),
          filteredUv: 0,
          timeSec: t,
          channelIndex: ch,
        ));
      }
    }
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    // 左轴：通道名；轴名：µV。
    expect(find.text('Fp1'), findsOneWidget);
    expect(find.text('O1'), findsOneWidget);
    expect(find.text('µV'), findsOneWidget);
    // 下轴：mm:ss 形式的时间刻度。
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Text && RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data!),
      ),
      findsWidgets,
    );

    final LineChartData data =
        tester.widget<LineChart>(find.byType(LineChart)).data;
    for (final LineChartBarData bar in data.lineBarsData) {
      expect(bar.spots.length, lessThanOrEqualTo(1200),
          reason: '单通道点数应不超过 maxSpotsPerChannel');
    }
  });
}
