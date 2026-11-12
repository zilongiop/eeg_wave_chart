import 'eeg_cmd.dart';
import 'eeg_config.dart';
import 'eeg_data_frame.dart';
import 'eeg_impedance.dart';

/// EEG 设备事件基类
///
/// 所有事件都带 [time]（APP 侧收到的时刻），并按类型投递到
/// [EventBusManager]（`common/event_bus_manager.dart`）。
///
/// ```dart
/// final sub = EventBusManager.i.on<EegDogStateEvent>().listen((e) {
///   debugPrint('小狗：${e.state.label}');
/// });
/// ```
abstract class EegEvent {
  EegEvent({DateTime? time}) : time = time ?? DateTime.now();

  /// 事件发生（APP 收到）的时刻
  final DateTime time;

  @override
  String toString() => '$runtimeType@${time.toIso8601String()}';
}

/// 连接状态变化
class EegConnectionEvent extends EegEvent {
  EegConnectionEvent({required this.connected, this.deviceId, DateTime? time})
    : super(time: time);

  /// 是否已连接
  final bool connected;

  /// 设备标识
  final String? deviceId;

  @override
  String toString() =>
      'EegConnectionEvent(${connected ? '已连接' : '已断开'}'
      '${deviceId == null ? '' : ' $deviceId'})';
}

/// 电量上报（来自数据帧 EleQuantity / 默认配置上报）
class EegBatteryEvent extends EegEvent {
  EegBatteryEvent({required this.level, DateTime? time}) : super(time: time);

  /// 电量百分比
  final int level;

  @override
  String toString() => 'EegBatteryEvent($level%)';
}

/// 时间锚点建立（CMD 0xA8：BootID + Timestamp）
class EegTimeAnchorEvent extends EegEvent {
  EegTimeAnchorEvent({required this.anchor, DateTime? time})
    : super(time: time);

  /// 锚点：设备相对时间 ↔ 真实时间的换算基准
  final EegTimeAnchor anchor;

  @override
  String toString() => 'EegTimeAnchorEvent($anchor)';
}

/// 设备唯一标识上报（DeviceId）
class EegDeviceIdEvent extends EegEvent {
  EegDeviceIdEvent({required this.id, DateTime? time}) : super(time: time);

  /// 设备唯一标识
  final String id;

  @override
  String toString() => 'EegDeviceIdEvent($id)';
}

/// 小狗状态标签上报（数据帧 LabelCode / 旧 CMD 0xAF，周期 2s）
class EegDogStateEvent extends EegEvent {
  EegDogStateEvent({
    required this.code,
    required this.timestampMs,
    this.absoluteTime,
    DateTime? time,
  }) : super(time: time);

  /// 原始 code
  final int code;

  /// 设备相对时间戳（ms）
  final int timestampMs;

  /// 换算后的绝对时间（尚未建立锚点时为 null）
  final DateTime? absoluteTime;

  /// 映射后的状态
  DogState get state => DogState.fromCode(code);

  @override
  String toString() => 'EegDogStateEvent(${state.label})';
}

/// 设备主动事件上报（v1.0.13 起走 `event` 字段；旧版为 0xA8 / 0xA9 / 0xAB / 0xAC）
class EegDeviceEventReport extends EegEvent {
  EegDeviceEventReport({required this.type, DateTime? time})
    : super(time: time);

  /// 事件类型
  final EegDeviceEventType type;

  @override
  String toString() => 'EegDeviceEventReport(${type.name})';
}

/// 配置上报（0xA9 默认配置，或数据帧 / 其它上报里带的 eeg_imu_config）
class EegConfigReportEvent extends EegEvent {
  EegConfigReportEvent({
    required this.config,
    this.isDefault = false,
    this.raw = const <String, dynamic>{},
    DateTime? time,
  }) : super(time: time);

  /// 脑电+IMU 配置（含电量）
  final EegImuConfig config;

  /// 是否为出厂默认配置（0xAE）
  final bool isDefault;

  /// 原始 JSON，便于透传日志
  final Map<String, dynamic> raw;

  @override
  String toString() =>
      'EegConfigReportEvent(${config.rateText}${isDefault ? ', 默认' : ''})';
}

/// 全量配置快照（0xA7 应答 / Config State 读取）
class EegConfigSnapshotEvent extends EegEvent {
  EegConfigSnapshotEvent({required this.config, DateTime? time})
    : super(time: time);

  /// 生效配置
  final EegConfigPayload config;

  @override
  String toString() => 'EegConfigSnapshotEvent(${config.eegImu?.rateText})';
}

/// 命令应答（0xA1~0xA7）
class EegCommandResultEvent extends EegEvent {
  EegCommandResultEvent({
    required this.cmd,
    required this.result,
    this.raw = const <String, dynamic>{},
    DateTime? time,
  }) : super(time: time);

  /// 应答命令字（= 下发命令 + 0x80）
  final int cmd;

  /// 结果码，0 = 成功
  final int result;

  /// 原始 JSON
  final Map<String, dynamic> raw;

  /// 是否成功
  bool get isOk => result == 0;

  @override
  String toString() =>
      'EegCommandResultEvent(${EegCmd.nameOf(cmd)}, result: $result)';
}

