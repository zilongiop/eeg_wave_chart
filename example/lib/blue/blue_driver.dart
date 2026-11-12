import 'dart:async';

import 'blue_defs.dart';
import 'blue_device.dart';
import 'blue_scan_result.dart';

/// 底层蓝牙插件的日志级别
///
/// Android 端 `DEBUG` 级别会为每一条 notify 打印
/// `onCharacteristicChanged` + `chr: …`（EEG Sensor Data 高频推送时会刷屏）。
/// 默认用 [warning] 只保留警告与错误，排查底层收发时可临时切到 [debug]。
enum BlueLogLevel { none, error, warning, info, debug, verbose }

/// 蓝牙能力驱动：core/blue 与具体插件之间的**唯一契约**
///
/// 替换 `flutter_blue_plus` 时，只需按本接口实现一个新的驱动，
/// 然后在 `BlueManager.i.init(driver: MyDriver())` 中传入即可，
/// 上层业务代码零改动。
///
/// 参考实现见 `core/blue/src/flutter_blue_plus_driver.dart`。
abstract class BlueDriver {
  /// 驱动名称，用于日志
  String get name;

  /// 设备是否支持 BLE
  Future<bool> isSupported();

  /// 请求开启蓝牙（Android 有效，其他平台多为空实现）
  Future<void> turnOn();

  /// 本机蓝牙适配器状态流
  Stream<BlueAdapterState> get adapterState;

  /// 是否正在扫描的流
  Stream<bool> get isScanning;

  /// 扫描结果流：每次推送当前完整的设备列表
  Stream<List<BlueScanResult>> get scanResults;

  /// 全局连接状态变化流（任意设备）
  Stream<BlueConnectionEvent> get connectionEvents;

  /// 开始扫描
  ///
  /// - [timeout]：为空表示不自动停止
  /// - [serviceUuids]：只扫描广播中包含这些服务的设备，为空表示不限制
  /// - [continuousUpdates]：是否持续更新（Android 需为 true 才能实时刷新 RSSI）
  /// - [androidUsesFineLocation]：Android 是否使用精确定位权限
  Future<void> startScan({
    Duration? timeout,
    List<String>? serviceUuids,
    bool continuousUpdates = true,
    bool androidUsesFineLocation = false,
  });

  /// 停止扫描
  Future<void> stopScan();

  /// 由标识构造设备（用于恢复已连接设备、系统已配对设备）
  BlueDevice deviceFromId(String remoteId);

  /// 系统已连接的设备列表
  Future<List<BlueDevice>> systemDevices({List<String>? serviceUuids});

  /// 平台相关的全局配置，由 [BlueManager.configure] 调用一次
  ///
  /// - [restoreState]：iOS / macOS 是否开启 CoreBluetooth State Restoration
  ///   （对应 `CBCentralManagerOptionRestoreIdentifierKey`）。开启后，App 进程
  ///   被系统杀死再重启时，系统会保留并恢复之前的连接。
  ///   **必须在任何 BLE 操作之前设置** —— CBCentralManager 是首次操作时才
  ///   创建的，标识必须创建时就传入，晚了不生效。
  ///   标识由插件内部固定，调用方无法自定义。
  ///   Android / 桌面端没有对应机制，忽略即可。
  ///
  /// - [logLevel]：底层插件日志级别，默认 [BlueLogLevel.warning]
  ///   （关掉 Android DEBUG 级 notify 刷屏，保留警告与错误）
  ///
  /// 默认实现为空操作，新驱动按需覆盖。
  Future<void> configure({
    bool restoreState = false,
    BlueLogLevel logLevel = BlueLogLevel.warning,
  }) async {}

  /// 运行时调整底层插件日志级别
  ///
  /// 默认实现为空操作，新驱动按需覆盖。
  Future<void> setLogLevel(BlueLogLevel level) async {}
}
