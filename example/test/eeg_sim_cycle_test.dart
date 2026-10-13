import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eeg_wave_chart_example/main.dart';

/// 统计一段信号经实时滤波后的峰峰值。
_Stat _cycleStat(DemoEegSignal sig, EegChannelFilter f, int cycle) {
  const int sr = 250;
  double lo = double.infinity;
  double hi = -double.infinity;
  for (int i = 0; i < sr * DemoEegSignal.cycleSec; i++) {
    final double t = cycle * DemoEegSignal.cycleSec + i / sr;
    final double out = f.processSample(sig.generate(t, 0));
    if (out < lo) lo = out;
    if (out > hi) hi = out;
  }
  return _Stat(lo: lo, hi: hi, peakToPeak: hi - lo);
}

class _Stat {
  const _Stat({required this.lo, required this.hi, required this.peakToPeak});
  final double lo;
  final double hi;
  final double peakToPeak;
}

void main() {
  test('信号严格按 8 秒循环重复', () {
    // 关掉随机噪声后必须是精确周期信号。
    final DemoEegSignal sig = DemoEegSignal(noiseUv: 0);

    for (int i = 0; i < 4000; i++) {
      final double t = i / 250.0;
      final double diff = (sig.generate(t + DemoEegSignal.cycleSec, 0) -
              sig.generate(t, 0))
          .abs();
      expect(diff, lessThan(1e-9),
          reason: 't=${t.toStringAsFixed(3)} 处与下一循环不符，偏差 $diff');
    }
    // 所有分量频率都必须是基准频率的整数倍，否则循环会对不齐。
    expect(10.0 / DemoEegSignal.baseHz, closeTo(80.0, 1e-9)); // α
    expect(18.0 / DemoEegSignal.baseHz, closeTo(144.0, 1e-9)); // β
    expect(50.0 / DemoEegSignal.baseHz, closeTo(400.0, 1e-9)); // 工频
  });

  test('滤波进入稳态后每个循环的幅度完全一致', () {
    final DemoEegSignal sig = DemoEegSignal(noiseUv: 0);
    final EegChannelFilter f =
        EegChannelFilter(fs: 250, notchFreq: 50.0, order: 4);

    // 第一个循环包含 IIR 启动瞬态（约 1~2 秒），不参与比较。
    _cycleStat(sig, f, 0);
    final _Stat second = _cycleStat(sig, f, 1);

    for (int cycle = 2; cycle < 8; cycle++) {
      final _Stat cur = _cycleStat(sig, f, cycle);
      expect(
        (cur.peakToPeak - second.peakToPeak).abs(),
        lessThan(second.peakToPeak * 0.02),
        reason: '第 ${cycle + 1} 循环的峰峰值 ${cur.peakToPeak.toStringAsFixed(1)} '
            '与第 2 循环 ${second.peakToPeak.toStringAsFixed(1)} 相差过大',
      );
      expect(cur.hi - second.hi, lessThan(1.0),
          reason: '第 ${cycle + 1} 循环上边界明显偏高');
      expect(cur.lo - second.lo, greaterThan(-1.0),
          reason: '第 ${cycle + 1} 循环下边界明显偏低');
    }
  });

  test('稳态峰峰值落在 displayUvRange=30 的量程内，不会被削平', () {
    final DemoEegSignal sig = DemoEegSignal(noiseUv: 2.5);
    final EegChannelFilter f =
        EegChannelFilter(fs: 250, notchFreq: 50.0, order: 4);

    _cycleStat(sig, f, 0); // 跳过启动瞬态
    _cycleStat(sig, f, 1);
    final _Stat steady = _cycleStat(sig, f, 2);

    // 含噪声的稳态输出必须能被 30µV 量程完整容纳，否则顶部会被削平。
    expect(steady.hi, lessThan(30.0));
    expect(steady.lo, greaterThan(-30.0));
    // 同时要足够饱满（占满量程的一半以上），否则看上去还是扁。
    expect(steady.peakToPeak, greaterThan(30.0));

    math.max(steady.hi, -steady.lo); // 保持可读：峰峰值已在上面断言
  });
}
