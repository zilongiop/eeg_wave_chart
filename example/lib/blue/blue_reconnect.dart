import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../common/prefs_manager.dart';
import 'blue_defs.dart';
import 'blue_device.dart';
import 'blue_manager.dart';

/// 蓝牙权限闸门
///
/// 返回 `true` 表示可以继续回连，`false` 表示权限不足（编排器会停在
/// [BlueReconnectPhase.disabled] 并给出原因）。
///
/// `core/blue` 不直接依赖任何权限插件，由业务层注入实现（见
/// `common/bluetooth_permission.dart`），这样换掉权限库也不用动本目录。
typedef BluePermissionGate = Future<bool> Function();

/// 日志输出
typedef BlueReconnectLogger = void Function(String message);

/// 上次成功连接过的设备记录
class BlueLastDevice {
  const BlueLastDevice({required this.id, this.name, this.time});

  /// 设备标识（Android = MAC，iOS / macOS = 系统生成的 UUID）
  final String id;

  /// 设备名称（可能为空）
  final String? name;

  /// 最近一次连接成功的时刻
  final DateTime? time;

  /// 是否为空记录
  bool get isEmpty => id.isEmpty;

  @override
  String toString() => 'BlueLastDevice($id${name == null ? '' : ', $name'})';
}

/// 回连阶段
enum BlueReconnectPhase {
  /// 空闲：没有历史记录，或尚未开始
  idle,

  /// 已停用：用户主动断开过，或权限不足、显式关闭
  disabled,

  /// 正在尝试恢复（读系统设备 / 按标识直连）
  restoring,

  /// 退避等待中，等待下一次尝试
  waiting,

  /// 已发起连接，等待结果
  connecting,

  /// 已连上（终态，之后回到 [idle] 继续监听断线）
  connected,

  /// 达到重试上限仍未连上
  failed,
}

extension BlueReconnectPhaseExt on BlueReconnectPhase {
  /// 可直接展示的文案
  String get label => switch (this) {
    BlueReconnectPhase.idle => '未连接',
    BlueReconnectPhase.disabled => '自动回连已关闭',
    BlueReconnectPhase.restoring => '正在恢复连接',
    BlueReconnectPhase.waiting => '等待重试',
    BlueReconnectPhase.connecting => '连接中',
    BlueReconnectPhase.connected => '已连接',
    BlueReconnectPhase.failed => '回连失败',
  };

  /// 是否处于「正在努力重连」的过程中（UI 可据此转圈）
  bool get isBusy =>
      this == BlueReconnectPhase.restoring ||
      this == BlueReconnectPhase.connecting ||
      this == BlueReconnectPhase.waiting;
}

/// 回连过程中的一次状态快照
class BlueReconnectState {
  const BlueReconnectState({
    required this.phase,
    this.attempt = 0,
    this.deviceId,
    this.message,
    this.nextDelay,
  });

  /// 当前阶段
  final BlueReconnectPhase phase;

  /// 当前是第几次尝试（0 = 还没开始）
  final int attempt;

  /// 目标设备标识
  final String? deviceId;

  /// 补充说明（失败原因等）
  final String? message;

  /// [BlueReconnectPhase.waiting] 时距离下次尝试的间隔
  final Duration? nextDelay;

  @override
  String toString() =>
      'BlueReconnectState(${phase.name}, attempt=$attempt'
      '${message == null ? '' : ', $message'})';
}

/// 回连配置
class BlueReconnectConfig {
  const BlueReconnectConfig({
    this.initialDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffFactor = 2,
    this.maxAttempts = 6,
    this.directTimeout = const Duration(seconds: 8),
    this.autoConnectWindow = const Duration(seconds: 30),
    this.useAutoConnect = true,
    this.adapterGracePeriod = const Duration(seconds: 5),
  });

  /// 首次重试前的等待（指数退避的基数）
  final Duration initialDelay;

  /// 退避上限：无论失败多少次，等待都不超过这个值
  final Duration maxDelay;

  /// 退避倍数
  final num backoffFactor;

  /// 最大尝试次数；`-1` 表示不限
  ///
  /// 默认给一个有限值：设备不在旁边时会「连 → 失败 → 退避 → 再连」无限打转，
  /// 表现为一直在扫描 / 一直在重连。用满次数后进入 [BlueReconnectPhase.failed]
  /// 停下来，等下一次断线事件或用户手动连接再重新开始。
  final int maxAttempts;

