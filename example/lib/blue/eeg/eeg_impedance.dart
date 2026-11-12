/// 阻抗：合格判定与事件广播
///
/// ## v1.0.9 起（当前协议）
///
/// 设备端算好 8 通道 kΩ、按「定标 ×10」组包下发（CMD 0x8C，见
/// `EegImpedanceFrame`），APP 直接用结果判定 → [feedImpedanceFrame]。
///
/// ## ≤ v1.0.8（旧协议 / 离线日志回放）
///
/// 设备发原始采样（CMD 0x90），APP 侧按下列公式自行算 kΩ → [feedSamples]。
/// 算法来源：《2026.05.25_阻抗测量.pdf》
///
/// 算法来源：《2026.05.25_阻抗测量.pdf》
/// ```
/// 1. 取最近 2 秒数据，去直流
/// 2. 加汉宁窗
/// 3. rFFT，取 31.2 Hz 所在 bin 及左右各 1 个 bin 的能量合成幅值
/// 4. Z = V / I - 串联电阻，I = leadOffCurrent × 4/π
/// ```
///
/// ⚠️ 与 Python 参考实现的差异（刻意保留，便于在 Dart 侧落地）：
/// * 只算目标 bin 及邻域的**直接 DFT**，而不是整段 FFT。
///   两者数学等价（已用 numpy `rfft` 逐位比对，误差 0.000000%），
///   但复杂度从 O(N log N) 降到 O(3N)，且不要求 N 是 2 的幂。
/// * `np.hanning(N)` 是**对称窗** `0.5×(1−cos(2πn/(N−1)))`，已按此实现。
///
/// ## 参数标定（来自 `只有通道8外接150k电阻.log`）
///
/// 该日志共 113 帧 × 100 点 × 8 通道，跨 22.424 s：
/// * 推得**采样率 ≈ 500 Hz**（272556 B ÷ 22.424 s ÷ 2400 B/帧 × 100 点）；
/// * 通道 8 外接 150 kΩ，谱峰落在 **31.24 Hz**（≈ 31.2 Hz），
///   通道 1~7 谱峰 ~4 LSB（噪声底）；
/// * 按 2 秒窗（N=1000）算得通道 8 幅值 **15792.84 LSB**，
///   反推 `microVoltsPerLsb = 0.126979`（取 `seriesResistorKohm = 0`）。
///
/// ⚠️ 该系数与 **窗长、采样率强相关**（N=11300 时会得到 0.151959）。
/// 换窗长或采样率后必须用 [ImpedanceCalcConfig.calibrate] 重新标定。
///
/// ## 用法
///
/// ```dart
/// // 1. 配置合格标准（默认 50 kΩ / 至少 5 通道；
/// //    不配则只发 Result 事件、不发 Fail/Pass）
/// EegImpedanceManager.i.quality = const ImpedanceStandard.defaults();
///
/// // 2. 全局挂载：自动订阅 EegImpedanceEvent（0x90 帧）并喂数据
/// EegImpedanceManager.i.attach();
///
/// // 3. 订阅方响应
/// EventBusManager.i.on<EegImpedanceFailEvent>().listen((e) {
///   debugPrint('阻抗不合格：${e.result.failedChannels}');
/// });
/// ```
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../common/event_bus_manager.dart';
import 'eeg_config.dart';
import 'eeg_data_frame.dart';
import 'eeg_event.dart';

// ---------------------------------------------------------------------------
// 1. 计算参数
// ---------------------------------------------------------------------------

/// 阻抗计算参数
class ImpedanceCalcConfig {
  const ImpedanceCalcConfig({
    this.leadOffCurrentNA = 10.5,
    this.seriesResistorKohm = 0,
    this.microVoltsPerLsb = 0.126979,
    this.sampleRateHz = 500,
    this.targetFreqHz = 31.2,
    this.windowSeconds = 2.0,
    this.neighborBins = 1,
  });

