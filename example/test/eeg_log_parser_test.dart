import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eeg_wave_chart_example/eeg_log_parser.dart';

/// 峰峰值。
double _p2p(List<double> xs) {
  double lo = double.infinity;
  double hi = -double.infinity;
  for (final double x in xs) {
    if (x < lo) lo = x;
    if (x > hi) hi = x;
  }
  return hi - lo;
}

double _mean(List<double> xs) {
  double s = 0;
  for (final double x in xs) {
    s += x;
  }
  return s / xs.length;
}

/// 用均值过零次数估频率。
double _freqHz(List<double> xs, double fs) {
  final double m = _mean(xs);
  int z = 0;
  for (int i = 1; i < xs.length; i++) {
    if (xs[i - 1] < m && xs[i] >= m) {
      z++;
    }
  }
  return z / (xs.length / fs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EegLogData data;
  setUpAll(() async {
    final String text = await rootBundle.loadString('assets/eeg_sample.log');
    data = EegLogParser.parse(text);
  });

  test('解析出完整的一分钟数据', () {
    // 500Hz × 60s = 30000，允许坏帧造成的少量缺失。
    expect(data.sampleCount, inInclusiveRange(29000, 30200));
    expect(data.durationSec, closeTo(60.0, 2.0));
    expect(data.sampleRate, 500.0);
  });

  test('坏帧被跳过而不是解析成乱码', () {
    // 实测第 168、195 帧帧头丢失。
    expect(data.skippedFrames, 2);
  });

  test('通道 7/8 的幅度符合 1mV 标定', () {
    for (int c = 0; c < data.channels.length; c++) {
      final List<double> xs = data.channels[c];
      // 信号发生器输入 1mV 振幅（峰峰 2mV），标定后应落在 ±1000µV 附近。
      final double p2p = _p2p(xs);
      expect(p2p, closeTo(2000.0, 200.0),
          reason: '通道 ${c + 7} 峰峰值 ${p2p.toStringAsFixed(0)}µV '
              '偏离 1mV 正弦应有的 2000µV');
    }
  });

  test('通道 7/8 的频率是 5Hz', () {
    for (int c = 0; c < data.channels.length; c++) {
      final double f = _freqHz(data.channels[c], data.sampleRate);
      expect(f, closeTo(5.0, 0.3),
          reason: '通道 ${c + 7} 频率 ${f.toStringAsFixed(2)}Hz 不是 5Hz');
    }
  });

  test('两路信号同频且几乎同相', () {
    final List<double> a = data.channels[0];
    final List<double> b = data.channels[1];
    final int n = math.min(a.length, b.length);
    // 同名信号源分两路采集，差值应远小于信号本身。
    double maxDiff = 0;
    for (int i = 0; i < n; i++) {
      maxDiff = math.max(maxDiff, (a[i] - b[i]).abs());
    }
    expect(maxDiff, lessThan(500.0),
        reason: '两路最大差 ${maxDiff.toStringAsFixed(0)}µV，不像是同一信号源');
  });

  test('滤波后直流偏移被去掉，幅度仍保持', () {
    final EegChannelFilter f =
        EegChannelFilter(fs: 500, notchFreq: 50.0, order: 4);
    final List<double> raw = data.channels[0];

    final double dcBefore = _mean(raw);
    expect(dcBefore.abs(), greaterThan(1000.0),
        reason: '原始数据应带明显的直流偏移（实测约 9.9mV）');

    final List<double> out = <double>[];
    for (int i = 0; i < 20000; i++) {
      out.add(f.processSample(raw[i]));
    }
    // 跳过前 2 秒启动瞬态后再统计。
    final List<double> steady = out.sublist(2000);
    expect(_mean(steady).abs(), lessThan(80.0),
        reason: '高通应把直流偏移滤掉，实测残余 ${_mean(steady).toStringAsFixed(0)}µV');
    expect(_p2p(steady), closeTo(2000.0, 250.0),
        reason: '滤波不应把 5Hz 信号衰减掉');
  });
}
