/// EEG **显示链路**的数字滤波：高通（去直流 / 慢漂移）+ 工频陷波 + 低通
///
/// 与上位机参考实现（`senyue_manager._design_biquad` / `_BiquadState`）同参：
/// * 系数用 RBJ Audio EQ Cookbook 的双二阶（biquad），纯 Dart 实现、无依赖；
/// * 级联顺序 高通 → 陷波 → 低通，逐通道独立状态；
/// * **首样本预热**（[EegBiquad.prime]）：高通级直流增益为 0，从 0 起步；
///   低通 / 陷波级直流增益为 1，直接输出该直流电平 —— 避免开机时电极直流
///   偏置造成一个巨大的阶跃暂态（不预热的话前 1~2 秒波形会整屏冲顶）。
///
/// ⚠️ 只作用于**显示**：导出 / 频谱 / 阻抗仍然用未滤波的原始 µV
///（参考实现里也是 `raw_uv` 导出、`uv` 只给前端画波形）。
library;

import 'dart:math' as math;

/// 双二阶系数（已按 a0 归一化，可直接用于 Direct Form I）
class EegBiquadCoeff {
  const EegBiquadCoeff(this.b0, this.b1, this.b2, this.a1, this.a2);

  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;
}

/// 按 RBJ Audio EQ Cookbook 设计双二阶系数
///
/// [type]：`highpass` / `lowpass` / `notch`
EegBiquadCoeff eegDesignBiquad(String type, double freq, double rate, double q) {
  final w0 = 2 * math.pi * freq / rate;
  final cw = math.cos(w0);
  final sw = math.sin(w0);
  final alpha = sw / (2 * q);

  final a0 = 1 + alpha;
  final a1 = -2 * cw;
  final a2 = 1 - alpha;

  final double b0;
  final double b1;
  final double b2;
  switch (type) {
    case 'notch':
      b0 = 1;
      b1 = -2 * cw;
      b2 = 1;
      break;
    case 'highpass':
      b0 = (1 + cw) / 2;
      b1 = -(1 + cw);
      b2 = (1 + cw) / 2;
      break;
    default: // lowpass
      b0 = (1 - cw) / 2;
      b1 = 1 - cw;
      b2 = (1 - cw) / 2;
  }
  return EegBiquadCoeff(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
}

/// 单级双二阶滤波器的**运行态**（系数 + 历史 4 个状态）
class EegBiquad {
  EegBiquad(this.coeff, this.type);

  final EegBiquadCoeff coeff;

  /// `highpass` / `lowpass` / `notch`：只用于决定预热时的输出初值
  final String type;

  double _x1 = 0;
  double _x2 = 0;
  double _y1 = 0;
  double _y2 = 0;
  bool _primed = false;

  double process(double x) {
    ///蓝牙传输、ADC 换算偶尔会出现异常值（超量程、丢包），传给`process`之后浮点会变成 NaN，整个通道滤波器直接废掉，之后所有波形全是 NaN。,这里添加保护
    if (!x.isFinite) {
      return _y1;
    }
    if (!_primed) prime(x);
    final y = coeff.b0 * x + coeff.b1 * _x1 + coeff.b2 * _x2 - coeff.a1 * _y1 - coeff.a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  /// 用首个采样预热：消掉「从 0 突然跳到 mV 级直流」的开机阶跃
  ///
  /// 高通直流增益 = 0 → 输出从 0 开始；低通 / 陷波直流增益 = 1 → 直接输出该直流。
  void prime(double x0) {
    _x1 = x0;
    _x2 = x0;
    _y1 = type == 'highpass' ? 0 : x0;
    _y2 = _y1;
    _primed = true;
  }

  void reset() {
    _x1 = 0;
    _x2 = 0;
    _y1 = 0;
    _y2 = 0;
    _primed = false;
  }
}

/// 单通道的滤波级联（高通 → 陷波 → 低通）
class EegChannelFilter {
  EegChannelFilter(this._stages);

  final List<EegBiquad> _stages;

  double process(double x) {
    var v = x;
    for (final s in _stages) {
      v = s.process(v);
    }
    return v;
  }

  void reset() {
    for (final s in _stages) {
      s.reset();
    }
  }
}

/// 多通道显示滤波（每通道一条独立级联）
///
/// 用法：
/// ```dart
/// final f = EegDisplayFilter();
/// f.configure(sampleRateHz: 250, channels: 8);   // 采样率 / 通道数变化时调用
/// final uv = f.apply(ch, eegMicroVoltsFromLsb(lsb));
/// ```
class EegDisplayFilter {
  EegDisplayFilter({this.highpassHz = 0.5, this.notchHz = 50, this.lowpassHz = 60});

  /// 高通截止（Hz）：压掉电极直流偏置与呼吸 / 电极电位慢漂移
  final double highpassHz;

  /// 工频陷波（Hz）：国内 50 Hz（60 Hz 地区改这里）
  final double notchHz;

  /// 低通截止（Hz）：压掉肌电 / 高频噪声
  final double lowpassHz;

  double _rate = 0;
  int _channels = 0;
  List<EegChannelFilter> _chains = const <EegChannelFilter>[];

  /// 是否真的有滤波级（全被关掉 / 参数越界时为 false，此时 [apply] 直通）
  bool get enabled => _chains.isNotEmpty && _chains.first._stages.isNotEmpty;

  /// 按采样率 / 通道数（重新）构建级联
  ///
  /// 相同参数重复调用不会重建（也就不会清掉滤波器状态）。
  /// 频率超出 `rate/2` 的级会被跳过（与参考实现的 `freq >= rate/2` 判据一致）。
  void configure({required double sampleRateHz, required int channels}) {
    final fsChanged = (_rate != sampleRateHz);
    _rate = sampleRateHz;
    _channels = channels;
    _rebuild();
    // 采样率发生变化，清空所有滤波器历史，防止旧状态产生低频振荡包络
    if (fsChanged) {
      reset();
    }
  }

  void _rebuild() {
    final specs = <(String, double, double)>[];
    final nyquist = _rate / 2;
    // 双二阶滤波器，频率不能超过采样率0.4倍，留奈奎斯特裕度，避免时域振铃
    const double maxFraction = 0.4;
    final safeMaxF = _rate * maxFraction;
    if (highpassHz > 0 && highpassHz < nyquist && highpassHz <= safeMaxF) {
      specs.add(('highpass', highpassHz, 0.707));
    }
    if (notchHz > 0 && notchHz < nyquist && notchHz <= safeMaxF) {
      specs.add(('notch', notchHz, 30.0));
    }
    if (lowpassHz > 0 && lowpassHz < nyquist && lowpassHz <= safeMaxF) {
      specs.add(('lowpass', lowpassHz, 0.707));
    }

    final coeffs = <EegBiquadCoeff>[
      for (final s in specs) eegDesignBiquad(s.$1, s.$2, _rate, s.$3),
    ];

    // 每通道一套独立状态（不能共用，否则通道间会互相污染）
    _chains = <EegChannelFilter>[
      for (var c = 0; c < _channels; c++)
        EegChannelFilter(<EegBiquad>[
          for (var i = 0; i < specs.length; i++) EegBiquad(coeffs[i], specs[i].$1),
        ]),
    ];
  }

  /// 单通道滤波（µV 进、µV 出）；通道越界或未配置时原样返回
  double apply(int channel, double uv) {
    if (channel < 0 || channel >= _chains.length) return uv;
    return _chains[channel].process(uv);
  }

  /// 清零全部状态（切换数据源 / 重新开始采集时调用，避免跨会话暂态）
  void reset() {
    for (final c in _chains) {
      c.reset();
    }
  }
}