  /// 导联脱落检测电流（nA），A99C8 芯片内部校准值
  ///
  /// PDF 中 `self.leadoff_current = 10.5e-9`。
  final double leadOffCurrentNA;

  /// P 端与 SRB1 端串联电阻之和（kΩ）
  ///
  /// PDF 中 `self.series_resistor_kohm`，需向固件确认实际值；
  /// 未确认前保持 0，标定系数 [microVoltsPerLsb] 已按 0 反推。
  final double seriesResistorKohm;

  /// 原始 LSB → 微伏 的换算系数
  ///
  /// 由 150 kΩ 已知电阻标定（2 s @ 500 Hz 窗口）。
  /// 若固件改了增益 / 参考电压，或改了窗长，用 [calibrate] 重算。
  final double microVoltsPerLsb;

  /// 阻抗采样率（Hz）
  ///
  /// 日志实测 ≈ 500 Hz。注意 `eeg_debug_page` 里下发的是 250 Hz，
  /// 与实测不符，联调时需向固件确认哪一项为准。
  final int sampleRateHz;

  /// 激励信号频率（Hz）
  final double targetFreqHz;

  /// 计算窗口时长（秒）；PDF 建议 2 秒
  final double windowSeconds;

  /// 目标 bin 左右各取几个 bin 参与能量合成；PDF 为 ±1
  final int neighborBins;

  /// 窗口采样点数
  int get windowSamples => (sampleRateHz * windowSeconds).round();

  /// 基波峰值电流（A）：`I × 4/π`
  double get fundPeakCurrentA => leadOffCurrentNA * 1e-9 * (4.0 / math.pi);

  /// 由谱幅值（LSB）算阻抗（kΩ）
  ///
  /// ```
  /// Z = (V_uV × 1e-6 / I_peak) / 1000 − Rs
  ///   = V_uV / (I_peak × 1e9) − Rs
  /// ```
  /// 结果下限截断到 0（极低阻抗时减串联电阻会出负数，与 PDF 的 `np.clip` 一致）。
  double kohmFromAmplitude(double amplitudeLsb) {
    final v = amplitudeLsb * microVoltsPerLsb;
    final z = v / (fundPeakCurrentA * 1e9) - seriesResistorKohm;
    return z < 0 ? 0 : z;
  }

  /// 用已知电阻标定 [microVoltsPerLsb]
  ///
  /// 必须在**与运行时相同的** [sampleRateHz] / [windowSeconds] 下标定，
  /// 否则幅值估计会偏离（谱泄漏随窗长变化）。
  ///
  /// ```dart
  /// // 通道 8 外接 150 kΩ，取该通道 1000 点原始值
  /// final scale = config.calibrate(
  ///   knownKohm: 150,
  ///   samples: X[7],
  /// );
  /// ```
  double calibrate({required double knownKohm, required List<int> samples}) {
    final amp = ImpedanceSpectrum.amplitude(samples, this);
    if (amp <= 0) return microVoltsPerLsb;
    final needMicroVolts =
        (knownKohm + seriesResistorKohm) * fundPeakCurrentA * 1e9;
    return needMicroVolts / amp;
  }

  ImpedanceCalcConfig copyWith({
    double? leadOffCurrentNA,
    double? seriesResistorKohm,
    double? microVoltsPerLsb,
    int? sampleRateHz,
    double? targetFreqHz,
    double? windowSeconds,
    int? neighborBins,
  }) => ImpedanceCalcConfig(
    leadOffCurrentNA: leadOffCurrentNA ?? this.leadOffCurrentNA,
    seriesResistorKohm: seriesResistorKohm ?? this.seriesResistorKohm,
    microVoltsPerLsb: microVoltsPerLsb ?? this.microVoltsPerLsb,
    sampleRateHz: sampleRateHz ?? this.sampleRateHz,
    targetFreqHz: targetFreqHz ?? this.targetFreqHz,
    windowSeconds: windowSeconds ?? this.windowSeconds,
    neighborBins: neighborBins ?? this.neighborBins,
  );