/// 采样率切换上报（CMD 0xAB：`{"change_sample":{"eeg_hz":250}}`）
class EegChangeSampleEvent extends EegEvent {
  EegChangeSampleEvent({required this.eegHz, DateTime? time})
    : super(time: time);

  /// 切换后的脑电采样率（IMU 恒为 120Hz）
  final int? eegHz;

  @override
  String toString() => 'EegChangeSampleEvent(${eegHz ?? '-'}Hz)';
}

/// EEG+IMU 数据帧（Sensor Data，CMD 0x8B）
class EegSamplesEvent extends EegEvent {
  EegSamplesEvent({required this.frame, DateTime? time}) : super(time: time);

  /// 解析后的数据帧
  final EegDataFrame frame;

  @override
  String toString() => 'EegSamplesEvent($frame)';
}

/// 阻抗结果帧（Sensor Data，CMD 0x8C）
///
/// v1.0.9 起设备直接下发 8 通道 kΩ 结果（定标 ×10），APP 不再做频谱计算。
class EegImpedanceEvent extends EegEvent {
  EegImpedanceEvent({required this.frame, DateTime? time}) : super(time: time);

  /// 解析后的阻抗结果帧（各通道 kΩ + 电量）
  final EegImpedanceFrame frame;

  @override
  String toString() => 'EegImpedanceEvent($frame)';
}

/// 阻抗测量完成（每攒满一个窗口算完就发一次）
///
/// 由 [EegImpedanceManager] 发出，含全通道 kΩ。
/// 未配置合格标准时**只会**发这个事件。
class EegImpedanceResultEvent extends EegEvent {
  EegImpedanceResultEvent({required this.result, DateTime? time})
    : super(time: time);

  /// 本次测量结果
  final ImpedanceResult result;

  @override
  String toString() => 'EegImpedanceResultEvent($result)';
}

/// 阻抗不合格（订阅方在此响应：提示调整电极 / 暂停采集 …）
///
/// 只有在 `EegImpedanceManager.i.quality` 配了 [ImpedanceQuality]
/// 且达标通道数不足时才会发。
class EegImpedanceFailEvent extends EegEvent {
  EegImpedanceFailEvent({required this.result, DateTime? time})
    : super(time: time);

  /// 本次测量结果（[ImpedanceResult.isPass] 必为 false）
  final ImpedanceResult result;

  /// 未达标的通道
  List<ImpedanceChannelResult> get failedChannels => result.failedChannels;

  @override
  String toString() =>
      'EegImpedanceFailEvent(${result.passedCount}/${result.requiredChannels}'
      ' 达标，未达标通道 ${failedChannels.map((c) => 'ch${c.channel}').join(',')})';
}

/// 阻抗合格（达标通道数满足要求）
class EegImpedancePassEvent extends EegEvent {
  EegImpedancePassEvent({required this.result, DateTime? time})
    : super(time: time);

  /// 本次测量结果（[ImpedanceResult.isPass] 必为 true）
  final ImpedanceResult result;

  @override
  String toString() =>
      'EegImpedancePassEvent(${result.passedCount}/${result.requiredChannels} 达标)';
}

/// 设备错误记录（辅助服务 Error Record）
class EegErrorEvent extends EegEvent {
  EegErrorEvent({required this.raw, this.text, DateTime? time})
    : super(time: time);

  /// 原始字节
  final List<int> raw;

  /// 可打印时的文本
  final String? text;

  @override
  String toString() => 'EegErrorEvent(${text ?? '${raw.length}B'})';
}

/// 安全服务认证状态（Auth Status 通知）
class EegAuthStatusEvent extends EegEvent {
  EegAuthStatusEvent({required this.raw, this.text, DateTime? time})
    : super(time: time);

  /// 原始字节
  final List<int> raw;

  /// 可打印时的文本
  final String? text;

  @override
  String toString() => 'EegAuthStatusEvent(${text ?? '${raw.length}B'})';
}

/// OTA 事件通知
///
/// 只做通知转发，真正的升级流程走 `lib/ota`（`OtaManager` / `OtaBleTransport`）。
class EegOtaEventNotice extends EegEvent {
  EegOtaEventNotice({required this.raw, DateTime? time}) : super(time: time);

  /// OTA Event 特征收到的原始字节
  final List<int> raw;

  @override
  String toString() => 'EegOtaEventNotice(${raw.length}B)';
}

/// 原始推送（调试用，默认关闭：见 `EegDeviceService.debugRaw`）
class EegRawNotifyEvent extends EegEvent {
  EegRawNotifyEvent({required this.uuid, required this.bytes, DateTime? time})
    : super(time: time);

  /// 来源特征 UUID
  final String uuid;

  /// 原始字节
  final List<int> bytes;

  @override
  String toString() => 'EegRawNotifyEvent($uuid, ${bytes.length}B)';
}

/// 未知 / 无法归类的配置帧（日志排查用）
class EegUnknownFrameEvent extends EegEvent {
  EegUnknownFrameEvent({required this.cmd, required this.text, DateTime? time})
    : super(time: time);

  /// 命令字
  final int cmd;

  /// DATA 文本
  final String text;

  @override
  String toString() => 'EegUnknownFrameEvent(${EegCmd.nameOf(cmd)}, $text)';
}
