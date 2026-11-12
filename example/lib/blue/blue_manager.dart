import 'dart:async';

import 'package:flutter/foundation.dart';

import '../extension/date_extension.dart' show DateExtension;
import 'blue_defs.dart';
import 'blue_device.dart';
import 'blue_driver.dart';
import 'blue_exception.dart';
import 'blue_gatt.dart';
import 'blue_reconnect.dart';
import 'blue_scan_result.dart';
import 'blue_utils.dart';
import 'eeg/eeg_data_frame.dart' show EegTimeAnchorHolder, peekEegFrameTime;
import 'security/device_authenticator.dart';
import 'security/security_defs.dart';
import 'security/security_error.dart';
import 'security/security_switch.dart';
import 'src/flutter_blue_plus_driver.dart';

/// 日志输出函数
typedef BlueLogWriter = void Function(String message);

/// BLE 统一管理入口（单例）
///
/// 业务层只依赖本类与 core/blue 下的抽象模型，**不直接 import 任何蓝牙插件**。
/// 需要更换底层实现时，只需提供新的 [BlueDriver]：
///
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   BlueManager.i.init();                     // 默认使用 flutter_blue_plus
///   // BlueManager.i.init(driver: MyDriver()); // 后期替换插件时改这一行
///   runApp(const MyApp());
/// }
/// ```
///
/// 典型流程：
///
/// ```dart
/// final blue = BlueManager.i;
///
/// await blue.startScan();
/// blue.scanResults.listen((results) => debugPrint('发现 ${results.length} 个设备'));
///
/// await blue.connect(device, notifyUuids: [BlueUuid.nusTx]);
/// blue.notifications.listen((bytes) => debugPrint(BlueHex.format(bytes)));
///
/// await blue.write([0xAA, 0x01]);
/// await blue.disconnect();
/// ```
class BlueManager {
  BlueManager._internal();

  static final BlueManager _instance = BlueManager._internal();

  /// 单例实例
  static BlueManager get instance => _instance;

  /// 单例简写：`BlueManager.i.startScan()`
  static BlueManager get i => _instance;

  /// 收到设备推送时是否打印日志（统一 `MYB` 前缀，方便 `flutter logs | grep MYB`）
  ///
  /// **默认关**：高采样率下推送很密集（2000Hz 时上百包/秒），每包都要走
  /// [BlueHex.format] 生成十六进制串再 `debugPrint`，这些活全在 UI isolate，
  /// 会直接挤占波形重算和绘制的时间。需要看原始包时在调试入口临时置 true。
  static bool notifyLogEnabled = false;

  /// 单包日志最多打印的字节数，超出部分以 `… (N 字节)` 结尾
  static int notifyLogBytes = 1000;

  // ---------------------------------------------------------------------------
  // 配置
  // ---------------------------------------------------------------------------

  /// 底层驱动，默认 flutter_blue_plus
  late BlueDriver _driver = FlutterBluePlusDriver();

  Duration _scanTimeout = const Duration(seconds: 15);
  Duration _connectTimeout = const Duration(seconds: 15);
  Duration _autoConnectWait = const Duration(seconds: 30);
  Duration _notifyDelay = const Duration(milliseconds: 100);
  /// 请求的最大 MTU：BLE ATT 协议上限 517（ATT_MTU = 512 载荷 + 5 字节头）。
  /// Android `requestMtu(517)` 会拿到控制器允许的最大值（常见 247 / 517）；
  /// iOS 忽略该请求、由系统自动协商。实际值永远以协商结果为准。
  int _mtu = 517;
  BlueLicense _license = BlueLicense.nonprofit;
  List<String> _notifyUuids = const <String>[BlueUuid.nusTx];
  List<String> _writeUuids = const <String>[BlueUuid.nusRx];
  bool _autoTurnOn = true;

  bool _initialized = false;
  bool _bound = false;
  bool _enableLog = true;
  BlueLogWriter _logWriter = debugPrint;

  // ---------------------------------------------------------------------------
  // 运行时状态
  // ---------------------------------------------------------------------------

  bool _busy = false;
  bool _notifyReady = false;
  BlueAdapterState _adapterState = BlueAdapterState.unknown;
  bool _scanning = false;
  BlueConnectionState _connectionState = BlueConnectionState.disconnected;

  /// 手动连接优先：置位期间自动回连不再发起新的连接尝试
  bool _manualPriority = false;

  /// 放弃挂起的 autoConnect 等待（手动连接抢占时置 true）
  bool _autoConnectAborted = false;

  /// 自动回连编排器（[enableAutoReconnect] 之后非空）
  BlueAutoReconnect? _reconnect;

  /// 是否处于 [disconnect] 流程中（用于区分主动断开与意外断线）
  bool _disconnecting = false;

  BlueDevice? _device;
  List<BlueService> _services = const <BlueService>[];
  DateTime? _servicesDiscoveredAt;
  BlueCharacteristic? _notifyCharacteristic;
  BlueCharacteristic? _writeCharacteristic;

  StreamSubscription<BlueConnectionState>? _connectionSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _deviceStateSub;
  final List<StreamSubscription<dynamic>> _driverSubs = <StreamSubscription<dynamic>>[];

  // 安全认证（证书 / 挑战响应 / 凭据 / 门禁）
  DeviceAuthenticator? _authenticator;
  String? _authenticatedDeviceId;
  BlueSecurityState _securityState = BlueSecurityState.disabled;
  bool _guardBound = false;

