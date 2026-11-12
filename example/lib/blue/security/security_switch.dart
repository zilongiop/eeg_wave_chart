/// 蓝牙安全认证总开关（**策略层**）
///
/// 这里只管「要不要开认证」，`security/` 下其余文件管「怎么认证」。
/// 两者刻意分开：样机联调阶段设备固件还没实现第二层握手，
/// 直接打开会让所有连接都失败；量产前把开关打开即可，无需改业务代码。
///
/// ## 打开时机
///
/// 满足下面全部条件再打开：
/// 1. 设备固件已实现认证 6 步（证书 / 挑战响应 / Key Exchange / 凭据）；
/// 2. 已通过 [CompanyCa.configure] 写入产线 CA 公钥；
/// 3. 设备固件已实现 0x57 Device State 与 96B 凭据签发；
/// 4. 设备会对未认证访问返回 GATT 0x8F / 凭据失效返回 0x90。
///
/// ## 用法
///
/// ```dart
/// // main() 中，早于任何 BLE 连接
/// BlueSecurityGuard.enabled = true;
///
/// // 运行时也能切（例如「设置 → 开发者选项 → 蓝牙安全认证」）
/// BlueSecurityGuard.turnOff();
/// ```
///
/// ## 关闭时的行为
///
/// * `BlueManager.connect` 不再触发认证握手；
/// * GATT 0x8F 门禁错误**不再被拦截**，按普通读写失败处理；
/// * 已建立的会话密钥被丢弃，`securityState` 变为 [BlueSecurityState.disabled]。
abstract final class BlueSecurityGuard {
  static bool _enabled = false;
  static final List<void Function(bool)> _listeners = <void Function(bool)>[];

  /// 是否已启用安全认证
  ///
  /// ⚠️ 默认 **false**。打开前请确认固件侧已就绪，否则所有连接都会失败。
  static bool get enabled => _enabled;

  /// 打开 / 关闭安全认证
  static set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    // 复制一份，避免回调里增删导致 ConcurrentModificationError
    for (final listener in List<void Function(bool)>.of(_listeners)) {
      listener(value);
    }
  }

  /// 打开安全认证
  static void turnOn() => enabled = true;

  /// 关闭安全认证
  static void turnOff() => enabled = false;

  /// 注册开关变化监听（[BlueManager] 用它同步内部状态）
  static void addListener(void Function(bool enabled) listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  /// 移除监听
  static void removeListener(void Function(bool enabled) listener) {
    _listeners.remove(listener);
  }
}

/// 安全认证状态
///
/// 由 [BlueManager.securityState] 推送，UI 可据此显示
/// 「正在认证… / 设备未认证 / 认证失败」等提示。
enum BlueSecurityState {
  /// 开关关闭，不做任何认证
  disabled,

  /// 开关已打开，但尚未认证（未连接，或连接后等待认证）
  idle,

  /// 正在认证（第二层握手中）
  authenticating,

  /// 已认证，会话密钥可用
  authenticated,

  /// 认证失败（设备会被断开）
  failed;

  /// 是否已通过认证
  bool get isAuthenticated => this == BlueSecurityState.authenticated;

  /// 是否处于认证流程中（含进行中与失败）
  bool get isActive =>
      this == BlueSecurityState.authenticating ||
      this == BlueSecurityState.failed;
}
