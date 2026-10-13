import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:eeg_wave_chart_example/eeg_simulator.dart';
import 'package:flutter_test/flutter_test.dart';

EegSimulator createSimulator({
  int channelCount = 1,
  int sampleRate = 250,
  Duration totalDuration = const Duration(minutes: 10),
}) {
  return EegSimulator(
    profiles: EegSimulator.defaultProfiles()
        .take(channelCount)
        .toList(growable: false),
    sampleRate: sampleRate,
    totalDuration: totalDuration,
  );
}

void main() {
  test('模拟器按 4ms 步进推进 10 分钟，总帧数为 150000', () {
    final EegSimulator simulator = createSimulator();

    expect(simulator.sampleRate, 250);
    expect(simulator.totalDuration, const Duration(minutes: 10));
    expect(simulator.totalTimeMs, closeTo(600000, 1e-9));
    expect(simulator.isFinished, isFalse);
    expect(simulator.progress, 0);

    int total = 0;
    while (!simulator.isFinished) {
      total += simulator
          .takeFramesUpTo(simulator.currentTimeMs + 4000,
              maxFramesPerBatch: 5000)
          .length;
    }

    expect(total, 150000);
    expect(simulator.currentTimeMs, closeTo(600000, 1e-9));
    expect(simulator.progress, 1);
    expect(simulator.isFinished, isTrue);
  });

  test('每帧的导联数量与配置的通道数一致', () {
    const int channelCount = 6;
    final EegSimulator simulator = createSimulator(channelCount: channelCount);

    final List<EegSimFrame> frames =
        simulator.takeFramesUpTo(1000, maxFramesPerBatch: 1000);
    expect(frames.length, greaterThan(0));
    for (final EegSimFrame frame in frames) {
      expect(frame.rawSamplesUv.length, channelCount);
    }
  });

  test('10 分钟后不再吐出新帧，reset 后可以重新播放', () {
    final EegSimulator simulator = createSimulator();

    simulator.takeFramesUpTo(simulator.currentTimeMs + 600001,
        maxFramesPerBatch: 200000);
    expect(simulator.isFinished, isTrue);
    expect(simulator.takeFramesUpTo(simulator.currentTimeMs + 4000), isEmpty);

    simulator.reset();
    expect(simulator.currentTimeMs, 0);
    expect(simulator.isFinished, isFalse);
    expect(
      simulator.takeFramesUpTo(1000, maxFramesPerBatch: 1000).length,
      greaterThan(0),
    );
  });

  test('单导联滤波器能抑制直流与工频干扰', () {
    final EegChannelFilter filter = EegChannelFilter(
      fs: 250,
      notchFreq: 50,
      order: 2,
    );

    double peak(double freqHz, double amp) {
      double result = 0;
      // 先跑一段让滤波器达到稳态，避免把瞬态当结果。
      for (int i = 0; i < 1250; i++) {
        final double t = i / 250.0;
        final double v = 200 + amp * math.sin(2 * math.pi * freqHz * t);
        final double out = filter.processSample(v);
        if (i > 625) {
          result = result.abs() > out.abs() ? result : out;
        }
      }
      return result;
    }

    // 直流（0Hz）应被高通+去趋势压掉。
    expect(peak(0, 200).abs(), lessThan(20));
    // 50Hz 工频应被陷波压掉到远低于带内信号。
    expect(peak(50, 100).abs(), lessThan(10));
    // 10Hz 带内信号应当基本保留。
    expect(peak(10, 100).abs(), greaterThan(30));
  });

  testWidgets('模拟数据接入波形控件后可以渲染出折线', (WidgetTester tester) async {
    const int channelCount = 2;
    final EegSimulator simulator = createSimulator(channelCount: channelCount);
    final EegRingBuffer ringBuffer = EegRingBuffer(2000);
    final List<EegChannelFilter> filters =
        List<EegChannelFilter>.generate(channelCount, (_) {
      return EegChannelFilter(fs: 250, notchFreq: 50, order: 2);
    }, growable: false);

    // 取 2 秒数据，模拟 500Hz @ 2s 的全部进入。
    for (final EegSimFrame frame
        in simulator.takeFramesUpTo(2000, maxFramesPerBatch: 1000)) {
      for (int ch = 0; ch < channelCount; ch++) {
        ringBuffer.push(
          EegSample(
            rawUv: frame.rawSamplesUv[ch],
            filteredUv: filters[ch].processSample(frame.rawSamplesUv[ch]),
            timeSec: frame.timeMs / 1000.0,
            channelIndex: ch, rawAdc: 12,
          ),
        );
      }
    }

    final List<EegSample> all = ringBuffer.getAll();
    expect(all.length, greaterThan(0));

    final Map<int, List<EegSample>> grouped = <int, List<EegSample>>{};
    for (final EegSample s in all) {
      grouped.putIfAbsent(s.channelIndex, () => <EegSample>[]).add(s);
    }
    expect(grouped.length, channelCount);

    // 每个通道降采样后都要有可绘制的点，且 x 必须单调递增。
    for (final List<EegSample> samples in grouped.values) {
      final List<FlSpot> spots =
          EegDownSampler(groupPointCount: 5).downsample(samples);
      expect(spots, isNotEmpty);
      for (int i = 1; i < spots.length; i++) {
        expect(spots[i].x, greaterThanOrEqualTo(spots[i - 1].x));
      }
    }
  });
}
