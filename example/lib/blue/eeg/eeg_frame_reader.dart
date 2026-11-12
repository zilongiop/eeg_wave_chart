/// 一帧 0x8B 原始采样值 → µV 的读取器
///
/// 首页卡片只要 CH8 一个通道，Live EEG 页要 8 个通道，两处都要做同一件事：
/// 「选通道 → 逐点按标定系数换算 → 顺手记下原始 LSB 极值（对账用）」。
/// 这类重复实现迟早会漂（之前换算系数就抄出过三个不同的值），所以收成一处。
///
/// 控制器拿到的是**物理量（µV）**，往后的滤波 / 去直流 / 缓冲 / 量程都在
/// `EegWaveformChart` 里完成 —— 本文件只负责「数据是什么」，不管「怎么显示」。
library;

import 'dart:typed_data';

import 'eeg_data_frame.dart';
import 'eeg_scale.dart';

/// 单个通道一帧的换算结果
class EegMicroVoltChunk {
  const EegMicroVoltChunk({
    required this.values,
    required this.rawMinLsb,
    required this.rawMaxLsb,
  });

  /// 空结果（通道越界 / 该通道没有采样点时返回）
  static final EegMicroVoltChunk empty = EegMicroVoltChunk(
    values: Float64List(0),
    rawMinLsb: 0,
    rawMaxLsb: 0,
  );

  /// 换算后的 µV 序列
  ///
  /// 用 [Float64List] 而非 `List<double>`：连续内存、元素不装箱，
  /// 每帧都要新建一条，省下的分配和 GC 是实打实的。
  final Float64List values;

  /// 本帧该通道的原始 LSB 最小值（**未**换算、未滤波，用于对账）
  final int rawMinLsb;

  /// 本帧该通道的原始 LSB 最大值
  final int rawMaxLsb;

  /// 没有任何采样点
  bool get isEmpty => values.isEmpty;
  bool get isNotEmpty => values.isNotEmpty;

  int get length => values.length;
}

/// 给 [EegDataFrame] 加的换算入口
extension EegFrameReader on EegDataFrame {
  /// 取第 [index] 个通道（0 基）并换算成 µV
  ///
  /// 越界、通道为空时返回 [EegMicroVoltChunk.empty]，调用方不用自己判下标的
  /// 边界（首页原来那句 `index >= frame.channels.length` 就属于这类样板）。
  EegMicroVoltChunk microVoltChannel(int index) {
    if (index < 0 || index >= channels.length) {
      return EegMicroVoltChunk.empty;
    }
    final src = channels[index];
    if (src.isEmpty) return EegMicroVoltChunk.empty;

    final values = Float64List(src.length);
    var min = src[0];
    var max = src[0];
    for (var i = 0; i < src.length; i++) {
      final lsb = src[i];
      if (lsb < min) min = lsb;
      if (lsb > max) max = lsb;
      // 换算走 [eegMicroVoltsFromLsb]：与嵌入式 `eeg_16_data_compute()` 逐位一致
      values[i] = eegMicroVoltsFromLsb(lsb);
    }
    return EegMicroVoltChunk(
      values: values,
      rawMinLsb: min,
      rawMaxLsb: max,
    );
  }

  /// 取前 [count] 个通道并换算（[count] 为 null 或超过实际通道数时取全部）
  List<EegMicroVoltChunk> microVoltChannels({int? count}) {
    final total = channels.length;
    final n = count == null || count > total ? total : count;
    return <EegMicroVoltChunk>[
      for (var c = 0; c < n; c++) microVoltChannel(c),
    ];
  }
}
