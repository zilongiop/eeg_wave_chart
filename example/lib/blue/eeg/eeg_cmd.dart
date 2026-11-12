/// 配置帧命令字（《业务流程 v1.0.13》第 7.3 节）
///
/// - APP→设备：0x21~0x24（0x25~0x2F 预留）
/// - 设备→APP：0xA1~0xA7 应答（= 对应命令 +0x80）；
///   0xA8 连接信息上报、0xA9 默认配置上报、0xAB 切换采样率上报，0xAC~0xAF 预留
/// - 0xAA 故意留空，避免与帧头 0xAA 混淆
///
/// ⚠️ v1.0.13 相对旧版的两处**破坏性**调整：
/// 1. 下行 0x24 由「触发规则」改为「EEG+IMU 和阻抗测试」（`action`）；
/// 2. 上行 0xA8/0xA9/0xAB 不再表示事件（事件改为在帧里带 `event` 字段），
///    分别改成连接信息上报 / 默认配置上报 / 切换采样率上报。
///    旧的含义保留在 [legacy*] 常量里，仅供老固件调试。
abstract final class EegCmd {
  // ---------------------------------------------------------------------------
  // APP → EEG
  // ---------------------------------------------------------------------------

  /// 脑电+IMU 配置下发：`{"eeg_imu_config":{"eeg_hz":2000,"imu_hz":120,"duration":5}}`
  static const int setEegImuConfig = 0x21;

  /// 阻抗配置下发：`{"imp_config":{"start":0,"duration_s":0}}`
  static const int setImpedanceConfig = 0x22;

  /// 阻抗通过标准下发：`{"imp_standard_config":{"imp_standard_kohm":50,"imp_standard_channel":5}}`
  static const int setImpedanceStandard = 0x23;

  /// EEG+IMU 和阻抗测试：`{"action":{"imp_duration_s":10,"duration_s":60}}`
  ///
  /// `imp_duration_s` = 阻抗采集周期（每隔这么久采一次阻抗，其余时间采 EEG+IMU）
  /// `duration_s` = 总时长
  static const int setTestAction = 0x24;

  /// 配置查询（DATA 为空 = 查询全部生效配置）
  static const int queryConfig = 0x27;

  /// 重置：`{"reset":"0"}`
  static const int reset = 0x28;

  // ---- ≤ v1.0.12 遗留：v1.0.13 起这些码位已预留，仅用于老固件调试 ----

  /// 遗留：触发规则下发（旧 0x24，与新 [setTestAction] 同码位）
  static const int legacySetTriggers = 0x24;

  /// 遗留：规则配置下发（0x25）
  static const int legacySetProfiles = 0x25;

  /// 遗留：整表配置下发（0x26）
  static const int legacySetFullConfig = 0x26;

  // ---------------------------------------------------------------------------
  // EEG → APP
  // ---------------------------------------------------------------------------

  /// 应答 = APP 命令 + 0x80（0x21 → 0xA1 …… 0x27 → 0xA7）
  static const int ackOffset = 0x80;

  /// 取某个 APP 命令对应的应答命令字
  static int ackOf(int cmd) => cmd + ackOffset;

  /// 0x21 应答：配置执行结果
  static const int ackEegImuConfig = 0xA1;

  /// 0x27 应答：携带全部生效配置 JSON
  static const int ackQueryConfig = 0xA7;

  /// 连接信息上报：`{"Timestamps":{"BootID":38,"Timestamp":60000}}`
  static const int reportTimestamps = 0xA8;

  /// 默认配置上报：`{"eeg_imu_config":{"eeg_hz":2000,"imu_hz":120,"EleQuantity":85}}`
  static const int reportDefaultConfig = 0xA9;

  /// 上报切换后的采样率：`{"change_sample":{"eeg_hz":250}}`（IMU 恒为 120Hz）
  static const int reportChangeSample = 0xAB;

  /// 遗留：小狗状态标签上报（旧 0xAF）。v1.0.13 起 0xAC~0xAF 预留，
  /// 状态标签以 7.2 数据帧的 LabelCode 为准。
  static const int legacyReportLabel = 0xAF;

  /// 是否为设备→APP 方向的命令
  static bool isFromDevice(int cmd) => cmd >= 0x80;

  /// 是否为应答帧（0xA1~0xA7）
  static bool isAck(int cmd) => cmd >= ackEegImuConfig && cmd <= ackQueryConfig;

  /// 命令字名称（日志用），未知返回十六进制
  static String nameOf(int cmd) => switch (cmd) {
    setEegImuConfig => 'SET_EEG_IMU_CONFIG',
    setImpedanceConfig => 'SET_IMPEDANCE_CONFIG',
    setImpedanceStandard => 'SET_IMPEDANCE_STANDARD',
    setTestAction => 'ACTION_TEST',
    queryConfig => 'QUERY_CONFIG',
    reset => 'RESET',
    ackEegImuConfig => 'ACK_EEG_IMU_CONFIG',
    0xA2 => 'ACK_IMPEDANCE_CONFIG',
    0xA3 => 'ACK_IMPEDANCE_STANDARD',
    0xA4 => 'ACK_ACTION_TEST',
    ackQueryConfig => 'ACK_QUERY_CONFIG',
    reportTimestamps => 'REPORT_TIMESTAMPS',
    reportDefaultConfig => 'REPORT_DEFAULT_CONFIG',
    reportChangeSample => 'REPORT_CHANGE_SAMPLE',
    legacyReportLabel => 'LEGACY_REPORT_LABEL',
    _ => 'CMD_0x${cmd.toRadixString(16).padLeft(2, '0').toUpperCase()}',
  };
}

/// 设备主动上报的事件类型（v1.0.13：事件名走 JSON 的 `event` 字段）
enum EegDeviceEventType {
  /// 蓝牙强制切换到手机（互动场景）
  bleForceSwitchPhone('ble_force_switch_phone', 0xA8),

  /// 蓝牙切换到设备网关（回家场景）
  bleSwitchGate('ble_switch_gate', 0xA9),

  /// IMU 活动状态
  imuStateActive('imu_state_active', 0xAB),

  /// IMU 睡眠状态
  imuStateSleep('imu_state_sleep', 0xAC);

  const EegDeviceEventType(this.event, this.legacyCmd);

  /// 上报时的事件名（`{"event":"imu_state_sleep"}`）
  final String event;

  /// ≤ v1.0.12 时的专用命令字（v1.0.13 起这些码位已改作他用途）
  final int legacyCmd;

  /// 按事件名匹配，未知返回 null
  static EegDeviceEventType? fromName(String? name) {
    if (name == null) return null;
    for (final type in values) {
      if (type.event == name) return type;
    }
    return null;
  }

  /// 按旧协议命令字匹配（仅在 DATA 里没有 `event` 字段时兜底）
  static EegDeviceEventType? fromLegacyCmd(int cmd) {
    for (final type in values) {
      if (type.legacyCmd == cmd) return type;
    }
    return null;
  }
}