  final StreamController<BlueSecurityState> _securityStateCtrl =
      StreamController<BlueSecurityState>.broadcast();
  final StreamController<BlueAdapterState> _adapterStateCtrl =
      StreamController<BlueAdapterState>.broadcast();
  final StreamController<bool> _isScanningCtrl = StreamController<bool>.broadcast();
  final StreamController<List<BlueScanResult>> _scanResultsCtrl =
      StreamController<List<BlueScanResult>>.broadcast();
  final StreamController<BlueConnectionEvent> _connectionEventCtrl =
      StreamController<BlueConnectionEvent>.broadcast();
  final StreamController<BlueConnectionState> _connectionStateCtrl =
      StreamController<BlueConnectionState>.broadcast();
  final StreamController<List<int>> _notificationCtrl = StreamController<List<int>>.broadcast();
  final StreamController<BlueException> _errorCtrl = StreamController<BlueException>.broadcast();

  // ---------------------------------------------------------------------------
  // 状态 & 事件
  // ---------------------------------------------------------------------------

  /// 是否已完成初始化
  bool get isInitialized => _initialized;

  /// 当前使用的驱动
  BlueDriver get driver => _driver;

  /// 设备是否支持 BLE
  Future<bool> get isSupported async {
    _ensureInitialized();
    return _driver.isSupported();
  }

  /// 最近一次已知的适配器状态（同步读取，供 UI 首帧使用）
  BlueAdapterState get adapterStateNow => _adapterState;

  /// 最近一次已知的扫描状态（同步读取）
  bool get isScanningNow => _scanning;

  /// 当前连接的设备，未连接时为 null
  BlueDevice? get connectedDevice => _device;

  /// 已发现的服务（连接并 discover 之后有效）
  List<BlueService> get services => _services;

  /// 最近一次 `discoverServices` 完成时间（诊断特征实例是否中途作废）
  DateTime? get servicesDiscoveredAt => _servicesDiscoveredAt;

  /// 当前服务列表的实例标识；值变化说明重新发现过服务，
  /// 旧的 characteristic 实例与通知订阅随之失效
  int get servicesIdentity => identityHashCode(_services);

  /// 当前正在接收推送的特征
  BlueCharacteristic? get notifyCharacteristic => _notifyCharacteristic;

  /// 当前默认写入的特征
  BlueCharacteristic? get writeCharacteristic => _writeCharacteristic;

  /// 是否已开启推送
  bool get isNotifyEnabled => _notifyReady && _notifySub != null;

  /// 当前连接状态（同步读取）
  BlueConnectionState get connectionStateNow => _connectionState;

  /// 连接时请求的 MTU（init 配置值；实际协商值以设备为准）
  int get mtu => _mtu;

  /// 按 UUID 查找已发现的特征；未连接 / 未发现返回 null
  ///
  /// 设备提供多服务多特征时用它精确定位（例如 EEG 的 Config Command）：
  /// ```dart
  /// final c = BlueManager.i.characteristicOf(EegUuid.configCommand);
  /// await BlueManager.i.write(frame, characteristic: c);
  /// ```
  BlueCharacteristic? characteristicOf(String uuid) {
    final target = BlueUuid.normalize(uuid);
    for (final service in _services) {
      for (final c in service.characteristics) {
        if (BlueUuid.normalize(c.uuid) == target) return c;
      }
    }
    return null;
  }

  /// 是否已连接
  bool get isConnected => _device != null && _connectionState == BlueConnectionState.connected;

  /// 是否正在执行连接 / 断开等耗时操作
  bool get isBusy => _busy;

  /// 手动连接是否正在占用通道（[beginManualConnect] ~ [endManualConnect] 之间）
  bool get isManualPriority => _manualPriority;

  /// 适配器状态流
  Stream<BlueAdapterState> get adapterState => _adapterStateCtrl.stream;

  /// 扫描状态流
  Stream<bool> get isScanning => _isScanningCtrl.stream;

  /// 扫描结果流：每次推送当前完整的设备列表
  Stream<List<BlueScanResult>> get scanResults => _scanResultsCtrl.stream;

  /// 全局连接状态变化流（任意设备）
  Stream<BlueConnectionEvent> get connectionEvents => _connectionEventCtrl.stream;

  /// 当前设备的连接状态流
  Stream<BlueConnectionState> get connectionState => _connectionStateCtrl.stream;

  /// 设备推送的数据流（需先 [connect] 成功并订阅到可通知特征）
  Stream<List<int>> get notifications => _notificationCtrl.stream;

  /// 异步错误流（驱动层异常，不打断业务流程）
  Stream<BlueException> get errors => _errorCtrl.stream;

  // ---------------------------------------------------------------------------
  // 安全认证（第二层 + 第三层）
  // ---------------------------------------------------------------------------

  /// 安全认证状态流
  ///
  /// 由 `BlueSecurityGuard.enabled` 与认证过程共同驱动，UI 可据此显示
  /// 「正在认证… / 设备未认证 / 认证失败」提示。
  Stream<BlueSecurityState> get securityState => _securityStateCtrl.stream;

  /// 最近一次已知的安全认证状态（同步读取）
  BlueSecurityState get securityStateNow => _securityState;

  /// 是否已通过安全认证
  bool get isAuthenticated => _securityState.isAuthenticated;

  /// 本次连接认证通过的 Device ID，未认证时为 null
  String? get authenticatedDeviceId => _authenticatedDeviceId;

