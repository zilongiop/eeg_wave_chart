import 'dart:async';
import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 降采样读的是 [EegSample.filteredUv]（原始值经滤波后才写入缓冲），
/// 所以这里两个字段都填同样的信号值。
List<EegSample> _samples(int count, double Function(double t) signal) {
  final List<EegSample> out = <EegSample>[];
  for (int i = 0; i < count; i++) {
    final double t = i / 250.0;
    out.add(EegSample(
      rawAdc: 0,
      rawUv: signal(t),
      filteredUv: signal(t),
      timeSec: t,
      channelIndex: 0,
    ));
  }
  return out;
}

void main() {
  test('每个点取该区间内所有样本的平均值', () {
    final EegDownSampler sampler = EegDownSampler();

    // 桶宽 1s：桶 [0,1) 恒为 5，桶 [1,2) 恒为 10，桶 [2,3) 恒为 -20。
    final List<EegSample> data = _samples(700, (double t) {
      if (t < 1.0) {
        return 5.0;
      }
      if (t < 2.0) {
        return 10.0;
      }
      return -20.0;
    });

    final List<FlSpot> spots = sampler.downsampleByTime(data, 1.0);
    expect(spots.length, 2);
    expect(spots[0].y, closeTo(5.0, 1e-9));
    expect(spots[1].y, closeTo(10.0, 1e-9));
  });

  test('区间内线性变化时平均值落在区间中点', () {
    final EegDownSampler sampler = EegDownSampler();

    // 斜坡 y = 100t：任何区间的平均值都等于区间中点的值。
    // 取 5 秒数据，最后一个未填满的桶不输出，故有 4 个桶。
    final List<FlSpot> spots =
        sampler.downsampleByTime(_samples(1250, (double t) => 100.0 * t), 1.0);

    expect(spots.length, 4);
    double maxErr = 0.0;
    for (final FlSpot sp in spots) {
      // 点的 x 是桶内样本的平均时间，y 是平均值，斜坡上二者满足 y=100x。
      maxErr = math.max(maxErr, (sp.y - 100.0 * sp.x).abs());
    }
    expect(maxErr, lessThan(1e-6),
        reason: '平均值应落在区间中点，实际最大偏差 $maxErr');
  });

  testWidgets('线条用曲线平滑过渡且防过冲', (WidgetTester tester) async {
    final StreamController<EegSample> controller =
        StreamController<EegSample>.broadcast();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: EegWaveChartWidget(
            config: const EegWaveConfig(
              sampleRate: 250,
              channelCount: 1,
              windowDuration: 10,
              xAxisInterval: 2.0,
              xAxisDivisions: 5,
              // 本用例验证聚合与曲线，不关心滤波器启动瞬态。
              filterWarmupSec: 0,
            ),
            sampleStream: controller.stream,
          ),
        ),
      ),
    ));

    for (int i = 0; i < 3000; i++) {
      controller.add(EegSample(
        rawAdc: 0,
        rawUv: 20 * math.sin(2 * math.pi * 10 * (i / 250.0)),
        filteredUv: 0,
        timeSec: i / 250.0,
        channelIndex: 0,
      ));
    }
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    final LineChartData data =
        tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(data.lineBarsData, isNotEmpty);
    expect(data.lineBarsData.first.isCurved, isTrue);
    expect(data.lineBarsData.first.preventCurveOverShooting, isTrue,
        reason: '开启防过冲，避免曲线插值把波形顶出通道带');
  });

  testWidgets('按刻度格聚合时每格出指定数量的点', (WidgetTester tester) async {
    int seed = 0;
    Future<int> countSpots(int perDiv) async {
      final StreamController<EegSample> controller =
          StreamController<EegSample>.broadcast();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: EegWaveChartWidget(
              // 必须换 key：同一位置复用 State 的话会继续订阅旧 stream，
              // 新数据根本收不到。
              key: ValueKey<int>(seed++),
              config: EegWaveConfig(
                sampleRate: 250,
                channelCount: 1,
                windowDuration: 10,
                xAxisInterval: 2.0,
                xAxisDivisions: 5,
                spotsPerDivision: perDiv,
                filterWarmupSec: 0,
              ),
              sampleStream: controller.stream,
            ),
          ),
        ),
      ));
      for (int i = 0; i < 3000; i++) {
        controller.add(EegSample(
          rawAdc: 0,
          rawUv: 10.0,
          filteredUv: 0,
          timeSec: i / 250.0,
          channelIndex: 0,
        ));
      }
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      final LineChartData data =
          tester.widget<LineChart>(find.byType(LineChart)).data;
      return data.lineBarsData.isEmpty ? 0 : data.lineBarsData.first.spots.length;
    }

    // 一屏 10s、每格 2s、共 5 格；最后一个未填满的桶不输出。
    final int n1 = await countSpots(1);
    expect(n1, inInclusiveRange(4, 5), reason: 'perDiv=1 时应为 4~5 点，实际 $n1');

    final int n2 = await countSpots(2);
    expect(n2, inInclusiveRange(8, 10), reason: 'perDiv=2 时应为 8~10 点，实际 $n2');

    final int n5 = await countSpots(5);
    expect(n5, inInclusiveRange(20, 25), reason: 'perDiv=5 时应为 20~25 点，实际 $n5');
  });
}
