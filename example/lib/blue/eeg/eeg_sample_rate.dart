import 'package:flutter/foundation.dart';

/// 全局 EEG 采样率（Hz）
///
/// 调试页「采样率 0x21」按钮写这里，波形侧（首页 Live EEG 卡 / Live EEG 页）
/// 订阅它重建模拟源与滑动窗口，窗口点数 = 采样率 × 窗口时长：
///
/// ```dart
/// EegSampleRate.i.set(1000); // 250 / 500 / 1000 / 2000
/// ```
///
/// 真机数据不受它影响（设备推多快就收多快），它只决定模拟源的节奏和
/// 窗口能装多少点。
class EegSampleRate {
  EegSampleRate._();

  /// 单例
  static final EegSampleRate i = EegSampleRate._();

  /// 默认档位：设备 `eeg_imu_config` 默认就是 2000Hz
  static const double defaultHz = 2000;

  /// 可选档位，与设备 0x21 命令一致
  static const List<int> presets = <int>[250, 500, 1000, 2000];

  /// 当前采样率（Hz）。用 [ValueNotifier] 订阅，接口与原 `Rx<double>` 一致
  final ValueNotifier<double> hz = ValueNotifier<double>(defaultHz);

  /// 设置采样率
  void set(double value) => hz.value = value;
}