  /// 手动触发一次完整安全认证（跳过令牌免认证）
  ///
  /// 通常不需要调用：`connect()` 在开关打开时会自动执行。
  /// 需要「强制重新认证」（例如设备被重置、令牌失效）时用这个。
  ///
  /// 认证失败会抛 [BlueException]，且连接会被断开。
  Future<DeviceAuthResult> authenticate() async {
    _ensureInitialized();
    if (!BlueSecurityGuard.enabled) {
      throw const BlueException(
        type: BlueExceptionType.unknown,
        message: '安全认证开关未打开，请先设置 BlueSecurityGuard.enabled = true',
      );
    }
    if (!isConnected) {
      throw const BlueException(type: BlueExceptionType.connect, message: '未连接设备，无法进行安全认证');
    }
    final result = await _runSecurityHandshake(force: true);
    if (result == null) {
      throw const BlueException(
        type: BlueExceptionType.unknown,
        message: '安全认证未产出结果',
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 全局初始化，建议在 `main()` 中调用一次
  ///
  /// - [driver]：底层实现，默认 [FlutterBluePlusDriver]；替换插件时传入新的驱动
  /// - [scanTimeout]：默认扫描超时
  /// - [connectTimeout]：连接超时
  /// - [autoConnectWait]：`connect(autoConnect: true)` 时等待连上的窗口
  /// - [notifyDelay]：开启推送后到开始监听的间隔（部分 Android 设备写入 CCCD 后需要延时）
  /// - [mtu]：期望的 MTU
  /// - [license]：授权类型，商业交付请改为 [BlueLicense.commercial]
  /// - [notifyUuids] / [writeUuids]：连接后自动挑选推送 / 写入特征的 UUID 偏好
  /// - [autoTurnOn]：扫描前是否自动请求开启蓝牙（Android）
  /// - [securityEnabled]：是否启用安全认证；为空表示沿用全局开关
  ///   [BlueSecurityGuard.enabled]（推荐留空，用全局开关统一控制）
  BlueManager init({
    BlueDriver? driver,
    Duration scanTimeout = const Duration(seconds: 15),
    Duration connectTimeout = const Duration(seconds: 15),
    Duration autoConnectWait = const Duration(seconds: 30),
    Duration notifyDelay = const Duration(milliseconds: 100),
    int mtu = 517,
    BlueLicense license = BlueLicense.nonprofit,
    List<String>? notifyUuids,
    List<String>? writeUuids,
    bool autoTurnOn = true,
    bool enableLog = true,
    BlueLogWriter? logWriter,
    bool? securityEnabled,
  }) {
    if (securityEnabled != null) BlueSecurityGuard.enabled = securityEnabled;
    if (logWriter != null) _logWriter = logWriter;
    _enableLog = enableLog;
    _scanTimeout = scanTimeout;
    _connectTimeout = connectTimeout;
    _autoConnectWait = autoConnectWait;
    _notifyDelay = notifyDelay;
    _mtu = mtu;
    _license = license;
    _autoTurnOn = autoTurnOn;
    if (notifyUuids != null) _notifyUuids = notifyUuids;
    if (writeUuids != null) _writeUuids = writeUuids;

    final next = driver ?? _driver;
    if (!_bound || !identical(next, _driver)) {
      _driver = next;
      _bindDriver();
    }

    // 订阅安全认证开关，运行时切换也能同步内部状态（只注册一次）
    if (!_guardBound) {
      BlueSecurityGuard.addListener(_onSecurityGuardChanged);
      _guardBound = true;
    }
    _securityState = BlueSecurityGuard.enabled
        ? BlueSecurityState.idle
        : BlueSecurityState.disabled;

    _initialized = true;
    _log(
      '已初始化，驱动：${_driver.name}，安全认证：'
      '${BlueSecurityGuard.enabled ? '开' : '关'}',
    );
    return this;
  }

  /// 平台相关的全局配置（iOS State Restoration 等）
  ///
  /// **必须在 [init] 之前调用。** iOS 的 `CBCentralManager` 是「首次 BLE 操作时」
  /// 才创建的，而 Restoration 开关必须在创建那一刻就传入；[init] 内部会订阅
  /// 适配器状态流，这已经算首次 BLE 操作，放到 init 之后就晚了。
  ///
  /// - [restoreState]：iOS / macOS 是否开启 State Restoration。开启后，App 进程
  ///   被系统杀死再重启时，系统会保留并恢复之前的连接（插件内部的
  ///   `willRestoreState` 回调接管，对 Dart 侧是透明的）。
  ///   Android / 桌面端没有对应机制，忽略本参数。
  /// - [driver]：显式指定驱动；为空时用默认驱动（init 之前只有默认驱动可用）
  ///
  /// ```dart
  /// await BlueManager.configure(restoreState: true);
  /// BlueManager.i.init();
  /// ```
  static Future<void> configure({
    bool restoreState = false,
    BlueDriver? driver,
    BlueLogLevel logLevel = BlueLogLevel.warning,
  }) async {
    await (driver ?? _instance._driver).configure(
      restoreState: restoreState,
      logLevel: logLevel,
    );
  }

  /// 运行时调整底层插件日志级别
  ///
  /// 排查 BLE 底层收发（notify / write 时序）时可临时开回 debug：
  /// ```dart
  /// await BlueManager.setPluginLogLevel(BlueLogLevel.debug);
  /// ```
  /// 看完记得切回 [BlueLogLevel.warning]，Sensor Data 高频推送会重新刷屏。
  static Future<void> setPluginLogLevel(BlueLogLevel level) =>
      _instance._driver.setLogLevel(level);

  /// 内部断开：安全认证失败、资源释放等场景使用
  ///
  /// 与 [disconnect] 的区别：**不会**写入「用户主动断开」标记，
  /// 因此自动回连仍会在下一轮继续尝试（认证失败可能是暂时性的）。
  Future<void> _abortConnection() async {
    final device = _device;
    if (device == null) return;

    _disconnecting = true;
    try {
      await _notifySub?.cancel();
      _notifySub = null;
      final notify = _notifyCharacteristic;
      if (notify != null) {
        await notify.setNotifyValue(false).catchError((Object _) {});
      }
      await device.disconnect();
    } catch (_) {
      // 兜底场景忽略断开异常
    } finally {
      _onDisconnected();
      _disconnecting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 自动回连
  // ---------------------------------------------------------------------------

  /// 当前生效的自动回连编排器，未启用时为 null
  BlueAutoReconnect? get reconnect => _reconnect;

  /// 启用自动回连
  ///
  /// 解决「第一次配对连接之后，二次启动 App 能否自动连上」：
  /// 连接成功后会记下设备标识，下次启动用 [BlueAutoReconnect.restore]
  /// 直接回连，无需扫描；意外断线会指数退避重连；用户主动断开则停用。
  ///
  /// - [serviceUuids]：读取「系统已连接设备」时的过滤条件（传自家服务 UUID）
  /// - [config]：退避与超时配置
  /// - [permissionGate]：权限检查回调，返回 false 则本次不回连。
  ///   `core/blue` 不依赖权限插件，由业务层注入（如 `ensureBluetoothPermission`）
  /// - [restoreNow]：是否立刻执行一次回连；false 时只启用断线重连能力
  ///
  /// ```dart
  /// // main()：BlueManager.i.init() 之后
  /// final reconnect = BlueManager.i.enableAutoReconnect(
  ///   serviceUuids: EegUuid.serviceUuids,
  ///   permissionGate: ensureBluetoothPermission,
  /// );
  /// unawaited(reconnect.restore());   // 不阻塞首帧
  /// ```
  BlueAutoReconnect enableAutoReconnect({
    List<String>? serviceUuids,
    BlueReconnectConfig config = const BlueReconnectConfig(),
    BluePermissionGate? permissionGate,
    BlueLogWriter? logWriter,
    bool restoreNow = false,
  }) {
    _ensureInitialized();
    unawaited(_reconnect?.dispose());
    final reconnect = BlueAutoReconnect(
      blue: this,
      config: config,
      serviceUuids: serviceUuids,
      permissionGate: permissionGate,
      logger: logWriter,
    );
    _reconnect = reconnect;
    if (restoreNow) unawaited(reconnect.restore());
    return reconnect;
  }

  /// 关闭自动回连：停止退避重试，但保留历史设备记录
  void disableAutoReconnect() => _reconnect?.stop();

  /// 手动连接优先：让自动回连让路
  ///
  /// 用户在页面上点某个设备时先调它：自动回连在 Android 上会挂起最长
  /// [autoConnectWait] 的 autoConnect 等待，并一直占着 [isBusy]，
  /// 不暂停的话手动连接会被「正在处理上一个蓝牙操作」挡掉。
  /// 结束后必须调 [endManualConnect]。
  void beginManualConnect() {
    _manualPriority = true;
    // 打断可能正在进行的 autoConnect 等待（最多几百毫秒内生效）
    _autoConnectAborted = true;
    _reconnect?.suspendForManualConnect();
  }

  /// 手动连接结束：没连上才恢复自动回连（连上了由 [BlueAutoReconnect.onConnected] 接管）
  void endManualConnect({required bool connected}) {
    _manualPriority = false;
    _reconnect?.resumeAfterManualConnect(connected: connected);
  }

  /// 释放全部资源（含广播流），通常在应用退出或单元测试结束时调用
  Future<void> dispose() async {
    if (_initialized) {
      // 释放不是用户主动断开，不能写停用标记
      await _abortConnection();
    }
    await _reconnect?.dispose();
    _reconnect = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    _cancelDriverSubs();
    if (_guardBound) {
      BlueSecurityGuard.removeListener(_onSecurityGuardChanged);
      _guardBound = false;
    }
    for (final controller in <StreamController<dynamic>>[
      _adapterStateCtrl,
      _isScanningCtrl,
      _scanResultsCtrl,
      _connectionEventCtrl,
      _connectionStateCtrl,
      _notificationCtrl,
      _errorCtrl,
      _securityStateCtrl,
    ]) {
      await controller.close();
    }
    _resetSecurity();
    _device = null;
    _services = const <BlueService>[];
    _servicesDiscoveredAt = null;
    _notifyCharacteristic = null;
    _writeCharacteristic = null;
    _notifyReady = false;
    _initialized = false;
    _bound = false;
    _busy = false;
  }

  // ---------------------------------------------------------------------------
  // 适配器
  // ---------------------------------------------------------------------------

  /// 请求开启蓝牙（Android 有效）
  Future<void> turnOn() async {
    _ensureInitialized();
    try {
      await _driver.turnOn();
    } catch (error, stack) {
      throw BlueException(
        type: BlueExceptionType.unauthorized,
        message: '开启蓝牙失败',
        error: error,
        stackTrace: stack,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 扫描
  // ---------------------------------------------------------------------------

  /// 开始扫描
  ///
  /// - [timeout]：为空表示一直扫描直到 [stopScan]
  /// - [serviceUuids]：按服务过滤，为空表示不限制
  Future<void> startScan({Duration? timeout, List<String>? serviceUuids}) async {
    _ensureInitialized();
    if (await _driver.isSupported() == false) {
      throw const BlueException(type: BlueExceptionType.unsupported, message: '当前设备不支持蓝牙低功耗（BLE）');
    }

    if (_autoTurnOn && defaultTargetPlatform == TargetPlatform.android) {
      // 用户拒绝时忽略，adapterState 会给出对应状态
      await _driver.turnOn().catchError((Object _) {});
    }

    try {
      await _driver.startScan(timeout: timeout ?? _scanTimeout, serviceUuids: serviceUuids);
      _log('开始扫描${timeout == null ? '' : '（${timeout.inSeconds}s）'}');
    } catch (error, stack) {
      throw BlueException(
        type: BlueExceptionType.scan,
        message: '扫描失败',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// 停止扫描
  Future<void> stopScan() async {
    _ensureInitialized();
    try {
      await _driver.stopScan();
    } catch (error, stack) {
      throw BlueException(
        type: BlueExceptionType.scan,
        message: '停止扫描失败',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// 系统已连接的设备
  Future<List<BlueDevice>> systemDevices({List<String>? serviceUuids}) async {
    _ensureInitialized();
    return _driver.systemDevices(serviceUuids: serviceUuids);
  }

  // ---------------------------------------------------------------------------
  // 连接
  // ---------------------------------------------------------------------------

  /// 连接设备，成功后自动发现服务并按 UUID 偏好解析推送 / 写入特征
  ///
  /// - [notifyUuids] / [writeUuids]：临时覆盖 init 中配置的偏好
  /// - [autoNotify]：是否自动开启推送
  /// - [autoAuthenticate]：连接后是否自动做安全认证；
  ///   为空表示沿用全局开关 [BlueSecurityGuard.enabled]。
  ///   开关打开且认证失败时，本方法会断开连接并抛 [BlueException]。
  /// - [autoConnect]：true 时改走「系统代管」的自动连接（仅 Android 有效）：
  ///   设备在广播里出现时才连，不会超时失败、更省电，但连得更慢。
  ///   此时 [timeout] 无效，改用 [autoConnectWait] 控制本方法最长阻塞多久。
  /// - [autoConnectWait]：仅在 [autoConnect] 为 true 时生效；
  ///   窗口内连上就继续做服务发现，超时抛 [BlueException]
  ///   （Android 侧的请求仍在，下一轮回连无需重新发起）。
  /// - [manual]：true 表示本次是用户在页面上点的连接，优先级高于自动回连；
  ///   自动回连占着通道时会等它让出（最多 2s）再连，而不是直接报 busy。
  /// 返回已发现的服务列表。
  Future<List<BlueService>> connect(
    BlueDevice device, {
    Duration? timeout,
    int? mtu,
    List<String>? notifyUuids,
    List<String>? writeUuids,
    bool autoNotify = true,
    bool? autoAuthenticate,
    bool autoConnect = false,
    Duration? autoConnectWait,
    bool manual = false,
  }) async {
    _ensureInitialized();
    if (_busy) {
      // 手动连接优先：等自动回连让出通道（abort 后通常几百毫秒内结束）
      if (!manual || !await _waitForIdle(const Duration(seconds: 2))) {
        throw const BlueException(type: BlueExceptionType.busy, message: '正在处理上一个蓝牙操作，请稍后再试');
      }
    }
    _busy = true;
    try {
      // 连接前停止扫描，失败不影响后续连接
      try {
        await stopScan();
      } catch (_) {
        // ignore
      }

      await _connectionSub?.cancel();
      _connectionSub = device.connectionState.listen(_setConnectionState);

      await device.connect(
        timeout: timeout ?? _connectTimeout,
        mtu: mtu ?? _mtu,
        license: _license,
        autoConnect: autoConnect,
      );

      if (autoConnect) {
        // 本轮重新开始等待：上一轮可能已被手动连接抢占而作废
        _autoConnectAborted = false;
        // autoConnect 只是登记了一个后台连接请求，上面的 await 会立即返回，
        // 这里要等到真正连上再做服务发现，否则 discoverServices 必然失败。
        await _waitUntilConnected(device, autoConnectWait ?? _autoConnectWait);
        // mtu 与 autoConnect 互斥（驱动层传的是 null），连上后手动补协商
        await device.requestMtu(mtu ?? _mtu).catchError((Object _) => mtu ?? _mtu);
      }

      _device = device;
      _setConnectionState(BlueConnectionState.connected);

      final services = await device.discoverServices();
      _servicesDiscoveredAt = DateTime.now();
      _services = List<BlueService>.unmodifiable(services);
      _log(
        'discoverServices @${_servicesDiscoveredAt!.toIso8601String()}'
        '，services#$servicesIdentity，共 ${services.length} 个服务',
      );
      _resolveCharacteristics(notifyUuids: notifyUuids, writeUuids: writeUuids);

      // 方案 v1.2：门禁放开前订阅业务数据流会被设备静默拒绝，
      // 因此先做第二层身份认证，成功后再开启业务推送。
      await _runSecurityHandshake(enabled: autoAuthenticate);

      if (autoNotify && _notifyCharacteristic != null) {
        await enableNotify();
      }

      _log('已连接 ${device.id}，${_services.length} 个服务');
      _reconnect?.onConnected(device);
      // 上面的 connected 是在服务发现之前推的（为了让 UI 尽快反馈），
      // 这里服务 / 订阅 / 认证都就绪后再推一次，订阅者拿到的才是可用连接。
      // 自动回连场景没有「手动 connect 的返回值」可用，页面只能靠这个流同步。
      _emit(_connectionStateCtrl, BlueConnectionState.connected);
      return _services;
    } on BlueException {
      rethrow;
    } catch (error, stack) {
      await _connectionSub?.cancel();
      _connectionSub = null;
      throw BlueException(
        type: BlueExceptionType.connect,
        message: '连接失败',
        error: error,
        stackTrace: stack,
      );
    } finally {
      _busy = false;
    }
  }

  /// 断开当前连接并清理订阅
  ///
  /// 主动断开会通知 [BlueAutoReconnect] 停用自动回连
  /// （用户点了断开就不该再自作主张连回去）。
  Future<void> disconnect() async {
    _ensureInitialized();
    final device = _device;

    // 置位期间 [_onDisconnected] 不会误判成「意外断线」
    _disconnecting = true;
    try {
      if (device == null) {
        // 没有设备对象也要走清理：下游（如 EegDeviceService）订阅的是特征
        // 自己的推送流，只有收到 disconnected 才会解绑，不补这一步就会出现
        // 「设备已断开，但日志还在刷推送」的僵尸订阅
        _log('没有连接中的设备对象，只做本地清理');
        return;
      }
      await _notifySub?.cancel();
      _notifySub = null;
      final notify = _notifyCharacteristic;
      if (notify != null) {
        // 关推送可能一直不返回（设备已经掉线时尤其常见），
        // 不能让它挡住真正的断开动作，否则连接一直在、推送也一直来
        await notify
            .setNotifyValue(false)
            .timeout(const Duration(seconds: 2), onTimeout: () {})
            .catchError((Object _) {});
      }
      await device.disconnect().timeout(const Duration(seconds: 3), onTimeout: () {});
      _log('已断开 ${device.id}');
    } catch (error, stack) {
      throw BlueException(
        type: BlueExceptionType.disconnect,
        message: '断开失败',
        error: error,
        stackTrace: stack,
      );
    } finally {
      // 顺序不能反：先走清理与「停用」回调，最后才复位标记
      _reconnect?.onUserDisconnect();
      _onDisconnected();
      _disconnecting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 数据收发
  // ---------------------------------------------------------------------------

  /// 开启推送（notify），成功后数据从 [notifications] 流出
  ///
  /// - [characteristic]：为空则使用连接时解析出的推送特征
  /// - [retry]：额外重试次数，默认再试 1 次
  Future<BlueCharacteristic> enableNotify({
    BlueCharacteristic? characteristic,
    int retry = 1,
  }) async {
    _ensureInitialized();
    final target = characteristic ?? _notifyCharacteristic;
    if (target == null) {
      throw const BlueException(type: BlueExceptionType.notify, message: '设备未提供可通知的特征，无法接收推送数据');
    }

    await _notifySub?.cancel();
    _notifySub = null;
    _notifyReady = false;

    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt <= retry; attempt++) {
      try {
        await target.setNotifyValue(true);
        if (_notifyDelay > Duration.zero) {
          await Future<void>.delayed(_notifyDelay);
        }
        await _notifySub?.cancel();
        _notifySub = target.onValueReceived.listen(
          _onNotification,
          onError: (Object error, StackTrace stack) {
            _notifyReady = false;
            _emitError(
              BlueException(
                type: BlueExceptionType.notify,
                message: '接收推送数据异常',
                error: error,
                stackTrace: stack,
              ),
            );
          },
          cancelOnError: false,
        );
        _notifyCharacteristic = target;
        _notifyReady = true;
        _log('已开启推送：${target.uuid}');
        return target;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (error is BlueException) _onGattFailure(error);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    throw BlueException(
      type: BlueExceptionType.notify,
      message: '开启推送失败',
      error: lastError,
      stackTrace: lastStack,
    );
  }

  /// 关闭推送
  Future<void> disableNotify() async {
    final notify = _notifyCharacteristic;
    if (notify == null) return;
    await _notifySub?.cancel();
    _notifySub = null;
    _notifyReady = false;
    await notify.setNotifyValue(false);
  }

  /// 写入数据到默认写入特征
  Future<void> write(
    List<int> data, {
    BlueCharacteristic? characteristic,
    bool withoutResponse = false,
  }) async {
    _ensureInitialized();
    final target = characteristic ?? _writeCharacteristic;
    if (target == null) {
      throw const BlueException(type: BlueExceptionType.write, message: '未找到可写入的特征');
    }
    try {
      await target.write(data, withoutResponse: withoutResponse);
    } on BlueException catch (error) {
      _onGattFailure(error);
      rethrow;
    } catch (error, stack) {
      final wrapped = BlueException(
        type: BlueExceptionType.write,
        message: '写入失败',
        error: error,
        stackTrace: stack,
      );
      _onGattFailure(wrapped);
      throw wrapped;
    }
  }

  /// 读取特征值
  Future<List<int>> read({BlueCharacteristic? characteristic}) async {
    _ensureInitialized();
    final target = characteristic ?? _notifyCharacteristic;
    if (target == null) {
      throw const BlueException(type: BlueExceptionType.read, message: '未找到可读的特征');
    }
    try {
      return await target.read();
    } on BlueException catch (error) {
      _onGattFailure(error);
      rethrow;
    } catch (error, stack) {
      final wrapped = BlueException(
        type: BlueExceptionType.read,
        message: '读取失败',
        error: error,
        stackTrace: stack,
      );
      _onGattFailure(wrapped);
      throw wrapped;
    }
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /// 把驱动事件转发到各自的广播流
  void _bindDriver() {
    _cancelDriverSubs();
    _driverSubs
      ..add(
        _driver.adapterState.listen((state) {
          _adapterState = state;
          _emit(_adapterStateCtrl, state);
        }, onError: _onDriverError),
      )
      ..add(
        _driver.isScanning.listen((scanning) {
          _scanning = scanning;
          _emit(_isScanningCtrl, scanning);
        }, onError: _onDriverError),
      )
      ..add(
        _driver.scanResults.listen(
          (results) => _emit(_scanResultsCtrl, results),
          onError: _onDriverError,
        ),
      )
      ..add(
        _driver.connectionEvents.listen((event) {
          _emit(_connectionEventCtrl, event);
          if (_device != null && event.deviceId == _device?.id) {
            _setConnectionState(event.state);
          }
        }, onError: _onDriverError),
      );
    _bound = true;
  }

  void _cancelDriverSubs() {
    for (final sub in _driverSubs) {
      unawaited(sub.cancel());
    }
    _driverSubs.clear();
    _bound = false;
  }

  void _setConnectionState(BlueConnectionState state) {
    _connectionState = state;
    if (state == BlueConnectionState.disconnected && _device != null) {
      // 断开事件由 [_onDisconnected] 统一发出，避免下游收到两遍
      _onDisconnected();
      return;
    }
    _emit(_connectionStateCtrl, state);
  }

  /// 断开后的清理：取消订阅、清空服务与特征、作废认证态
  ///
  /// 非 [disconnect] 流程触发时（设备掉电 / 超距 / 被系统回收），
  /// 通知 [BlueAutoReconnect] 开始退避重连。
  void _onDisconnected() {
    unawaited(_notifySub?.cancel());
    _notifySub = null;
    unawaited(_deviceStateSub?.cancel());
    _deviceStateSub = null;
    _notifyReady = false;
    _device = null;
    _services = const <BlueService>[];
    _servicesDiscoveredAt = null;
    _notifyCharacteristic = null;
    _writeCharacteristic = null;
    _resetSecurity();
    // 必须自己补发一次 disconnected：驱动的连接事件往往晚于本地清理到达，
    // 那时 _device 已置空、事件会被 deviceId 守卫挡掉，下游（EegDeviceService）
    // 就收不到断开通知 → 不解绑 → 断开后还在收推送、日志一直刷。
    _connectionState = BlueConnectionState.disconnected;
    _emit(_connectionStateCtrl, BlueConnectionState.disconnected);
    if (!_disconnecting) _reconnect?.onUnexpectedDisconnect();
  }

  /// 等到设备真正连上（[connect] 走 autoConnect 时使用）
  ///
  /// 轮询而不是只监听状态流：手动连接抢占（[beginManualConnect]）时要能在
  /// 几百毫秒内放弃等待，否则会一直卡到 timeout，把用户的点击堵死。
  Future<void> _waitUntilConnected(BlueDevice device, Duration timeout) async {
    if (device.isConnected) return;
    final deadline = DateTime.now().add(timeout);
    while (!device.isConnected) {
      if (_autoConnectAborted) {
        throw const BlueException(type: BlueExceptionType.connect, message: '自动连接已让位给手动连接');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw BlueException(
          type: BlueExceptionType.connect,
          message: '自动连接等待超时（${timeout.inSeconds}s）',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// 等 [isBusy] 变 false，超时返回 false（手动连接抢占自动回连时用）
  Future<bool> _waitForIdle(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_busy) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // 安全认证内部实现
  // ---------------------------------------------------------------------------

  /// 连接后（或手动调用时）执行第二层握手（方案 v1.2）
  ///
  /// - [enabled]：为空表示沿用全局开关；显式传 false 则本次不做认证
  /// - [force]：true 时跳过令牌免认证，强制走完整握手
  Future<DeviceAuthResult?> _runSecurityHandshake({
    bool? enabled,
    bool force = false,
  }) async {
    final on = enabled ?? BlueSecurityGuard.enabled;
    if (!on) {
      _setSecurityState(BlueSecurityState.disabled);
      return null;
    }

    _setSecurityState(BlueSecurityState.authenticating);
    try {
      // 认证状态 / 设备状态两个 CCC 要在认证前开启：
      // 业务流 CCC 等门禁放开后才订阅，但 Key Exchange 的 0x00 结果
      // 与 reset indication 都依赖这两条通道。
      await _enableAuthCcc();
      final authenticator = _ensureAuthenticator();
      final result = await authenticator.authenticate(forceFull: force);

      _authenticatedDeviceId = result.deviceId;
      _setSecurityState(BlueSecurityState.authenticated);
      _startResetMonitor();
      final how = result.viaToken
          ? '（24h Auth Token 免认证）'
          : result.reused
              ? '（设备端会话仍有效）'
              : '（完整认证，设备已派生会话密钥）';
      _log('安全认证通过：${result.deviceId}$how');
      return result;
    } on SecurityException catch (error) {
      _resetSecurity();
      _setSecurityState(BlueSecurityState.failed);
      _emitError(BlueException(type: BlueExceptionType.connect, message: '设备安全认证失败', error: error));
      _log('安全认证失败：$error');
      // 方案要求：认证失败即断开，不放行任何业务数据。
      // 用内部断开：不算「用户主动断开」，自动回连下一轮仍会重试。
      await _abortConnection();
      throw BlueException(
        type: BlueExceptionType.connect,
        message: '设备安全认证失败（${error.code.label}）',
        error: error,
      );
    } catch (error, stack) {
      _resetSecurity();
      _setSecurityState(BlueSecurityState.failed);
      await _abortConnection();
      throw BlueException(
        type: BlueExceptionType.connect,
        message: '设备安全认证异常',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// 运行中遇到门禁拒绝后的重新认证（不阻塞当前调用）
  Future<void> _reauthenticate() async {
    if (!BlueSecurityGuard.enabled || !isConnected) return;
    _setSecurityState(BlueSecurityState.authenticating);
    try {
      final result = await _ensureAuthenticator().authenticate(forceFull: true);
      _authenticatedDeviceId = result.deviceId;
      _setSecurityState(BlueSecurityState.authenticated);
      _log('门禁拒绝后重新认证通过：${result.deviceId}');
    } catch (error) {
      _resetSecurity();
      _setSecurityState(BlueSecurityState.failed);
      _emitError(
        BlueException(type: BlueExceptionType.connect, message: '设备门禁拒绝，重新认证失败', error: error),
      );
    }
  }

  /// GATT 读写失败时的统一入口：识别门禁错误并触发重新认证
  ///
  /// * 0x8F 未认证：认证态失效，重跑完整认证；
  /// * 0x90 令牌失效：先作废本地 24h 令牌，再重跑完整认证。
  ///
  /// 门禁错误**不是传输失败**，不应按重试逻辑处理。
  void _onGattFailure(BlueException error) {
    if (!BlueSecurityGuard.enabled) return;
    if (!isGateRejected(error.gattCode)) return;

    final code = error.gattCode;
    final tokenInvalid = isTokenInvalid(code);
    _log(
      '设备返回门禁错误（GATT 0x${code?.toRadixString(16) ?? '??'}）：'
      '${tokenInvalid ? '令牌失效，清本地令牌' : '认证态失效'}，开始重新认证',
    );
    final deviceId = _authenticatedDeviceId;
    _authenticatedDeviceId = null;
    if (tokenInvalid && deviceId != null) {
      unawaited(_ensureAuthenticator().invalidate(deviceId));
    }
    unawaited(_reauthenticate());
  }

  /// 全局开关变化：同步内部状态
  void _onSecurityGuardChanged(bool enabled) {
    _log('安全认证开关：${enabled ? '开' : '关'}');
    if (!enabled) {
      _resetSecurity();
      _setSecurityState(BlueSecurityState.disabled);
      return;
    }
    _setSecurityState(isConnected ? BlueSecurityState.idle : BlueSecurityState.disabled);
  }

  /// 作废当前认证产物（Device ID）
  void _resetSecurity() {
    _authenticatedDeviceId = null;
  }

  void _setSecurityState(BlueSecurityState state) {
    _securityState = state;
    _emit(_securityStateCtrl, state);
  }

  DeviceAuthenticator _ensureAuthenticator() => _authenticator ??= DeviceAuthenticator(
    transport: BlueManagerSecurityTransport(manager: this),
    logger: _enableLog ? _logWriter : null,
  );

  /// 开启 Auth Status / Device State 的 CCC
  ///
  /// Device State 是 INDICATE 且明文可订阅（reset 后 bond 已清也能收）。
  /// 特征不存在 = 旧固件，静默降级：Auth Status 靠「写 Key Exchange 后读回
  /// 确认」，reset 靠下次连接读 generation 兜底。
  Future<void> _enableAuthCcc() async {
    for (final uuid in <String>[
      SecurityUuid.authStatus,
      SecurityUuid.deviceState,
    ]) {
      final c = characteristicOf(uuid);
      if (c == null || !c.properties.canNotify) continue;
      try {
        await c.setNotifyValue(true);
      } catch (e) {
        _log('CCC 开启失败 $uuid：$e');
      }
    }
  }

  /// 订阅 Device State indication：设备 reset 前会发一次 flags.bit0 = 1
  ///
  /// 文档 6.3：收到后清本地凭据、主动断开且**不自动重连**。
  /// [disconnect] 会置 `_disconnecting`，`_onDisconnected` 因此不会触发回连。
  void _startResetMonitor() {
    unawaited(_deviceStateSub?.cancel());
    final c = characteristicOf(SecurityUuid.deviceState);
    if (c == null) return;
    _deviceStateSub = c.onValueReceived.listen(
      (bytes) {
        if (!SecurityDeviceState.isResetting(bytes)) return;
        _log('*** 收到设备 reset indication，清凭据并主动断开（不自动重连）***');
        unawaited(_ensureAuthenticator().invalidate());
        _setSecurityState(BlueSecurityState.failed);
        unawaited(disconnect());
      },
      onError: (Object _) {},
    );
  }

  /// 按 UUID 偏好解析推送 / 写入特征，未命中时退化为第一个可用特征
  void _resolveCharacteristics({List<String>? notifyUuids, List<String>? writeUuids}) {
    final notifyPrefs = (notifyUuids ?? _notifyUuids).map(BlueUuid.normalize);
    final writePrefs = (writeUuids ?? _writeUuids).map(BlueUuid.normalize);

    BlueCharacteristic? notify;
    BlueCharacteristic? write;

    for (final service in _services) {
      for (final c in service.characteristics) {
        final uuid = BlueUuid.normalize(c.uuid);
        if (notify == null && notifyPrefs.contains(uuid) && c.properties.canNotify) {
          notify = c;
        }
        if (write == null && writePrefs.contains(uuid) && c.properties.canWrite) {
          write = c;
        }
      }
    }

    // 退化：未命中偏好时取第一个可用特征
    if (notify == null || write == null) {
      for (final service in _services) {
        for (final c in service.characteristics) {
          if (notify == null && c.properties.canNotify) notify = c;
          if (write == null && c.properties.canWrite) write = c;
        }
      }
    }

    _notifyCharacteristic = notify;
    _writeCharacteristic = write;
    _log('推送特征：${notify?.uuid ?? '无'}，写入特征：${write?.uuid ?? '无'}');
  }

  /// 设备推送的一包数据：先打日志（`MYB` 前缀 + 十六进制），再投到 [notifications]
  void _onNotification(List<int> value) {
    if (value.isEmpty) return;
    if (notifyLogEnabled) {
      final uuid = _notifyCharacteristic?.uuid;
      debugPrint('MYB recv ${DateExtension.getNowMs()}${_frameTime(value)}\n ');
      debugPrint(
        '${value.length}B${uuid == null ? '' : ' · $uuid'}:\n\n '
        '${BlueHex.format(value, limit: 1000)}\n\n',
      );
    }
    _emit(_notificationCtrl, value);
  }

  /// 这一包是 0x8B 数据帧时，补一段帧内时间戳（精确到毫秒）
  ///
  /// 分包时只有第一片带帧头，后续分片取不到时间戳就留空（那种情况看前面的
  /// APP 接收时刻即可）；还没建立时间锚点时退化为设备相对毫秒。
  String _frameTime(List<int> bytes) {
    final t = peekEegFrameTime(bytes);
    if (t == null) return '';
    final text = DateExtension.frameTimestamp(
      t.timestampMs,
      bootId: t.bootId,
      anchor: EegTimeAnchorHolder.current,
      withDate: false,
      fallback: 'dev ${t.timestampMs}ms',
    );
    return ' · $text';
  }

  void _onDriverError(Object error, StackTrace stack) {
    _emitError(
      BlueException(
        type: BlueExceptionType.unknown,
        message: '蓝牙底层异常',
        error: error,
        stackTrace: stack,
      ),
    );
  }

  void _emitError(BlueException error) {
    _log('${error.message}${error.error == null ? '' : '：${error.error}'}');
    _emit(_errorCtrl, error);
  }

  void _emit<T>(StreamController<T> controller, T value) {
    if (controller.isClosed) return;
    controller.add(value);
  }

  void _log(String message) {
    if (_enableLog) _logWriter('[BLE] $message');
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('BlueManager 尚未初始化，请先调用 BlueManager.instance.init()');
    }
  }
}
