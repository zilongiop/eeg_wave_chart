import 'package:fl_chart/fl_chart.dart';

import '../models/wave/eeg_types.dart';

/// 分组降采样器。
class EegDownSampler {
  EegDownSampler({this.groupPointCount = 5});

  /// 每 N 个原始点合并为一组。
  final int groupPointCount;

  /// 输入单一导联的全部样本，输出降采样后的 [FlSpot] 列表。
  ///
  /// [groupSize] 覆盖默认的 [groupPointCount]，用于按点预算自适应调粗。
  List<FlSpot> downsample(List<EegSample> samples, {int? groupSize}) {
    final List<FlSpot> output = <FlSpot>[];
    if (samples.isEmpty) {
      return output;
    }
    final int group = groupSize == null || groupSize < 1
        ? groupPointCount
        : groupSize;

    final int total = samples.length;
    // 直接在原列表上按区间扫描，避免每帧为每个分组 sublist 分配临时列表。
    for (int i = 0; i < total; i += group) {
      final int end = i + group > total ? total : i + group;

      EegSample maxSample = samples[i];
      EegSample minSample = samples[i];
      for (int j = i + 1; j < end; j++) {
        final EegSample s = samples[j];
        if (s.filteredUv > maxSample.filteredUv) {
          maxSample = s;
        }
        if (s.filteredUv < minSample.filteredUv) {
          minSample = s;
        }
      }

      // 必须按时间递增输出，否则折线会出现回折。
      final EegSample first =
          maxSample.timeSec <= minSample.timeSec ? maxSample : minSample;
      final EegSample second =
          maxSample.timeSec <= minSample.timeSec ? minSample : maxSample;
      output.add(FlSpot(first.timeSec, first.filteredUv));
      if (!identical(first, second)) {
        output.add(FlSpot(second.timeSec, second.filteredUv));
      }
    }
    return output;
  }

  /// 按「绝对时间分桶 + 均值」降采样。
  ///
  /// 1. 分桶边界锚定在全局时间轴上（bucket = t / bucketSec），
  ///    新样本进入、旧数据淘汰时已有分桶的边界不会整体位移，
  ///    相邻帧之间折线顶点保持稳定。
  /// 2. 每个桶只输出一个均值点，而不是 min/max 两个包络点。
  ///    min/max 包络会在 10Hz 这类节律上形成密集的「之」字形锯齿，
  ///    并且锯齿相位随桶边界漂移，整条曲线看起来就在「沸腾」闪烁；
  ///    均值连线才是平滑的趋势线。
  ///
  /// 最后一个尚未填满的桶不输出，避免波形最右端每帧跳动。
  List<FlSpot> downsampleByTime(List<EegSample> samples, double bucketSec) {
    final List<FlSpot> output = <FlSpot>[];
    if (samples.isEmpty || bucketSec <= 0) {
      return output;
    }

    // samples 必须按时间升序。
    int bucket = -1;
    double sumY = 0.0;
    double sumT = 0.0;
    int count = 0;

    void flush() {
      if (count == 0) {
        return;
      }
      output.add(FlSpot(sumT / count, sumY / count));
    }

    for (final EegSample s in samples) {
      final int b = (s.timeSec / bucketSec).floor();
      if (b != bucket) {
        // 已经进入下一个桶，说明上一个桶数据完整，可以输出。
        flush();
        bucket = b;
        sumY = s.filteredUv;
        sumT = s.timeSec;
        count = 1;
      } else {
        sumY += s.filteredUv;
        sumT += s.timeSec;
        count++;
      }
    }
    return output;
  }
}
