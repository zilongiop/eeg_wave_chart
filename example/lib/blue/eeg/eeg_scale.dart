/// EEG 采样值（24 位原始 LSB）↔ 电压（µV）的换算
///
/// 与嵌入式端 `eeg_16_data_compute()` **逐位一致**（Y 轴最大/最小电压就是由它
/// 算出来的），工程里所有「画波形」「读数值」的地方都走这里，不要再各自抄一个
/// 系数（首页 / Live EEG / BLE 帧解析页之前用了三个不同的值）。
library;

import 'dart:typed_data';

/// ADC 参考电压（V）
const double eegReferenceVolt = 4.5;

/// 前端增益（PGA）
const double eegGain = 6.0;

/// 24 位满量程码：固件用 `0x7FFFFF`（不是 `0x800000`），与 C 端实现保持一致
const double eegFullScaleCode = 0x7FFFFF;

/// 24 位补码的模（C 端取负幅度时用的 `16777216`）
const int eegCodeModulus = 0x01000000;

/// 符号位（bit23）
const int eegSignBit = 0x00800000;

/// LSB → µV 的换算系数 ≈ 0.089407 µV/LSB
///
/// 由 C 端公式化简而来：
/// ```
/// µV = ±|raw| × 4.5 / 0x7FFFFF × 1000 / 6 × 1000
///    = ±|raw| × 4.5e6 / (6 × 8388607)
/// ```
/// 满量程（0x7FFFFF）→ ±750000 µV = ±0.75 V（正好是 `Vref / Gain`）。
const double eegMicroVoltPerLsb =
    eegReferenceVolt * 1e6 / (eegGain * eegFullScaleCode);

/// 24 位有符号原始值 → µV
///
/// 严格照 C 端 `eeg_16_data_compute()` 写：
/// * 先 `& 0x00FFFFFF` 取 24 位；
/// * 符号位为 1 时幅度 = `16777216 − code`（24 位补码取模），结果为负；
/// * 否则幅度 = code，结果为正。
///
/// [raw] 允许是已带符号的整数（如帧解析出的 `-129`），也能是 24 位无符号码。
double eegMicroVoltsFromLsb(int raw) {
  final code = raw & 0x00FFFFFF;
  final negative = (code & eegSignBit) != 0;
  final magnitude = negative
      ? (eegCodeModulus - code).toDouble()
      : code.toDouble();

  // 4.5 / 0x7FFFFF * 1000 / 6 * 1000（保持 C 端的运算顺序）
  final microVolts =
      magnitude * eegReferenceVolt / eegFullScaleCode * 1000 / eegGain * 1000;

  return negative ? -microVolts : microVolts;
}

/// 整段原始值 → µV（[eegMicroVoltsFromLsb] 的批量版）
Float32List eegMicroVoltsFromLsbList(List<int> raw) {
  final out = Float32List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    out[i] = eegMicroVoltsFromLsb(raw[i]);
  }
  return out;
}

/// 一帧算完量程后的**对账快照**
///
/// 把「原始 LSB → µV → 去直流 → 抗尖峰 → Y 轴」这条链上的每个中间量都留
/// 一份，EEG Debug 页直接显示。跟嵌入式对数值时不用再翻代码或临时加日志：
/// 同一屏里能看到原始极值、去直流后的极值、分位范围和最终纵轴。
///
/// 由 `HomeController._updateYAxis` 每帧写入（Rx，页面 Obx 订阅）。
class EegScaleSnapshot {
  const EegScaleSnapshot({
    required this.rawMinLsb,
    required this.rawMaxLsb,
    required this.minMicroVolt,
    required this.maxMicroVolt,
    required this.robustLo,
    required this.robustHi,
    required this.axisLo,
    required this.axisHi,
    required this.clipped,
    required this.points,
    required this.sampleRateHz,
  });

  /// 窗口内原始采样值最小值（LSB，**未**换算、未滤波）
  final int rawMinLsb;

  /// 窗口内原始采样值最大值（LSB）
  final int rawMaxLsb;

  /// 去直流后的真实最小值（µV）
  final double minMicroVolt;

  /// 去直流后的真实最大值（µV）
  final double maxMicroVolt;

  /// 抗尖峰下限（3% 分位，µV）
  final double robustLo;

  /// 抗尖峰上限（97% 分位，µV）
  final double robustHi;

  /// 纵轴下限（µV，分位 + 余量 + niceSpan 之后）
  final double axisLo;

  /// 纵轴上限（µV）
  final double axisHi;

  /// 真实极值是否被纵轴裁掉（尖峰削顶）
  final bool clipped;

  /// 参与统计的点数
  final int points;

  /// 当前采样率（Hz）
  final int sampleRateHz;

  /// 原始极小值换算成 µV —— **含直流偏置**，即不做去直流的那套口径
  double get rawMinMicroVolt => eegMicroVoltsFromLsb(rawMinLsb);

  /// 原始极大值换算成 µV（含直流偏置）
  double get rawMaxMicroVolt => eegMicroVoltsFromLsb(rawMaxLsb);

  /// 原始极值的中点（µV）：不为 0 说明有直流偏置
  double get rawCenterMicroVolt => (rawMinMicroVolt + rawMaxMicroVolt) / 2;

  /// 原始极值的峰峰值（µV）
  double get rawSpanMicroVolt => rawMaxMicroVolt - rawMinMicroVolt;

  /// 去直流后的峰峰值（µV）
  double get spanMicroVolt => maxMicroVolt - minMicroVolt;

  /// 是否越出设备标称量程（±[deviceRangeMicroVolt] 的调用方自己传值，
  /// 这里只提供原始值，判定留给页面）
  bool isOverDeviceRange(double deviceRangeMicroVolt) =>
      minMicroVolt < -deviceRangeMicroVolt ||
      maxMicroVolt > deviceRangeMicroVolt;

  @override
  String toString() =>
      'EegScaleSnapshot(raw[$rawMinLsb ~ $rawMaxLsb] LSB → '
      '[${rawMinMicroVolt.toStringAsFixed(0)} ~ '
      '${rawMaxMicroVolt.toStringAsFixed(0)}] µV, 去直流'
      '[$minMicroVolt ~ $maxMicroVolt], 分位[$robustLo ~ $robustHi], '
      '轴[$axisLo ~ $axisHi]${clipped ? ' 削顶' : ''}, '
      '$points 点 @ $sampleRateHz Hz)';
}