  @override
  String toString() =>
      'ImpedanceCalcConfig(I=$leadOffCurrentNA nA, Rs=$seriesResistorKohm kΩ, '
      '$microVoltsPerLsb µV/LSB, $sampleRateHz Hz, $targetFreqHz Hz, '
      '$windowSeconds s=$windowSamples 点)';
}

// ---------------------------------------------------------------------------
// 2. 频谱计算
// ---------------------------------------------------------------------------

/// 阻抗频谱计算（直接 DFT，只算目标 bin 及邻域）
abstract final class ImpedanceSpectrum {
  /// 对称汉宁窗缓存：`w[n] = 0.5 × (1 − cos(2πn/(N−1)))`
  static final Map<int, Float64List> _windows = <int, Float64List>{};

  static Float64List _hann(int n) {
    final cached = _windows[n];
    if (cached != null) return cached;
    final w = Float64List(n);
    if (n == 1) {
      w[0] = 1;
    } else {
      for (var i = 0; i < n; i++) {
        w[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
      }
    }
    _windows[n] = w;
    return w;
  }

  /// 求 [samples] 在 [config.targetFreqHz] 及其邻域的合成幅值（LSB）
  ///
  /// 与 Python `np.fft.rfft` + `np.hanning` + `abs/(N/2)*2.0` 等价。
  /// 点数不足（< 8）或全为常数时返回 0。
  static double amplitude(List<int> samples, ImpedanceCalcConfig config) {
    final n = samples.length;
    if (n < 8) return 0;

    // 去直流
    var sum = 0.0;
    for (final v in samples) {
      sum += v;
    }
    final mean = sum / n;

    final w = _hann(n);
    final idx = (config.targetFreqHz * n / config.sampleRateHz).round();
    final from = math.max(0, idx - config.neighborBins);
    final to = math.min(n ~/ 2, idx + config.neighborBins);

    var energy = 0.0;
    for (var k = from; k <= to; k++) {
      var re = 0.0;
      var im = 0.0;
      for (var i = 0; i < n; i++) {
        final x = (samples[i] - mean) * w[i];
        final angle = -2 * math.pi * k * i / n;
        re += x * math.cos(angle);
        im += x * math.sin(angle);
      }
      // 与 numpy 一致：mag = |X| / (N/2) × 2.0
      final mag = math.sqrt(re * re + im * im) / (n / 2) * 2.0;
      energy += mag * mag;
    }
    return math.sqrt(energy);
  }
}

// ---------------------------------------------------------------------------
// 3. 结果模型
// ---------------------------------------------------------------------------

/// 单通道阻抗结果
class ImpedanceChannelResult {
  const ImpedanceChannelResult({
    required this.channel,
    required this.amplitudeLsb,
    required this.voltMicrovolts,
    required this.kohm,
    required this.isPass,
  });

  /// 物理通道号（1 起始，由 ChannelMask 的位序推出）
  final int channel;

  /// 31.2 Hz 邻域合成谱幅值（原始 LSB）
  final double amplitudeLsb;

  /// 换算后的电压峰值（µV）
  final double voltMicrovolts;

  /// 阻抗（kΩ）
  final double kohm;

  /// 是否满足合格标准；未配置标准时为 true
  final bool isPass;

  @override
  String toString() =>
      'ch$channel ${kohm.toStringAsFixed(1)}kΩ${isPass ? '' : ' ✗'}';
}

/// 一次阻抗测量结果
class ImpedanceResult {
  const ImpedanceResult({
    required this.time,
    required this.channels,
    required this.config,
    this.quality,
    this.seq = 0,
  });

  /// 测量完成时刻
  final DateTime time;

  /// 各通道结果（按物理通道号升序）
  final List<ImpedanceChannelResult> channels;

  /// 本次使用的计算参数快照
  final ImpedanceCalcConfig config;

