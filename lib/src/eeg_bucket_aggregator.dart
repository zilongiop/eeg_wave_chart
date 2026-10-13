import 'package:fl_chart/fl_chart.dart';

/// 单通道的增量桶聚合器（min/max 包络）。
///
/// 样本按时间到达时就立即并入当前桶；一旦下一个桶开始，当前桶就被"关闭"，
/// 它产出的点从此**不再改变**。因此屏幕上已经画出来的历史点不会被二次
/// 重算，波形左半部分完全静止，只有最右端在生长——滚动时不会有任何抖动，
/// 也省掉了每帧重新扫描全部原始样本的开销。
///
/// 每个关闭的桶输出 max / min 两个点（按时间先后排列），这样尖峰和包络
/// 不会被平均掉；桶内只有一个样本时只输出一个点。
class EegBucketAggregator {
  EegBucketAggregator({required this.bucketSec});

  /// 桶宽（秒），决定屏幕上的点密度。改变它需要 [reset]。
  final double bucketSec;

  /// 已关闭的桶产出的绘制点，按 x 升序。可直接交给 fl_chart。
  final List<FlSpot> points = <FlSpot>[];

  int _bucket = -1;
  bool _filled = false;
  double _maxV = 0.0;
  double _minV = 0.0;
  double _maxT = 0.0;
  double _minT = 0.0;

  /// 并入一个样本。[valueUv] 应当是最终用于绘制的值（已叠加基线、已限幅）。
  void addSample(double timeSec, double valueUv) {
    final int b = (timeSec / bucketSec).floor();
    if (b != _bucket) {
      // 进入新桶，说明上一个桶已经收满，可以定稿输出。
      _flush();
      _bucket = b;
      _maxV = valueUv;
      _minV = valueUv;
      _maxT = timeSec;
      _minT = timeSec;
      _filled = true;
      return;
    }
    if (valueUv > _maxV) {
      _maxV = valueUv;
      _maxT = timeSec;
    }
    if (valueUv < _minV) {
      _minV = valueUv;
      _minT = timeSec;
    }
  }

  void _flush() {
    if (!_filled) {
      return;
    }
    // 必须按时间递增输出，否则折线会回折。
    final bool maxFirst = _maxT <= _minT;
    points.add(FlSpot(maxFirst ? _maxT : _minT, maxFirst ? _maxV : _minV));
    if (_minT != _maxT) {
      points.add(FlSpot(maxFirst ? _minT : _maxT, maxFirst ? _minV : _maxV));
    }
  }

  /// 丢弃已经滚出窗口左侧的点，避免列表无限增长。
  ///
  /// [points] 始终按 x 升序，所以这里用二分定位，再整段移除。
  void pruneBefore(double startX) {
    int lo = 0;
    int hi = points.length;
    while (lo < hi) {
      final int mid = lo + ((hi - lo) >> 1);
      if (points[mid].x < startX) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // 多留一个点，让折线能从窗口左边界外连进来，避免边缘出现断口。
    final int keep = lo > 0 ? lo - 1 : 0;
    if (keep > 0) {
      points.removeRange(0, keep);
    }
  }

  void reset() {
    points.clear();
    _bucket = -1;
    _filled = false;
  }
}
