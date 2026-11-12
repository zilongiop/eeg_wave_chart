import 'dart:convert';

/// 小狗状态标签（《业务流程 v1.0.13》第 6.1 节）
///
/// 设备端上传 code，APP 端按下表映射。EEG+IMU 帧（7.2）的 LabelCode 与
/// label 上报（0xAF）的 code 共用这张表。
enum DogState {
  /// 0x00 其它
  other(0x00, 'other', '其他'),

  /// 0x02 行走
  walk(0x02, 'walk', '行走'),

  /// 0x03 躺卧（睡觉）
  lying(0x03, 'lying', '躺卧'),

  /// 0x04 奔跑
  run(0x04, 'run', '奔跑'),

  /// 0x06 坐
  sit(0x06, 'sit', '坐立');

  const DogState(this.code, this.label, this.zhName);

  /// 设备上报的 code
  final int code;

  /// 标签名（与文档 label 字段一致）
  final String label;

  /// 中文名（界面展示用）
  final String zhName;

  /// 按 code 精确匹配；未登记的 code 返回 null
  ///
  /// 与 [fromCode] 的区别：0x00 是**真的「其他」**，而未登记的 code（例如
  /// 固件新增但协议表还没同步的状态）应该显式暴露出来，不能悄悄算成「其他」。
  static DogState? tryFromCode(int? code) {
    if (code == null) return null;
    for (final state in values) {
      if (state.code == code) return state;
    }
    return null;
  }

  /// 按 code 映射；未知 code 与 0xFF（未就绪）都归为 [other]
  static DogState fromCode(int? code) => tryFromCode(code) ?? other;
}

/// 脑电 + IMU 配置（`eeg_imu_config`）
///
/// 上行时设备会额外带 [eleQuantity]（电池电量）。
class EegImuConfig {
  const EegImuConfig({this.eegHz, this.imuHz, this.duration, this.eleQuantity});

  /// 脑电采样率：250 / 500 / 1000 / 2000
  final int? eegHz;

  /// IMU 采样率：默认 120
  final int? imuHz;

  /// 采集持续时间，单位秒，0 = 无限制
  final int? duration;

  /// 电池电量百分比（仅设备上报）
  final int? eleQuantity;

  factory EegImuConfig.fromJson(Map<String, dynamic> json) => EegImuConfig(
    eegHz: _intOf(json['eeg_hz']),
    imuHz: _intOf(json['imu_hz']),
    duration: _intOf(json['duration']),
    eleQuantity: _intOf(json['EleQuantity']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (eegHz != null) 'eeg_hz': eegHz,
    if (imuHz != null) 'imu_hz': imuHz,
    if (duration != null) 'duration': duration,
    if (eleQuantity != null) 'EleQuantity': eleQuantity,
  };

  EegImuConfig copyWith({int? eegHz, int? imuHz, int? duration}) =>
      EegImuConfig(
        eegHz: eegHz ?? this.eegHz,
        imuHz: imuHz ?? this.imuHz,
        duration: duration ?? this.duration,
        eleQuantity: eleQuantity,
      );

  /// 采样率文案，如 `250Hz / 120Hz`
  String get rateText {
    final eeg = eegHz == null ? '—' : '${eegHz}Hz';
    final imu = imuHz == null ? '—' : '${imuHz}Hz';
    return '$eeg / $imu';
  }

  @override
  String toString() => 'EegImuConfig($rateText, duration: $duration)';
}

/// 阻抗配置（`imp_config`，CMD 0x22）
///
/// v1.0.13 起字段名改为 `start` / `duration_s`（旧版为 `sample_hz` / `duration`）。
class ImpConfig {
  const ImpConfig({this.start, this.durationS});

  /// 是否进行阻抗检测：0 = 不检测（此时设备忽略 [durationS]），1 = 开始
  final int? start;

  /// 检测持续时间，单位秒
  final int? durationS;

  factory ImpConfig.fromJson(Map<String, dynamic> json) => ImpConfig(
    start: _intOf(json['start']),
    // 旧版用 `duration`，兜底兼容过渡期固件
    durationS: _intOf(json['duration_s']) ?? _intOf(json['duration']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (start != null) 'start': start,
    if (durationS != null) 'duration_s': durationS,
  };

  @override
  String toString() => 'ImpConfig(start: $start, duration_s: $durationS)';
}

/// 阻抗通过标准（`imp_standard_config`，CMD 0x23）
///
/// v1.0.13 起字段名改为 `imp_standard_kohm` / `imp_standard_channel`
/// （旧版为 `impedance_max_kohm` / `channel`）。
class ImpedanceStandard {
  /// 全工程统一的阻抗合格上限：50 kΩ
  ///
  /// 单通道 kΩ ≤ 该值算达标。状态图着色、阻抗调试页默认值、
  /// CMD 0x23 下发配置都以此为准，避免各处硬编码出现不同口径。
  static const int defaultMaxKohm = 50;

  /// 全工程统一的要求达标通道数：8 通道中至少 5 个
  static const int defaultRequiredChannels = 5;

  const ImpedanceStandard({this.impStandardKohm, this.impStandardChannel});