  /// 本次使用的合格标准；为 null 表示未配置，不判定
  final ImpedanceStandard? quality;

  /// 第几次测量（管理器内自增，从 1 开始）
  final int seq;

  /// 阻抗上限（kΩ）；未配置标准为 null
  double? get maxKohm => quality?.impStandardKohm?.toDouble();

  /// 要求达标的最少通道数；未配置标准为 null
  int? get requiredChannels => quality?.impStandardChannel;

  /// 达标通道数
  int get passedCount => channels.where((c) => c.isPass).length;

  /// 未达标通道
  List<ImpedanceChannelResult> get failedChannels =>
      channels.where((c) => !c.isPass).toList(growable: false);

  /// 是否配置了合格标准
  bool get hasRule => quality != null;

  /// 是否合格
  ///
  /// 未配置 [quality] 时恒为 true（无标准即无从判定）；
  /// 管理器此时也**不会**发 `EegImpedanceFail/PassEvent`。
  bool get isPass {
    final q = quality;
    if (q == null) return true;
    return passedCount >= (q.impStandardChannel ?? channels.length);
  }

  /// 按通道号取结果
  ImpedanceChannelResult? of(int channel) {
    for (final c in channels) {
      if (c.channel == channel) return c;
    }
    return null;
  }

  @override
  String toString() {
    final verdict = hasRule
        ? ' → ${isPass ? '合格' : '不合格'}'
              '($passedCount/$requiredChannels)'
        : '';
    return 'ImpedanceResult#$seq '
        '${channels.map((c) => c.toString()).join(' ')}$verdict';
  }
}

// ---------------------------------------------------------------------------
// 4. 全局管理器
// ---------------------------------------------------------------------------

/// 阻抗数据管理器（全局单例）
///
/// 职责：
/// 1. 收 0x8C 阻抗结果帧 → 直接判定（主路径）；
///    收 0x90 原始采样帧 → 按通道累积、攒满窗口算 kΩ（旧协议）；
/// 3. 按 [quality] 判定合格 / 不合格；
/// 4. 广播 `EegImpedanceResultEvent`（每次）、
///    `EegImpedanceFailEvent` / `EegImpedancePassEvent`（判定后）。
///
/// 订阅方示例：
/// ```dart
/// final sub = EventBusManager.i.on<EegImpedanceFailEvent>().listen((e) {
///   // 提示用户调整电极
/// });
/// ```
class EegImpedanceManager {
  EegImpedanceManager._();

  static final EegImpedanceManager _instance = EegImpedanceManager._();

  /// 单例
  static EegImpedanceManager get instance => _instance;

  /// 单例简写
  static EegImpedanceManager get i => _instance;

  /// 计算参数（默认已按 150 kΩ 日志标定）
  ///
  /// 赋值会自动清空缓冲，避免新旧参数混算。
  ImpedanceCalcConfig _config = const ImpedanceCalcConfig();

  /// 合格标准（`ImpedanceStandard`：阻抗阈值 + 要求达标通道数）
  ///
  /// 为 null 表示不判定，此时只发 `EegImpedanceResultEvent`，
  /// 不发 `EegImpedanceFailEvent` / `EegImpedancePassEvent`。
  ImpedanceStandard? quality;

  int _hopSamples = 0;
  bool _running = true;
  bool _attached = false;
  int _seq = 0;

  /// 按通道号（1 起始）累积的采样缓冲
  final Map<int, List<int>> _buffer = <int, List<int>>{};

  /// 当前缓冲对应的物理通道号（升序）
  List<int> _channelNumbers = const <int>[];

  ImpedanceResult? _latest;
  StreamSubscription<EegImpedanceEvent>? _frameSub;

  /// 日志输出（默认 null 即静默）
  void Function(String)? logger;

  // -------------------------------------------------------------------------
  // 配置
  // -------------------------------------------------------------------------

  /// 计算参数（默认已按 150 kΩ 日志标定）
  ImpedanceCalcConfig get config => _config;

