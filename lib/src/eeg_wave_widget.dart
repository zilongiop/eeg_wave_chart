import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'eeg_bucket_aggregator.dart';
import 'eeg_filter.dart';
import '../models/wave/eeg_types.dart';

/// 坐标轴名的文字样式。
const TextStyle _kAxisNameStyle = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w500,
);

/// 多导联滚动脑电波形控件。
///
/// 外部通过 [sampleStream] 持续推送原始样本，控件内部完成滤波、
/// 降采样与节流重绘，因此高频数据不会直接冲击 UI 帧。
class EegWaveChartWidget extends StatefulWidget {
  const EegWaveChartWidget({
    super.key,
    required this.config,
    required this.sampleStream,
  });

  /// 运行参数。
  final EegWaveConfig config;

  /// 外部推送新的原始样本。
  final Stream<EegSample> sampleStream;

  @override
  State<EegWaveChartWidget> createState() => _EegWaveChartWidgetState();
}

class _EegWaveChartWidgetState extends State<EegWaveChartWidget>
    with SingleTickerProviderStateMixin {
  late List<EegChannelFilter> _channelFilters;

  /// 每个通道的增量聚合器：桶关闭后产出的点就固定下来，不再重算。
  final Map<int, EegBucketAggregator> _aggregators =
      <int, EegBucketAggregator>{};

  /// 当前桶宽（秒）。变化时必须重建聚合器，否则新旧点密度不一致。
  double _bucketSec = 0.0;

  late StreamSubscription<EegSample> _sampleSub;

  /// 用 Ticker 而不是 Timer.periodic：回调跟屏幕刷新对齐，
  /// 滚动才不会忽快忽慢地「咯噔」。
  late Ticker _ticker;

  /// 上次重算时的 ticker 时间（毫秒）。
  int _lastProcessMs = 0;

  /// 上次重算得到的窗口右边界（秒）。
  double _endXAtProcess = 0.0;

  /// 当前窗口右边界（秒），每帧按真实时间平滑推进，且单调不回退。
  double _endX = 0.0;

  /// 缓冲区内最新样本的时间（秒）。
  double _latestTimeSec = 0.0;

  /// 自上次重绘以来是否收到过新样本。
  bool _pendingSamples = false;

  /// 收到的第一个样本的时间（秒），用于计算预热期起点。
  double _firstSampleSec = -1.0;

  @override
  void initState() {
    super.initState();
    _buildPipeline();

    // 订阅外部样本流。
    _sampleSub = widget.sampleStream.listen(_onNewRawSample);

    // 每帧跟随屏幕刷新回调：重算按 uiFps 节流，重绘则每帧都做，
    // 这样折线形状 25fps 更新、位移 60fps 更新，滚动是连续的。
    _ticker = createTicker(_onFrame)..start();
  }

  /// 构建采样管线：各通道滤波器 + 增量聚合器。
  ///
  /// 不再保留环形缓冲：滤波和聚合都是流式的，样本用完即弃，只需留下
  /// 聚合后的点，内存从「十几万条原始样本」降到「一屏的点数」。
  void _buildPipeline() {
    // 每个通道独立滤波器实例。
    _channelFilters = List<EegChannelFilter>.generate(
      widget.config.channelCount,
      (_) => EegChannelFilter(
        fs: widget.config.sampleRate,
        notchFreq: widget.config.notchFreq,
        order: widget.config.filterOrder,
      ),
      growable: false,
    );

    _bucketSec = _computeBucketSec();
    _aggregators.clear();
    // 管线重建意味着滤波器回到零状态，预热要重新开始。
    _lastProcessMs = 0;
    _endXAtProcess = 0.0;
    _endX = 0.0;
    _latestTimeSec = 0.0;
    _pendingSamples = false;
    _firstSampleSec = -1.0;
  }

  /// 桶宽：按刻度格聚合时为「每格时间 / 每格点数」，否则按点预算自适应。
  ///
  /// min/max 包络每个桶产出 2 个点，所以桶数取点预算的一半。
  double _computeBucketSec() {
    final int perDiv = widget.config.spotsPerDivision;
    double bucketSec;
    if (perDiv > 0) {
      bucketSec = _xAxisInterval / perDiv;
    } else {
      final int budget = widget.config.maxSpotsPerChannel > 0
          ? widget.config.maxSpotsPerChannel
          : 600;
      final int bucketCount = budget < 2 ? 1 : budget ~/ 2;
      bucketSec = widget.config.windowDuration / bucketCount;
    }
    // 桶至少覆盖 2 个采样周期，避免过度细分导致点数爆炸。
    final double minBucket = 2.0 / widget.config.sampleRate;
    if (bucketSec < minBucket) {
      bucketSec = minBucket;
    }
    return bucketSec;
  }

  @override
  void didUpdateWidget(covariant EegWaveChartWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有影响采样管线的参数变了才重建。父级每次 setState 都会新建
    // config 对象，若直接比较对象身份会每帧清空缓冲，波形永远画不满。
    final EegWaveConfig a = oldWidget.config;
    final EegWaveConfig b = widget.config;
    final bool pipelineChanged =
        a.sampleRate != b.sampleRate ||
        a.windowDuration != b.windowDuration ||
        a.channelCount != b.channelCount ||
        a.notchFreq != b.notchFreq ||
        a.filterOrder != b.filterOrder ||
        a.filterWarmupSec != b.filterWarmupSec ||
        a.displayUvRange != b.displayUvRange ||
        a.gain != b.gain;
    if (pipelineChanged) {
      _buildPipeline();
      return;
    }
    // 桶宽随这些参数变化，变了就要丢弃已聚合的点重新开始。
    if (a.maxSpotsPerChannel != b.maxSpotsPerChannel ||
        a.spotsPerDivision != b.spotsPerDivision ||
        a.xAxisInterval != b.xAxisInterval ||
        a.xAxisDivisions != b.xAxisDivisions) {
      final double bs = _computeBucketSec();
      if (bs != _bucketSec) {
        _bucketSec = bs;
        _aggregators.clear();
      }
    }
    // 数据源换了要重新订阅，否则收不到任何样本。
    if (!identical(oldWidget.sampleStream, widget.sampleStream)) {
      _sampleSub.cancel();
      _buildPipeline();
      _sampleSub = widget.sampleStream.listen(_onNewRawSample);
    }
  }

  /// 收到新原始样本：滤波 → 叠加基线并限幅 → 并入当前桶。
  ///
  /// 这里不做任何 UI 操作，也不保存原始样本。聚合在样本到达时就完成，
  /// 所以每帧的绘制只需复用已经定稿的点。
  void _onNewRawSample(EegSample rawSample) {
    final int ch = rawSample.channelIndex;
    if (ch < 0 || ch >= _channelFilters.length) {
      return;
    }
    // 真实数据往往带几 mV 的直流偏移（电极极化电压），必须靠高通去掉，
    // 否则波形会整体偏出量程。
    final double filtered = _channelFilters[ch].processSample(rawSample.rawUv);

    if (_firstSampleSec < 0) {
      _firstSampleSec = rawSample.timeSec;
    }
    // 预热期内只喂滤波器：不产出绘制点，也不推进窗口，避免把启动瞬态
    // 画成「开头幅度大」的一段波形。
    if (rawSample.timeSec - _firstSampleSec < widget.config.filterWarmupSec) {
      return;
    }

    if (rawSample.timeSec > _latestTimeSec) {
      _latestTimeSec = rawSample.timeSec;
    }

    // 基线偏移与限幅在这里一次做完，存进去的就是最终绘制值，
    // 绘制阶段因此不必再逐点变换、也不必重建 FlSpot。
    final double range = widget.config.displayUvRange;
    final double chOffset = range * 1.3;
    final double baseline = ch * chOffset;
    final double scaled = filtered * widget.config.gain;
    final double y = (scaled + baseline).clamp(
      baseline - range,
      baseline + range,
    );

    final EegBucketAggregator agg = _aggregators.putIfAbsent(
      ch,
      () => EegBucketAggregator(bucketSec: _bucketSec),
    );
    agg.addSample(rawSample.timeSec, y);
    _pendingSamples = true;
  }

  /// X 轴每格时间：未显式指定时按窗口时长均分到各格。
  double get _xAxisInterval {
    final int divisions = widget.config.xAxisDivisions < 1
        ? 1
        : widget.config.xAxisDivisions;
    return widget.config.xAxisInterval > 0
        ? widget.config.xAxisInterval
        : widget.config.windowDuration / divisions;
  }

  /// 每帧回调：推进窗口，并回收滚出左侧的旧点。
  ///
  /// 这里不再有任何全量遍历——点是在样本到达时就定稿的，每帧只做
  /// O(新增点 + 回收点) 的工作。
  void _onFrame(Duration elapsed) {
    final int intervalMs = (1000 / widget.config.uiFps).round();
    final int nowMs = elapsed.inMilliseconds;

    if (_pendingSamples && nowMs - _lastProcessMs >= intervalMs) {
      _pendingSamples = false;
      _lastProcessMs = nowMs;
      _endXAtProcess = _latestTimeSec;
    }

    // 回收滚出窗口左侧的点，避免列表随录制时长无限增长。
    final double startX = _endX - widget.config.windowDuration;
    for (final EegBucketAggregator agg in _aggregators.values) {
      agg.pruneBefore(startX);
    }

    // 两次重算之间按真实时间插值推进右边界，位移因此是连续的；
    // 再取 max 保证单调，避免窗口回退造成波形「弹回去」。
    final double drift = (nowMs - _lastProcessMs) / 1000.0;
    final double candidate =
        _endXAtProcess + drift.clamp(0.0, intervalMs / 1000.0);
    if (candidate > _endX) {
      _endX = candidate;
    }

    if (mounted) {
      setState(() {});
    }
  }

  /// 第 [ch] 个通道在左侧坐标轴上显示的名字。
  String _channelName(int ch) {
    final List<String> names = widget.config.channelNames;
    if (ch < names.length && names[ch].isNotEmpty) {
      return names[ch];
    }
    return 'CH${ch + 1}';
  }

  /// 把秒数格式化成 mm:ss；[withFraction] 时补一位小数（mm:ss.s）。
  ///
  /// 每格时间小于 1 秒（如 0.5s/格）时必须带小数，否则相邻刻度会显示成
  /// 完全相同的 mm:ss，看上去像刻度重复。
  static String _formatClock(double seconds, {bool withFraction = false}) {
    final double clamped = seconds < 0 ? 0.0 : seconds;
    final int mm = clamped ~/ 60;
    if (withFraction) {
      final double rest = clamped - mm * 60.0;
      return '${mm.toString().padLeft(2, '0')}:'
          '${rest.toStringAsFixed(1).padLeft(4, '0')}';
    }
    final int ss = clamped.floor() % 60;
    return '${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final List<LineChartBarData> lines = <LineChartBarData>[];
    final double chOffset = widget.config.displayUvRange * 1.3;
    final int channelCount = widget.config.channelCount;

    // 按通道顺序遍历，保证线条顺序稳定。
    //
    // 直接复用聚合器里已经定稿的点：基线偏移和限幅在样本到达时就做完了，
    // 这里既不重新计算、也不重建 FlSpot —— 已经画出来的点位不会被二次
    // 重算，所以波形左半部分在滚动时是完全静止的。
    final double range = widget.config.displayUvRange;
    for (int ch = 0; ch < channelCount; ch++) {
      final EegBucketAggregator? agg = _aggregators[ch];
      if (agg == null || agg.points.isEmpty) {
        continue;
      }
      lines.add(
        LineChartBarData(
          spots: agg.points,
          // 每个桶给出 max/min 包络，点之间用曲线过渡，兼顾尖峰与顺滑。
          isCurved: true,
          curveSmoothness: 0.2,
          preventCurveOverShooting: true,
          barWidth: 1.0,
          color: const Color(0xFF00BCD4),
          // 关闭圆点，性能关键。
          dotData: const FlDotData(show: false),
        ),
      );
    }

    // 窗口右边界由 _onFrame 按真实时间单调推进，左边界 = 右边界 - 窗口时长。
    final double endX = _endX;
    final double startX = endX - widget.config.windowDuration;

    final bool showTitles = widget.config.showAxisTitles;
    final double xAxisInterval = _xAxisInterval;

    return SizedBox(
      height: channelCount * widget.config.channelHeight,
      child: LineChart(
        LineChartData(
          minX: startX,
          maxX: endX,
          minY: -range,
          maxY: chOffset * (channelCount - 1) + range,
          lineBarsData: lines,
          clipData: const FlClipData.all(),
          // 只画横向分隔线，标出每个通道的基线，避免多导联糊在一起。
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: chOffset,
            getDrawingHorizontalLine: (_) => FlLine(
              color: Colors.grey.withValues(alpha: 0.35),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            // 左轴：每个通道基线处标通道名，轴名标单位 µV。
            leftTitles: AxisTitles(
              axisNameWidget: showTitles
                  ? const Text('µV', style: _kAxisNameStyle)
                  : null,
              axisNameSize: 22,
              sideTitles: SideTitles(
                showTitles: showTitles,
                reservedSize: 44,
                interval: chOffset,
                getTitlesWidget: (double value, TitleMeta meta) {
                  final int ch = (value / chOffset).round();
                  if (ch < 0 || ch >= channelCount) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 6,
                    child: Text(
                      _channelName(ch),
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
            // 下轴：时间，格式为 mm:ss。
            bottomTitles: AxisTitles(
              axisNameWidget: showTitles
                  ? const Text('时间', style: _kAxisNameStyle)
                  : null,
              axisNameSize: 22,
              sideTitles: SideTitles(
                showTitles: showTitles,
                reservedSize: 26,
                interval: xAxisInterval,
                getTitlesWidget: (double value, TitleMeta meta) =>
                    SideTitleWidget(
                      axisSide: meta.axisSide,
                      space: 4,
                      child: Text(
                        _formatClock(value, withFraction: xAxisInterval < 1.0),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
              ),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _sampleSub.cancel();
    for (final EegChannelFilter f in _channelFilters) {
      f.reset();
    }
    super.dispose();
  }
}
