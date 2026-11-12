/// 头戴 EEG 设备：GATT 服务 / 协议帧 / 数据模型 / 事件 / 业务服务
///
/// 依据《业务流程 v1.0.13》，按文档的 5 大类服务组织：
///
/// * `eeg_uuid.dart`：数据交互 / 感知 / 辅助 / OTA / 安全 5 大服务的 UUID
/// * `eeg_cmd.dart`：配置帧命令字（APP→设备 0x21~0x28，设备→APP 0xA1~0xAF）
/// * `eeg_frame.dart`：配置帧 `AA | CMD | DATA | XOR | 55` 编解码 + 流式解码
/// * `eeg_config.dart`：第 5/6 章 JSON 配置与上报模型（含小狗状态标签）
/// * `eeg_data_frame.dart`：第 7.1/7.2 节二进制帧（阻抗结果 0x8C / 脑电+IMU 0x8B）
/// * `eeg_impedance.dart`：阻抗（0x8C 设备直算结果 → 合格判定）、`EegImpedanceManager`
/// * `eeg_event.dart`：投到全局事件总线的事件类型
/// * `eeg_service.dart`：门面 `EegDeviceService`（绑定 / 订阅 / 下行 / 分发）
library;

export 'eeg_cmd.dart';
export 'eeg_config.dart';
export 'eeg_data_frame.dart';
export 'eeg_event.dart';
export 'eeg_filter.dart';
export 'eeg_frame.dart';
export 'eeg_frame_reader.dart';
export 'eeg_impedance.dart';
export 'eeg_sample_rate.dart';
export 'eeg_scale.dart';
export 'eeg_service.dart';
export 'eeg_uuid.dart';
