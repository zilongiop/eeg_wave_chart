import 'dart:async';

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eeg_wave_chart_example/main.dart';

void main() {
  testWidgets('波形页提供 0.5/1/2s 的 X 轴每格时间切换',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: DemoEegPage()));

    // 小数档不能显示成 "0s"。
    for (final String label in <String>['0.5s', '1s', '2s']) {
      expect(find.text(label), findsOneWidget, reason: '应有 $label 切换项');
    }
    expect(find.text('0s'), findsNothing);

    ChoiceChip chipOf(String label) => tester.widget<ChoiceChip>(find.ancestor(
          of: find.text(label),
          matching: find.byType(ChoiceChip),
        ));

    // 默认 2s/格 → 一屏 5 格 = 10s。
    expect(chipOf('2s').selected, isTrue);
    expect(chipOf('0.5s').selected, isFalse);

    EegWaveChartWidget wave() =>
        tester.widget<EegWaveChartWidget>(find.byType(EegWaveChartWidget));
    final EegWaveChartWidget before = wave();
    expect(before.config.xAxisInterval, 2.0);
    expect(before.config.xAxisDivisions, 5);
    expect(before.config.windowDuration, 10.0);

    // 切到 0.5s/格：一屏变成 2.5s，格数不变。
    await tester.tap(find.text('0.5s'));
    await tester.pump();

    expect(chipOf('0.5s').selected, isTrue);
    expect(chipOf('2s').selected, isFalse);

    final EegWaveChartWidget after = wave();
    expect(after.config.xAxisInterval, 0.5);
    expect(after.config.xAxisDivisions, 5);
    expect(after.config.windowDuration, 2.5);
    // key 变了才说明是整体重建，缓冲与滤波器一并复位（数据从头展示）。
    expect(after.key, isNot(before.key));
  });

  testWidgets('未显式指定每格时间时按窗口时长均分', (WidgetTester tester) async {
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
              windowDuration: 20,
            ),
            sampleStream: controller.stream,
          ),
        ),
      ),
    ));

    for (int i = 0; i < 2500; i++) {
      controller.add(EegSample(
        rawAdc: 0,
        rawUv: 0,
        filteredUv: 0,
        timeSec: i / 250.0,
        channelIndex: 0,
      ));
    }
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));

    final LineChartData data =
        tester.widget<LineChart>(find.byType(LineChart)).data;
    // 未指定 xAxisInterval 时回退成 windowDuration / divisions = 4s。
    expect(data.titlesData.bottomTitles.sideTitles.interval, 4.0);
  });

  testWidgets('亚秒档位的时间刻度带小数，不会重复', (WidgetTester tester) async {
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
              windowDuration: 2.5,
              xAxisInterval: 0.5,
              xAxisDivisions: 5,
            ),
            sampleStream: controller.stream,
          ),
        ),
      ),
    ));

    for (int i = 0; i < 1000; i++) {
      controller.add(EegSample(
        rawAdc: 0,
        rawUv: 0,
        filteredUv: 0,
        timeSec: i / 250.0,
        channelIndex: 0,
      ));
    }
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));

    // 0.5s 间隔下标签应为 mm:ss.s，例如 "00:01.5"。
    final List<String> labels = tester
        .widgetList<Text>(find.byWidgetPredicate(
          (Widget w) => w is Text && w.data != null && w.data!.contains(':'),
        ))
        .map((Text t) => t.data!)
        .toList();

    expect(labels, isNotEmpty);
    expect(labels.any((String s) => s.contains('.')), isTrue,
        reason: '亚秒档位的刻度应带小数，否则相邻刻度秒数会重复');
  });
}
