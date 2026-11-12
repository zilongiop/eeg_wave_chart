/// 蓝牙低功耗（BLE）统一能力层
///
/// 目标：**业务代码只依赖本目录，不直接 import 任何蓝牙插件。**
/// 后期要替换 `flutter_blue_plus`，只需实现一个新的 [BlueDriver] 并在
/// [BlueManager.init] 时传入，上层无需改动。
///
/// ```dart
/// import 'package:eeg_wave_chart_example/blue/blue.dart' as ble;
///
/// // 1. 初始化（建议在 main() 中调用一次）
/// BlueManager.i.init();
///
/// // 2. 扫描
/// await BlueManager.i.startScan();
/// BlueManager.i.scanResults.listen((results) => debugPrint('${results.length} 个设备'));
///
/// // 3. 连接（自动发现服务并按 UUID 偏好订阅推送）
/// await BlueManager.i.connect(device, notifyUuids: ['0000ff01-...']);
///
/// // 4. 接收设备推送
/// BlueManager.i.notifications.listen((bytes) => debugPrint('收到 ${bytes.length} 字节'));
///
/// // 5. 写入
/// await BlueManager.i.write([0xAA, 0x01]);
/// ```
///
/// 目录说明：
/// * `blue_manager.dart`：单例门面，对外唯一入口
/// * `blue_driver.dart`：与插件对接的抽象契约（替换插件时只动这里）
/// * `blue_defs.dart` / `blue_device.dart` / `blue_gatt.dart` / `blue_scan_result.dart`：抽象模型
/// * `blue_device_filter.dart`：扫描结果过滤规则（只保留自家 EEG 设备）
/// * `src/flutter_blue_plus_driver.dart`：flutter_blue_plus 的默认实现
/// * `eeg/`：头戴 EEG 设备的业务协议层（5 大服务 UUID、帧编解码、事件分发）
/// * `security/`：蓝牙安全通信 v1.2（X.509 设备证书认证 + Auth Token / Auth Status 门禁；链路加密由 OS 负责）
library;

export 'blue_defs.dart';
export 'blue_device_filter.dart';
export 'eeg/eeg.dart';
export 'blue_device.dart';
export 'blue_driver.dart';
export 'blue_exception.dart';
export 'blue_gatt.dart';
export 'blue_manager.dart';
export 'blue_reconnect.dart';
export 'blue_scan_result.dart';
export 'blue_utils.dart';
export 'security/security.dart';