  /// 每次尝试里「直连」的超时
  final Duration directTimeout;

  /// 每轮里 autoConnect 的等待窗口（见 [useAutoConnect]）
  final Duration autoConnectWindow;

  /// 直连失败后是否挂起 autoConnect 常驻等待
  ///
  /// 仅 Android 生效：系统在设备出现在广播里时才发起连接，省电且不会超时失败。
  /// iOS 无此能力，autoConnect 会被忽略，因此本目录下默认只在 Android 使用。
  final bool useAutoConnect;

  /// 等待蓝牙适配器打开的宽限期，超时就进入退避，由适配器状态变化唤醒
  final Duration adapterGracePeriod;
}

/// 上次连接设备的本地存储
///
/// 统一走 [PrefsManager]，key 全部登记在 [PrefsKeys]。
abstract final class BlueLastDeviceStore {
  /// 读取历史记录；没有记录返回 null
  static BlueLastDevice? read() {
    final id = PrefsManager.i.getString(PrefsKeys.bleLastDeviceId);
    if (id == null || id.isEmpty) return null;

    final ms = PrefsManager.i.getInt(PrefsKeys.bleLastDeviceTime);
    return BlueLastDevice(
      id: id,
      name: PrefsManager.i.getString(PrefsKeys.bleLastDeviceName),
      time: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  /// 写入 / 更新历史记录
  static Future<void> save({required String id, String? name}) async {
    await PrefsManager.i.setString(PrefsKeys.bleLastDeviceId, id);
    if (name != null && name.isNotEmpty) {
      await PrefsManager.i.setString(PrefsKeys.bleLastDeviceName, name);
    }
    await PrefsManager.i.setInt(
      PrefsKeys.bleLastDeviceTime,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 清空历史记录（换设备 / 退出登录时用）
  static Future<void> clear() => PrefsManager.i.removeAll(<String>[
    PrefsKeys.bleLastDeviceId,
    PrefsKeys.bleLastDeviceName,
    PrefsKeys.bleLastDeviceTime,
  ]);

  /// 是否被「用户主动断开」停用
  ///
  /// 用户点了断开就不该再自动连回去，直到他手动再连一次（届时置回 false）。
  static bool get isDisabled =>
      PrefsManager.i.getBool(PrefsKeys.bleAutoReconnectDisabled) ?? false;

  /// 设置停用标记
  static Future<void> setDisabled(bool value) =>
      PrefsManager.i.setBool(PrefsKeys.bleAutoReconnectDisabled, value);
}

/// BLE 自动回连编排器
///
/// 解决「第一次配对连接之后，二次启动 App 能否自动连上」：
///
/// * **Android**：`remoteId` 是 MAC 地址，可跨进程稳定复用，
///   `deviceFromId(mac)` 直接连，无需扫描；直连失败再挂 autoConnect 常驻等待。
/// * **iOS**：拿不到已配对列表，只能靠**本地保存的 peripheral UUID**，
///   `deviceFromId(uuid)` 内部走 `retrievePeripherals(withIdentifiers:)`。
///   注意该 UUID 由每台 iPhone 本地生成，换手机 / 重置系统会失效，
///   因此失败后必须静默降级，不能阻塞启动。
///
/// 用法（`main()` 里，[BlueManager.init] 之后）：
///
/// ```dart
/// final reconnect = BlueManager.i.enableAutoReconnect(
///   serviceUuids: EegUuid.serviceUuids,
///   permissionGate: ensureBluetoothPermission,
/// );
/// unawaited(reconnect.restore());   // 不阻塞首帧
/// ```
///
/// 之后全程自动：连上会记录设备、意外断线会指数退避重连、
/// 用户主动断开会停用（不再自作主张连回去）。
class BlueAutoReconnect {
  /// 由 [BlueManager.enableAutoReconnect] 创建，业务层不要直接 new
  BlueAutoReconnect({
    // 不能用 `this._blue`：私有字段不能作为命名参数名
    // ignore: prefer_initializing_formals
    required BlueManager blue,
    required this.config,
    this.serviceUuids,
    this.permissionGate,
    BlueReconnectLogger? logger,
  }) : _blue = blue,
       _log = logger ?? ((message) => debugPrint('[BLE-RC] $message')) {
    _adapterSub = _blue.adapterState.listen(_onAdapterState);
  }

  /// 被托管的蓝牙管理器
  final BlueManager _blue;

  /// 回连配置
  final BlueReconnectConfig config;

  /// 过滤系统设备用的服务 UUID（为空表示不过滤）
  final List<String>? serviceUuids;

  /// 权限检查（为空表示不检查）
  final BluePermissionGate? permissionGate;

  final BlueReconnectLogger _log;

  final StreamController<BlueReconnectState> _stateCtrl =
      StreamController<BlueReconnectState>.broadcast();

  StreamSubscription<BlueAdapterState>? _adapterSub;
  Timer? _timer;

  String? _targetId;
  int _attempt = 0;
  bool _disposed = false;
  BlueReconnectPhase _phase = BlueReconnectPhase.idle;

  /// 是否被手动连接占用（见 [suspendForManualConnect]）
  bool _manualConnecting = false;

  // ---------------------------------------------------------------------------
  // 对外
  // ---------------------------------------------------------------------------

  /// 状态流（UI 可直接订阅展示「正在回连… / 等待重试 8s」）
  Stream<BlueReconnectState> get state => _stateCtrl.stream;

  /// 最近一次状态（同步读取，供首帧使用）
  BlueReconnectState get stateNow => _last;

  BlueReconnectState _last = const BlueReconnectState(
    phase: BlueReconnectPhase.idle,
  );

  /// 当前阶段
  BlueReconnectPhase get phase => _phase;

  /// 是否启用了「用户主动断开」停用标记
  bool get isDisabledByUser => BlueLastDeviceStore.isDisabled;

  /// 启动回连：App 冷启动时调用
  ///
  /// 返回 true 表示**本次调用**已连上；返回 false 表示转入后台退避重试，
  /// 不抛异常、不阻塞启动。
  Future<bool> restore() async {
    if (_disposed) return false;
    if (_blue.isConnected) {
      _emit(const BlueReconnectState(phase: BlueReconnectPhase.connected));
      return true;
    }

    final last = BlueLastDeviceStore.read();
    if (last == null || last.isEmpty) {
      _emit(
        const BlueReconnectState(
          phase: BlueReconnectPhase.idle,
          message: '无历史连接记录，需手动连接一次',
        ),
      );
      return false;
    }
    if (BlueLastDeviceStore.isDisabled) {
      _emit(
        BlueReconnectState(
          phase: BlueReconnectPhase.disabled,
          deviceId: last.id,
          message: '上次为用户主动断开，不再自动回连',
        ),
      );
      return false;
    }

    final gate = permissionGate;
    if (gate != null && !await gate()) {
      _emit(
        BlueReconnectState(
          phase: BlueReconnectPhase.disabled,
          deviceId: last.id,
          message: '蓝牙权限不足，未执行自动回连',
        ),
      );
      return false;
    }

    _targetId = last.id;
    _attempt = 0;
    _emit(
      BlueReconnectState(
        phase: BlueReconnectPhase.restoring,
        deviceId: last.id,
        message: '目标 ${last.name ?? last.id}',
      ),
    );
    return _runAttempt();
  }

  /// 连接成功（由 [BlueManager.connect] 调用）
  void onConnected(BlueDevice device) {
    if (_disposed) return;
    _timer?.cancel();
    _attempt = 0;
    _targetId = device.id;
    unawaited(BlueLastDeviceStore.save(id: device.id, name: device.name));
    unawaited(BlueLastDeviceStore.setDisabled(false));
    _emit(
      BlueReconnectState(
        phase: BlueReconnectPhase.connected,
        deviceId: device.id,
      ),
    );
    _log('已记录设备 ${device.id}，后续启动会自动回连');
  }

  /// 用户主动断开（由 [BlueManager.disconnect] 调用）
  ///
  /// 写入停用标记：下次启动不再自动连，直到用户手动连一次。
  void onUserDisconnect() {
    if (_disposed) return;
    _timer?.cancel();
    unawaited(BlueLastDeviceStore.setDisabled(true));
    _emit(
      const BlueReconnectState(
        phase: BlueReconnectPhase.disabled,
        message: '用户主动断开，已停用自动回连',
      ),
    );
    _log('用户主动断开，停用自动回连');
  }

  /// 手动连接优先：暂停自动回连
  ///
  /// 用户在页面上点了某个设备时（配合 [BlueManager.beginManualConnect]）调用，
  /// 避免自动回连和手动点击抢同一条连接 —— [BlueManager] 同时只允许一个
  /// 连接操作，回连在 Android 上还会挂起最长 30s 的 autoConnect 窗口。
  /// 暂停期间不发起任何尝试，由 [resumeAfterManualConnect] 恢复。
  void suspendForManualConnect() {
    if (_disposed) return;
    _manualConnecting = true;
    _timer?.cancel();
    _log('手动连接中，暂停自动回连');
  }

  /// 手动连接结束：连上了交给 [onConnected] 接管，没连上再接着退避重试
  void resumeAfterManualConnect({required bool connected}) {
    if (_disposed) return;
    _manualConnecting = false;
    if (connected || _blue.isConnected) return;

    final id = _targetId ?? BlueLastDeviceStore.read()?.id;
    if (id == null || id.isEmpty) return;
    if (BlueLastDeviceStore.isDisabled) return;

    _targetId = id;
    _attempt = 0;
    _log('手动连接未成功，继续自动回连：$id');
    _scheduleRetry();
  }

  /// 是否正被手动连接占用（占用期间不自动重连）
  bool get isSuspendedForManual => _manualConnecting;

  /// 意外断线（设备掉电 / 超距 / 被系统回收），开始退避重连
  void onUnexpectedDisconnect() {
    if (_disposed) return;
    if (_manualConnecting) return;
    if (_blue.isConnected) return;

    final id = _targetId ?? BlueLastDeviceStore.read()?.id;
    if (id == null || id.isEmpty) return;
    if (BlueLastDeviceStore.isDisabled) return;

    _targetId = id;
    _attempt = 0;
    _log('意外断线，开始自动重连：$id');
    _scheduleRetry();
  }

  /// 停止退避重试（不清历史记录，也不写停用标记）
  void stop() {
    _timer?.cancel();
    if (_phase == BlueReconnectPhase.waiting ||
        _phase == BlueReconnectPhase.restoring ||
        _phase == BlueReconnectPhase.connecting) {
      _emit(
        BlueReconnectState(
          phase: BlueReconnectPhase.idle,
          deviceId: _targetId,
          message: '已停止自动回连',
        ),
      );
    }
  }

  /// 释放资源（App 退出 / 单元测试结束时调用）
  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _adapterSub?.cancel();
    _adapterSub = null;
    await _stateCtrl.close();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 一次完整尝试：等适配器 → 系统设备 → 直连 → autoConnect 兜底
  Future<bool> _runAttempt() async {
    if (_disposed || _manualConnecting) return false;
    final id = _targetId;
    if (id == null || id.isEmpty) return false;

    _attempt++;
    _emit(
      BlueReconnectState(
        phase: BlueReconnectPhase.connecting,
        attempt: _attempt,
        deviceId: id,
      ),
    );

    if (!await _ensureAdapterOn()) {
      _log('蓝牙未打开，等待适配器就绪');
      _scheduleRetry();
      return false;
    }

    final ok = await _connectOnce(id);
    if (ok) {
      // 这条日志是「断开后又收到数据」的关键判据：设备其实是被自动回连连回来了
      _log('回连成功：$id（第 $_attempt 次尝试）→ 重新订阅推送，数据恢复');
      _emit(
        BlueReconnectState(
          phase: BlueReconnectPhase.connected,
          attempt: _attempt,
          deviceId: id,
        ),
      );
      return true;
    }

    if (config.maxAttempts > 0 && _attempt >= config.maxAttempts) {
      _emit(
        BlueReconnectState(
          phase: BlueReconnectPhase.failed,
          attempt: _attempt,
          deviceId: id,
          message: '已重试 $_attempt 次仍未连上',
        ),
      );
      _log('回连失败：已重试 $_attempt 次');
      return false;
    }

    _scheduleRetry();
    return false;
  }

  /// 连接一次：先直连，Android 上失败再挂 autoConnect 常驻等待
  Future<bool> _connectOnce(String id) async {
    BlueDevice? device;
    try {
      device = await _findSystemDevice(id) ?? _blue.driver.deviceFromId(id);
    } catch (error) {
      _log('构造设备对象失败：$error');
      return false;
    }

    // ① 直连：设备就在旁边时通常 1~2s 内成功
    try {
      await _blue.connect(device, timeout: config.directTimeout);
      return true;
    } catch (error) {
      _log('第 $_attempt 次直连失败：$error');
    }

    // ② Android 兜底：交给系统，设备出现在广播里时才连，不超时、省电
    if (!_autoConnectSupported) return false;
    try {
      await _blue.connect(
        device,
        autoConnect: true,
        autoConnectWait: config.autoConnectWindow,
        timeout: config.autoConnectWindow,
      );
      return true;
    } catch (error) {
      _log('第 $_attempt 次 autoConnect 窗口内未连上：$error');
      return false;
    }
  }

  /// 在系统已连接的设备里找目标（省一次 GATT 握手）
  Future<BlueDevice?> _findSystemDevice(String id) async {
    try {
      final devices = await _blue.systemDevices(serviceUuids: serviceUuids);
      for (final device in devices) {
        if (device.id == id) return device;
      }
    } catch (error) {
      _log('读取系统设备失败：$error');
    }
    return null;
  }

  /// 等蓝牙打开；超时返回 false，之后由适配器状态变化唤醒
  Future<bool> _ensureAdapterOn() async {
    if (_blue.adapterStateNow == BlueAdapterState.on) return true;
    try {
      await _blue.adapterState
          .firstWhere((state) => state == BlueAdapterState.on)
          .timeout(config.adapterGracePeriod);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// 指数退避：initialDelay × factor^(attempt-1)，不超过 maxDelay
  void _scheduleRetry() {
    if (_disposed || _manualConnecting) return;

    final base = config.initialDelay.inMilliseconds;
    final factor = math.pow(config.backoffFactor, math.max(_attempt - 1, 0));
    final ms = math.min(
      base * factor,
      config.maxDelay.inMilliseconds.toDouble(),
    );
    final delay = Duration(milliseconds: ms.round());

    _emit(
      BlueReconnectState(
        phase: BlueReconnectPhase.waiting,
        attempt: _attempt,
        deviceId: _targetId,
        nextDelay: delay,
        message: '${delay.inSeconds}s 后第 ${_attempt + 1} 次尝试',
      ),
    );

    _timer?.cancel();
    _timer = Timer(delay, () {
      if (_disposed) return;
      unawaited(_runAttempt());
    });
  }

  /// 蓝牙被打开 / 重新打开时，立刻唤醒重试（重置退避）
  void _onAdapterState(BlueAdapterState state) {
    if (_disposed || state != BlueAdapterState.on) return;
    if (_phase == BlueReconnectPhase.connected ||
        _phase == BlueReconnectPhase.disabled) {
      return;
    }
    // 已经在重试节奏里就别重置退避：蓝牙适配器一抖动（开关蓝牙、扫描前的
    // turnOn）都会收到 on，若每次都把间隔打回初始值，指数退避会形同虚设，
    // 表现就是「一直在重连」。只有空闲 / 用满次数停下来之后才立即唤醒。
    if (_phase == BlueReconnectPhase.waiting ||
        _phase == BlueReconnectPhase.connecting ||
        _phase == BlueReconnectPhase.restoring) {
      return;
    }
    if (_manualConnecting) return;

    final id = _targetId ?? BlueLastDeviceStore.read()?.id;
    if (id == null || id.isEmpty) return;
    if (BlueLastDeviceStore.isDisabled) return;
    if (_blue.isConnected) return;

    _targetId = id;
    _attempt = 0;
    _timer?.cancel();
    _log('蓝牙已打开，重新开始回连');
    unawaited(_runAttempt());
  }

  /// 是否支持 autoConnect（仅 Android；iOS 上该参数会被忽略）
  bool get _autoConnectSupported =>
      config.useAutoConnect && defaultTargetPlatform == TargetPlatform.android;

  void _emit(BlueReconnectState state) {
    if (_disposed) return;
    _phase = state.phase;
    _last = state;
    if (!_stateCtrl.isClosed) _stateCtrl.add(state);
  }
}
