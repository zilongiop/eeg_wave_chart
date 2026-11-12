/// core/blue 的公共枚举
///
/// 这一层只描述 BLE 领域的通用概念，不依赖任何第三方插件，
/// 便于后期把 `flutter_blue_plus` 换成其他实现。

/// 本机蓝牙适配器状态
enum BlueAdapterState {
  /// 未知（尚未获取）
  unknown,

  /// 设备不支持 BLE
  unavailable,

  /// 权限未授权
  unauthorized,

  /// 正在开启
  turningOn,

  /// 已开启，可正常使用
  on,

  /// 正在关闭
  turningOff,

  /// 已关闭
  off;

  /// 蓝牙是否已开启
  bool get isOn => this == BlueAdapterState.on;

  /// 硬件可用（含正在开启的过渡态）
  bool get isUsable =>
      this == BlueAdapterState.on || this == BlueAdapterState.turningOn;
}

/// 与单个远端设备的连接状态
enum BlueConnectionState {
  /// 已断开
  disconnected,

  /// 已连接
  connected;

  /// 是否已连接
  bool get isConnected => this == BlueConnectionState.connected;
}

/// 授权类型
///
/// flutter_blue_plus 2.x 起，`connect()` 必须显式声明授权类型：
/// * [BlueLicense.nonprofit]：个人 / 非营利组织 / 教育机构，免费
/// * [BlueLicense.commercial]：商业或盈利性使用，需购买授权
///
/// 若本项目用于商业交付，请在 `BlueManager.init(license: ...)` 中切换。
enum BlueLicense {
  /// 非商业用途
  nonprofit,

  /// 商业用途
  commercial,
}
