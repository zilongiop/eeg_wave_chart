import 'dart:async';

/// GATT 特征属性
class BlueCharacteristicProperties {
  const BlueCharacteristicProperties({
    this.read = false,
    this.write = false,
    this.writeWithoutResponse = false,
    this.notify = false,
    this.indicate = false,
  });

  /// 可读
  final bool read;

  /// 可写（带响应）
  final bool write;

  /// 可写（无响应，吞吐更高）
  final bool writeWithoutResponse;

  /// 支持 notify
  final bool notify;

  /// 支持 indicate
  final bool indicate;

  /// 是否可订阅推送（notify 或 indicate）
  bool get canNotify => notify || indicate;

  /// 是否可写入
  bool get canWrite => write || writeWithoutResponse;
}

/// GATT 特征
abstract class BlueCharacteristic {
  /// 特征 UUID
  String get uuid;

  /// 所属服务 UUID
  String get serviceUuid;

  /// 特征属性
  BlueCharacteristicProperties get properties;

  /// 是否已开启推送
  bool get isNotifying;

  /// 设备推送的数据流（需先用 [setNotifyValue] 开启）
  Stream<List<int>> get onValueReceived;

  /// 开启 / 关闭推送
  Future<void> setNotifyValue(bool enable);

  /// 读取特征值
  Future<List<int>> read();

  /// 写入特征值
  ///
  /// - [withoutResponse]：是否使用 Write Without Response（更快但不保证送达）
  Future<void> write(List<int> value, {bool withoutResponse});
}

/// GATT 服务
class BlueService {
  const BlueService({
    required this.uuid,
    this.characteristics = const <BlueCharacteristic>[],
  });

  /// 服务 UUID
  final String uuid;

  /// 该服务下的特征
  final List<BlueCharacteristic> characteristics;
}