  /// 默认合格标准（50 kΩ / 5 通道）
  const ImpedanceStandard.defaults()
    : impStandardKohm = defaultMaxKohm,
      impStandardChannel = defaultRequiredChannels;

  /// 阻抗阈值，单位 kΩ
  final int? impStandardKohm;

  /// 要求达标的有效通道数
  final int? impStandardChannel;

  factory ImpedanceStandard.fromJson(Map<String, dynamic> json) =>
      ImpedanceStandard(
        // 旧字段名 `impedance_max_kohm` / `channel` 兜底兼容
        impStandardKohm:
            _intOf(json['imp_standard_kohm']) ??
            _intOf(json['impedance_max_kohm']),
        impStandardChannel:
            _intOf(json['imp_standard_channel']) ?? _intOf(json['channel']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (impStandardKohm != null) 'imp_standard_kohm': impStandardKohm,
    if (impStandardChannel != null) 'imp_standard_channel': impStandardChannel,
  };

  @override
  String toString() =>
      'ImpedanceStandard($impStandardKohm kΩ, $impStandardChannel 通道)';
}

/// EEG+IMU 和阻抗测试（`action`，CMD 0x24）
///
/// 设备在这段总时长内：每隔 [impDurationS] 秒采一次阻抗，其余时间采 EEG+IMU。
class EegTestAction {
  const EegTestAction({this.impDurationS, this.durationS});

  /// 阻抗采集周期，单位秒
  final int? impDurationS;

  /// 总时长，单位秒
  final int? durationS;

  factory EegTestAction.fromJson(Map<String, dynamic> json) => EegTestAction(
    impDurationS: _intOf(json['imp_duration_s']),
    durationS: _intOf(json['duration_s']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (impDurationS != null) 'imp_duration_s': impDurationS,
    if (durationS != null) 'duration_s': durationS,
  };

  @override
  String toString() => 'EegTestAction(阻抗每 ${impDurationS}s / 总 ${durationS}s)';
}

/// 采样率切换上报（`change_sample`，CMD 0xAB）
class EegChangeSample {
  const EegChangeSample({this.eegHz});

  /// 切换后的脑电采样率（IMU 恒为 120Hz，不随该字段变化）
  final int? eegHz;

  factory EegChangeSample.fromJson(Map<String, dynamic> json) =>
      EegChangeSample(eegHz: _intOf(json['eeg_hz']));

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (eegHz != null) 'eeg_hz': eegHz,
  };

  @override
  String toString() => 'EegChangeSample(${eegHz}Hz)';
}

/// 触发规则里的规则引用（`triggers[].profiles[]`）
class EegTriggerRef {
  const EegTriggerRef({required this.profile, this.priority});

  /// 规则名称，对应 [EegProfile.profile]
  final String profile;

  /// 优先级，越小越高
  final int? priority;

  factory EegTriggerRef.fromJson(Map<String, dynamic> json) => EegTriggerRef(
    profile: json['profile']?.toString() ?? '',
    priority: _intOf(json['priority']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'profile': profile,
    if (priority != null) 'priority': priority,
  };
}

/// 触发规则（`triggers[]`）：事件 → 规则组合
class EegTrigger {
  const EegTrigger({
    required this.event,
    this.profiles = const <EegTriggerRef>[],
  });

  /// 事件名：ble_force_switch_phone / ble_switch_gate /
  /// imu_state_active / imu_state_sleep
  final String event;

  /// 规则组合（按优先级排列）
  final List<EegTriggerRef> profiles;

