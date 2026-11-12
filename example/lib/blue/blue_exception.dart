/// BLE 领域异常
enum BlueExceptionType {
  /// 设备不支持 BLE
  unsupported,

  /// 权限未授权
  unauthorized,

  /// 蓝牙未开启
  adapterOff,

  /// 操作过于频繁（上一次操作尚未结束）
  busy,

  /// 扫描失败
  scan,

  /// 连接失败
  connect,

  /// 发现服务失败
  discover,

  /// 订阅推送失败
  notify,

  /// 写入失败
  write,

  /// 读取失败
  read,

  /// 断开失败
  disconnect,

  /// 超时
  timeout,

  /// 其他
  unknown,
}

/// core/blue 统一异常
///
/// 所有蓝牙操作失败都会抛该异常，业务层只需 `on BlueException` 即可：
///
/// ```dart
/// try {
///   await BlueManager.i.startScan();
/// } on BlueException catch (e) {
///   debugPrint(e.message);
/// }
/// ```
class BlueException implements Exception {
  const BlueException({
    required this.type,
    required this.message,
    this.error,
    this.stackTrace,
    this.gattCode,
  });

  /// 异常类型
  final BlueExceptionType type;

  /// 可直接展示给用户的描述
  final String message;

  /// 底层原始异常
  final Object? error;

  /// 原始堆栈
  final StackTrace? stackTrace;

  /// GATT 层错误码（ATT Error Code）
  ///
  /// * `0x80` ~ `0x9F`：应用层自定义错误，本项目门禁拒绝固定用 `0x8F`；
  /// * 其余为标准 ATT 错误码；
  /// * 非 GATT 错误（如插件内部异常、超时）为 null。
  ///
  /// 只有 `read` / `write` / `setNotifyValue` 这类真正走 ATT 的操作才有值。
  final int? gattCode;

  /// 是否因硬件不支持
  bool get isUnsupported => type == BlueExceptionType.unsupported;

  /// 是否因权限未授权
  bool get isUnauthorized => type == BlueExceptionType.unauthorized;

  /// 是否因蓝牙未开启
  bool get isAdapterOff => type == BlueExceptionType.adapterOff;

  @override
  String toString() =>
      'BlueException(${type.name}): $message${error == null ? '' : ' | $error'}'
      '${gattCode == null ? '' : ' | gatt 0x${gattCode!.toRadixString(16)}'}';
}
