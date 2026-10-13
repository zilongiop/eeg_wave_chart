import 'package:fl_chart/fl_chart.dart';

import '../models/wave/eeg_types.dart';

// 降采样 / 坐标换算的返回值都是 FlSpot，一并提出到插件的公开面，
// 下游就不必为了写个类型声明再去依赖 fl_chart。
export 'package:fl_chart/fl_chart.dart' show FlSpot;

/// 返回限制在 [-range, range] 内的 double 值。
double clampValue(double value, double range) {
  if (value < -range) {
    return -range;
  }
  if (value > range) {
    return range;
  }
  return value;
}

/// 把单个样本换算成画布坐标点。
class EegCoordinateConverter {
  EegCoordinateConverter({
    required this.gain,
    required this.displayUvRange,
  });

  /// 幅值增益。
  final double gain;

  /// 纵向显示量程（微伏）。
  final double displayUvRange;

  FlSpot convertSpot(EegSample sample) {
    final double y = clampValue(sample.filteredUv * gain, displayUvRange);
    return FlSpot(sample.timeSec, y);
  }

  List<FlSpot> convertSpots(List<EegSample> samples) =>
      List<FlSpot>.generate(samples.length, (int i) => convertSpot(samples[i]),
          growable: false);
}