  set config(ImpedanceCalcConfig value) {
    if (_config == value) return;
    _config = value;
    reset();
  }

  /// 滑动步长（采样点数）
  ///
  /// 0 或负值 = 非重叠（算完清空，默认）。
  /// 设成小于 [ImpedanceCalcConfig.windowSamples] 可重叠滑窗，更新更密但更耗 CPU。
  int get hopSamples => _hopSamples > 0 ? _hopSamples : _config.windowSamples;

  set hopSamples(int value) => _hopSamples = value < 0 ? 0 : value;

  /// 是否在接收数据（false 时 [feed] 直接丢弃）
  bool get running => _running;

  /// 最近一次测量结果
  ImpedanceResult? get latest => _latest;

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  /// 挂载到全局事件总线：自动消费 `EegImpedanceEvent`（0x8C 帧）
  ///
  /// 幂等，重复调用无副作用。与 [detach] 配对。
  void attach() {
    if (_attached) return;
    _frameSub = EventBusManager.i.on<EegImpedanceEvent>().listen(
      _onFrame,
      cancelOnError: false,
    );
    _attached = true;
    _log('已挂载，窗口 ${_config.windowSamples} 点 @ ${_config.sampleRateHz}Hz');
  }

  /// 取消挂载
  Future<void> detach() async {
    await _frameSub?.cancel();
    _frameSub = null;
    _attached = false;
  }

  /// 暂停接收
  void pause() => _running = false;

  /// 恢复接收（会先清空缓冲，避免拼接上暂停前的旧数据）
  void resume() {
    reset();
    _running = true;
  }

  /// 清空缓冲与最近结果
  void reset() {
    _buffer.clear();
    _channelNumbers = const <int>[];
    _latest = null;
    _seq = 0;
  }

  void _onFrame(EegImpedanceEvent event) => feedImpedanceFrame(event.frame);

  // -------------------------------------------------------------------------
  // 数据输入
  // -------------------------------------------------------------------------

  /// 喂一帧 0x8C 阻抗**结果**（v1.0.9 起的主要路径）
  ///
  /// 设备已算好各通道 kΩ（定标 ×10），这里只做合格判定与事件广播，
  /// 不再做频谱计算（[feedSamples] 那条路径保留给旧固件 / 离线日志）。
  void feedImpedanceFrame(EegImpedanceFrame frame) {
    if (!_running) return;

    final max = quality?.impStandardKohm?.toDouble();
    final results = <ImpedanceChannelResult>[
      for (var i = 0; i < frame.rawValues.length; i++)
        ImpedanceChannelResult(
          channel: i + 1,
          // 设备直算结果：无原始幅值 / 电压，填 0
          amplitudeLsb: 0,
          voltMicrovolts: 0,
          kohm: frame.rawValues[i] / 10.0,
          isPass: max == null ? true : frame.rawValues[i] / 10.0 <= max,
        ),
    ];

    _seq++;
    final result = ImpedanceResult(
      time: DateTime.now(),
      channels: List<ImpedanceChannelResult>.unmodifiable(results),
      config: _config,
      quality: quality,
      seq: _seq,
    );
    _latest = result;
    _emit(result);
    _log('$result');
  }

  /// 喂一帧 0x90 阻抗**原始采样**（旧协议 ≤ v1.0.8；离线日志回放也走这里）
  ///
  /// 帧内 `channels` 是 `channels[通道序][采样点]`，
  /// 物理通道号由 `channelMask` 的置位顺序推出。
  void feed(EegDataFrame frame) {
    if (!_running) return;
    if (!frame.isImpedance) return;
    feedSamples(frame.channels, channelMask: frame.channelMask);
  }

