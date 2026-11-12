import 'blue_device.dart';

/// 广播包数据
class BlueAdvertisement {
  const BlueAdvertisement({
    this.advName = '',
    this.serviceUuids = const <String>[],
    this.serviceData = const <String, List<int>>{},
    this.manufacturerData = const <int, List<int>>{},
    this.txPowerLevel,
    this.connectable = true,
  });

  /// 广播中的设备名称（可能为空）
  final String advName;

  /// 广播中声明的服务 UUID 列表
  final List<String> serviceUuids;

  /// 服务数据，key 为服务 UUID
  final Map<String, List<int>> serviceData;

  /// 厂商数据，key 为厂商 ID
  final Map<int, List<int>> manufacturerData;

  /// 发射功率（部分设备不广播）
  final int? txPowerLevel;

  /// 是否可连接
  final bool connectable;
}

/// 一条扫描结果
class BlueScanResult {
  const BlueScanResult({
    required this.device,
    required this.name,
    required this.rssi,
    required this.advertisement,
    required this.timeStamp,
  });

  /// 扫描到的设备
  final BlueDevice device;

  /// 展示用名称：优先广播名，其次平台名，兜底「未知设备」
  final String name;

  /// 信号强度（dBm，越大越好）
  final int rssi;

  /// 广播包
  final BlueAdvertisement advertisement;

  /// 收到该广播的时间
  final DateTime timeStamp;

  /// 设备标识，等价于 `device.id`
  String get id => device.id;
}