  factory EegTrigger.fromJson(Map<String, dynamic> json) => EegTrigger(
    event: json['event']?.toString() ?? '',
    profiles: (json['profiles'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => EegTriggerRef.fromJson(e.cast<String, dynamic>()))
        .toList(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'event': event,
    'profiles': profiles.map((e) => e.toJson()).toList(),
  };
}

/// 规则配置（`profiles[]`）
class EegProfile {
  const EegProfile({
    required this.profile,
    this.eegHz,
    this.imuHz,
    this.duration,
    this.start,
    this.end,
    this.onSec,
    this.offSec,
    this.action,
  });

  /// 规则名：continuous / interval / low_power / high_power / windows / ble_switch
  final String profile;

  final int? eegHz;
  final int? imuHz;

  /// 持续时间，0 = 永久，单位秒
  final int? duration;

  /// 时间窗开始，如 `22:00`
  final String? start;

  /// 时间窗结束，如 `06:00`
  final String? end;

  /// 断点采集：采集时长，单位秒
  final int? onSec;

  /// 断点采集：停止时长，单位秒
  final int? offSec;

  /// 触发动作，如 `disconnect`
  final String? action;

  factory EegProfile.fromJson(Map<String, dynamic> json) => EegProfile(
    profile: json['profile']?.toString() ?? '',
    eegHz: _intOf(json['eeg_hz']),
    imuHz: _intOf(json['imu_hz']),
    duration: _intOf(json['duration']),
    start: json['start']?.toString(),
    end: json['end']?.toString(),
    onSec: _intOf(json['on_sec']),
    offSec: _intOf(json['off_sec']),
    action: json['action']?.toString(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'profile': profile,
    if (eegHz != null) 'eeg_hz': eegHz,
    if (imuHz != null) 'imu_hz': imuHz,
    if (duration != null) 'duration': duration,
    if (start != null) 'start': start,
    if (end != null) 'end': end,
    if (onSec != null) 'on_sec': onSec,
    if (offSec != null) 'off_sec': offSec,
    if (action != null) 'action': action,
  };
}

/// 完整配置（第 5 章顶层 JSON）
///
/// 下发时只序列化非空字段（设备支持"只携带部分字段"）；
/// `ts` 为下发时间戳（毫秒）。
class EegConfigPayload {
  const EegConfigPayload({
    this.eegImu,
    this.impConfig,
    this.impedanceStandard,
    this.triggers,
    this.profiles,
    this.ts,
    this.reset,
  });

  final EegImuConfig? eegImu;

  /// 阻抗配置（`imp_config`，CMD 0x22）
  final ImpConfig? impConfig;

  /// 阻抗通过标准（`imp_standard_config`，CMD 0x23）
  final ImpedanceStandard? impedanceStandard;

  /// ≤ v1.0.12 遗留；v1.0.13 起不再有独立命令字
  final List<EegTrigger>? triggers;
  final List<EegProfile>? profiles;

  /// 时间戳（毫秒）
  final int? ts;

  /// 重置标记：文档示例 `{"reset":"0"}`
  final String? reset;

  factory EegConfigPayload.fromJson(Map<String, dynamic> json) =>
      EegConfigPayload(
        eegImu: json['eeg_imu_config'] is Map
            ? EegImuConfig.fromJson(_map(json['eeg_imu_config']))
            : null,
        impConfig: json['imp_config'] is Map
            ? ImpConfig.fromJson(_map(json['imp_config']))
            : (json['impedance_config'] is Map
                  ? ImpConfig.fromJson(_map(json['impedance_config']))
                  : null),
        impedanceStandard: json['imp_standard_config'] is Map
            ? ImpedanceStandard.fromJson(_map(json['imp_standard_config']))
            : (json['impedance_quality'] is Map
                  ? ImpedanceStandard.fromJson(_map(json['impedance_quality']))
                  : null),
        triggers: _list(json['triggers'])
            ?.map((e) => EegTrigger.fromJson(_map(e)))
            .toList(),
        profiles: _list(json['profiles'])
            ?.map((e) => EegProfile.fromJson(_map(e)))
            .toList(),
        ts: _intOf(json['ts']),
        reset: json['reset']?.toString(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (eegImu != null) 'eeg_imu_config': eegImu!.toJson(),
    if (impConfig != null) 'imp_config': impConfig!.toJson(),
    if (impedanceStandard != null)
      'imp_standard_config': impedanceStandard!.toJson(),
    if (triggers != null) 'triggers': triggers!.map((e) => e.toJson()).toList(),
    if (profiles != null) 'profiles': profiles!.map((e) => e.toJson()).toList(),
    if (ts != null) 'ts': ts,
    if (reset != null) 'reset': reset,
  };

  /// 转成待下发的 ASCII JSON（不含结束符）
  String encodeJson() => jsonEncode(toJson());
}

/// 连接信息上报（`Timestamps`，CMD 0xAD）
class EegTimestamps {
  const EegTimestamps({required this.bootId, required this.timestampMs});

  /// 开机会话号，每次上电 +1
  final int bootId;

  /// 设备开机相对时间戳，单位 ms
  final int timestampMs;

  factory EegTimestamps.fromJson(Map<String, dynamic> json) => EegTimestamps(
    bootId: _intOf(json['BootID']) ?? 0,
    timestampMs: _intOf(json['Timestamp']) ?? 0,
  );

  @override
  String toString() => 'EegTimestamps(boot: $bootId, t: ${timestampMs}ms)';
}

/// 唯一标识上报（`DeviceId`，独立帧）
class EegDeviceIdentity {
  const EegDeviceIdentity({required this.id});

  /// 设备唯一标识
  final String id;

  factory EegDeviceIdentity.fromJson(Map<String, dynamic> json) =>
      EegDeviceIdentity(id: json['ID']?.toString() ?? '');

  @override
  String toString() => 'EegDeviceIdentity($id)';
}

/// 小狗状态标签上报（`label`，CMD 0xAF，周期 2s）
class EegLabelReport {
  const EegLabelReport({required this.code, required this.timestampMs});

  /// 状态 code，见 [DogState]
  final int code;

  /// 设备相对时间戳，单位 ms
  final int timestampMs;

  /// 映射后的状态
  DogState get state => DogState.fromCode(code);

  factory EegLabelReport.fromJson(Map<String, dynamic> json) => EegLabelReport(
    code: _intOf(json['code']) ?? 0,
    timestampMs: _intOf(json['Timestamp']) ?? 0,
  );

  @override
  String toString() => 'EegLabelReport(${state.label}, t: ${timestampMs}ms)';
}

int? _intOf(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

List<dynamic>? _list(dynamic value) => value is List ? value : null;

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};