  /// 直接喂采样数据：`channels[通道序][采样点]`
  ///
  /// - [channelMask]：置位顺序即物理通道号；为 null 时按 1..n 顺序编号。
  /// - [flush]：是否立刻尝试出结果（默认 true）。
  void feedSamples(
    List<List<int>> channels, {
    int? channelMask,
    bool flush = true,
  }) {
    if (!_running || channels.isEmpty) return;

    final numbers = _resolveChannelNumbers(channels.length, channelMask);
    if (_channelNumbers.isEmpty) {
      _channelNumbers = numbers;
      _buffer.clear();
    } else if (!_sameChannels(_channelNumbers, numbers)) {
      // 通道布局变了，旧数据作废
      _log('通道布局变化 $_channelNumbers → $numbers，重置缓冲');
      reset();
      _channelNumbers = numbers;
    }

    final sampleCount = channels.first.length;
    for (var c = 0; c < channels.length; c++) {
      final sink = _buffer.putIfAbsent(numbers[c], () => <int>[]);
      sink.addAll(channels[c]);
    }

    if (flush) _tryEvaluate(sampleCount);
  }

  void _tryEvaluate(int added) {
    final need = _config.windowSamples;
    if (need < 8) return;

    for (final n in _channelNumbers) {
      if ((_buffer[n]?.length ?? 0) < need) return;
    }

    final result = _compute();
    if (result == null) return;

    // 滑窗推进：丢弃已消费的采样
    final hop = math.min(hopSamples, need);
    for (final n in _channelNumbers) {
      final buf = _buffer[n];
      if (buf == null) continue;
      final drop = math.min(hop, buf.length);
      if (drop >= buf.length) {
        buf.clear();
      } else {
        buf.removeRange(0, drop);
      }
    }

    _latest = result;
    _emit(result);
    _log('$result');
  }

  ImpedanceResult? _compute() {
    final need = _config.windowSamples;
    final results = <ImpedanceChannelResult>[];

    for (final n in _channelNumbers) {
      final buf = _buffer[n];
      if (buf == null || buf.length < need) return null;

      // 取**最近**的 need 个点（PDF：获取最近 2 秒数据）
      final window = buf.sublist(buf.length - need);
      final amp = ImpedanceSpectrum.amplitude(window, _config);
      final kohm = _config.kohmFromAmplitude(amp);
      final max = quality?.impStandardKohm;

      results.add(
        ImpedanceChannelResult(
          channel: n,
          amplitudeLsb: amp,
          voltMicrovolts: amp * _config.microVoltsPerLsb,
          kohm: kohm,
          isPass: max == null ? true : kohm <= max,
        ),
      );
    }

    _seq++;
    return ImpedanceResult(
      time: DateTime.now(),
      channels: List<ImpedanceChannelResult>.unmodifiable(results),
      config: _config,
      quality: quality,
      seq: _seq,
    );
  }

  void _emit(ImpedanceResult result) {
    EventBusManager.i.fire(EegImpedanceResultEvent(result: result));
    if (!result.hasRule) return;
    if (result.isPass) {
      EventBusManager.i.fire(EegImpedancePassEvent(result: result));
    } else {
      EventBusManager.i.fire(EegImpedanceFailEvent(result: result));
    }
  }

  // -------------------------------------------------------------------------
  // 工具
  // -------------------------------------------------------------------------

  /// 由 ChannelMask 的置位顺序推出物理通道号（1 起始）
  static List<int> _resolveChannelNumbers(int count, int? mask) {
    if (mask == null || mask == 0) {
      return List<int>.generate(count, (i) => i + 1, growable: false);
    }
    final out = <int>[];
    for (var bit = 0; bit < 32 && out.length < count; bit++) {
      if ((mask >> bit) & 0x01 == 1) out.add(bit + 1);
    }
    // 掩码位数不足时按自然序补齐
    for (var i = out.length; i < count; i++) {
      out.add((out.isEmpty ? 0 : out.last) + 1);
    }
    return List<int>.unmodifiable(out);
  }

  static bool _sameChannels(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _log(String message) => logger?.call('[Impedance] $message');
}
