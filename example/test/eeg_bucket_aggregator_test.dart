import 'dart:math' as math;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('每个桶输出 max / min 两个点，按时间先后排列', () {
    final EegBucketAggregator agg =
        EegBucketAggregator(bucketSec: 0.1);

    // 桶 [0, 0.1)：先来 1.0，再来 5.0（最大），最后 3.0。
    agg.addSample(0.01, 1.0);
    agg.addSample(0.02, 5.0);
    agg.addSample(0.03, 3.0);
    // 桶 0 此时还没关闭，不应产出任何点。
    expect(agg.points, isEmpty);

    // 进入桶 1，桶 0 关闭并定稿：min=1.0 (t=0.01)，max=5.0 (t=0.02)。
    agg.addSample(0.10, 0.0);
    expect(agg.points.length, 2);
    // min 的时间更早，所以先输出 min。
    expect(agg.points[0].x, closeTo(0.01, 1e-9));
    expect(agg.points[0].y, 1.0);
    expect(agg.points[1].x, closeTo(0.02, 1e-9));
    expect(agg.points[1].y, 5.0);
  });

  test('桶内只有一个样本时只输出一个点', () {
    final EegBucketAggregator agg = EegBucketAggregator(bucketSec: 1.0);
    agg.addSample(0.5, 7.0);
    agg.addSample(1.5, 7.0); // 关闭桶 0、开启桶 1
    expect(agg.points.length, 1);
    expect(agg.points[0].y, 7.0);
  });

  test('已定稿的点不再被重算：对象保持同一个实例', () {
    final EegBucketAggregator agg = EegBucketAggregator(bucketSec: 0.1);

    // 灌满前 30 个桶。
    for (int i = 0; i < 750; i++) {
      agg.addSample(i / 250.0, 20 * math.sin(2 * math.pi * 10 * (i / 250.0)));
    }
    expect(agg.points.length, greaterThan(20));

    // 快照最初的几个点。
    final List<FlSpot> before = agg.points.sublist(0, 10);

    // 继续灌 3 秒（窗口持续右移，旧桶不断被回收前的这段时间里，
    // 已定稿的点不应发生任何变化）。
    for (int i = 750; i < 1500; i++) {
      agg.addSample(i / 250.0, 20 * math.sin(2 * math.pi * 10 * (i / 250.0)));
    }

    final List<FlSpot> after = agg.points.sublist(0, 10);
    for (int i = 0; i < before.length; i++) {
      // 同一个 FlSpot 实例 → 证明没有被二次重建。
      expect(identical(after[i], before[i]), isTrue,
          reason: '第 $i 个点被重新创建了，说明发生了二次重算');
    }
  });

  test('pruneBefore 只丢弃窗口左侧的点，且保留一个用于连线', () {
    final EegBucketAggregator agg = EegBucketAggregator(bucketSec: 0.1);
    for (int i = 0; i < 1000; i++) {
      agg.addSample(i / 250.0, 1.0);
    }
    final int total = agg.points.length;
    expect(total, greaterThan(10));

    // 丢弃 x < 2.0 的点。
    agg.pruneBefore(2.0);
    expect(agg.points.length, lessThan(total));
    // 保留下来的第一个点应紧邻窗口左边界（<= 2.0），以便连线不断口。
    expect(agg.points.first.x, lessThanOrEqualTo(2.0));
    // 剩下的点都在窗口内。
    expect(agg.points.last.x, greaterThan(2.0));
  });

  test('reset 后重新开始', () {
    final EegBucketAggregator agg = EegBucketAggregator(bucketSec: 0.1);
    for (int i = 0; i < 500; i++) {
      agg.addSample(i / 250.0, 1.0);
    }
    expect(agg.points, isNotEmpty);
    agg.reset();
    expect(agg.points, isEmpty);
  });
}
