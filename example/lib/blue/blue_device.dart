import 'dart:async';

import 'blue_defs.dart';
import 'blue_gatt.dart';

/// 远端 BLE 设备的抽象
///
/// 业务层只持有本类型，不接触具体插件的设备类。
abstract class BlueDevice {
  /// 设备标识（Android 为 MAC、iOS / macOS 为 UUID）
  String get id;

  /// 设备名称（平台缓存的名称，可能为空）
  String get name;

  /// 是否已连接
  bool get isConnected;

  /// 连接状态变化流（订阅后立即收到当前状态）
  Stream<BlueConnectionState> get connectionState;

  /// 连接设备
  ///
  /// - [timeout]：超时时间
  /// - [mtu]：期望的 MTU，连接后自动协商（部分平台生效）；
  ///   [autoConnect] 为 true 时**会被忽略**（两者互斥，见驱动实现注释）
  /// - [license]：授权类型，为空时由驱动决定
  /// - [autoConnect]：true 时本方法**立即返回**，只向系统登记一个「设备出现就
  ///   连」的后台请求，是否连上需监听 [connectionState]。仅 Android 有效。
  Future<void> connect({
    Duration? timeout,
    int? mtu,
    BlueLicense? license,
    bool autoConnect = false,
  });

  /// 断开连接
  Future<void> disconnect();

  /// 发现服务（含特征）
  Future<List<BlueService>> discoverServices();

  /// 当前 MTU 变化流
  Stream<int> get mtu;

  /// 服务被重置（设备侧 Service Changed / 0x2A05）
  ///
  /// 一旦触发，之前 [discoverServices] 拿到的 characteristic 实例全部作废，
  /// 旧通知订阅会**静默失效**（不报错、不抛异常，只是再也收不到数据）。
  Stream<void> get servicesReset;

  /// 请求修改 MTU，返回协商后的实际值（部分平台不支持会抛异常）
  Future<int> requestMtu(int desiredMtu);
}

/// 连接状态变化事件
///
/// 来自全局连接事件流 [BlueManager.connectionEvents]，可用于同步设备列表中的状态。
class BlueConnectionEvent {
  const BlueConnectionEvent({required this.device, required this.state});

  /// 状态发生变化的设备
  final BlueDevice device;

  /// 新的连接状态
  final BlueConnectionState state;

  /// 设备标识，等价于 `device.id`
  String get deviceId => device.id;

  @override
  String toString() => 'BlueConnectionEvent(${device.id}, ${state.name})';
}
