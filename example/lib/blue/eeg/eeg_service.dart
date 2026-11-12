import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../common/event_bus_manager.dart';
import '../../extension/date_extension.dart' show DateExtension;
import '../blue_defs.dart';
import '../blue_gatt.dart';
import '../blue_manager.dart';
import '../blue_utils.dart';
import 'eeg_cmd.dart';
import 'eeg_config.dart';
import 'eeg_data_frame.dart';
import 'eeg_event.dart';
import 'eeg_frame.dart';
import 'eeg_sample_rate.dart';
import 'eeg_uuid.dart';

/// 头戴 EEG 设备的业务服务（core/blue 之上的一层）
///
/// 职责：
/// 1. **绑定**：连接后按 [EegUuid] 把 5 大服务的特征找出来并订阅推送
/// 2. **上行**：Sensor Data / Config Event 的字节流 → 解析 → 按类型
///    投递到全局事件总线（[EventBusManager]）
/// 3. **下行**：把配置封装成 `AA CMD DATA XOR 55` 帧写进 Config Command
/// 4. **辅助**：OTA 只做事件转发（升级走 `lib/ota`），安全服务提供流程接口
///
/// 用法：
/// ```dart
/// // main()：蓝牙初始化后挂上
/// BlueManager.i.init();
/// await EegDeviceService.i.attach();
///
/// // 页面里只订阅关心的事件
/// final sub = EegDeviceService.i.on<EegDogStateEvent>().listen((e) {
///   debugPrint('小狗：${e.state.label}');
/// });
///
/// // 改采样率
/// await EegDeviceService.i.setEegImuConfig(eegHz: 1000, imuHz: 120);
/// ```
class EegDeviceService {
  EegDeviceService._();

  static final EegDeviceService _instance = EegDeviceService._();

  /// 单例
  static EegDeviceService get instance => _instance;

  /// 单例简写：`EegDeviceService.i`
  static EegDeviceService get i => _instance;

  /// 数据帧解析选项（字节序 / Length 口径 / 采样点排布未与嵌入式对齐时可运行时调整）
  EegFrameOptions get frameOptions => _dataParser.options;

  /// 数据帧解析统计（分包组装异常时先看 [EegFrameStats.resyncs]）
  EegFrameStats get frameStats => _dataParser.stats;

  /// 缓冲里攒着、还没凑成一整帧的字节数（分包的中间态）
  ///
  /// 一直涨说明某帧始终凑不齐（定界口径 / 字节序不对，或设备真的没发完）。
  int get framePendingBytes => _dataParser.pendingBytes;

  /// 清空数据帧解析缓冲（换定界口径后手动清一次乱流）
  void resetFrameParser() => _dataParser.reset();

  set frameOptions(EegFrameOptions value) => _dataParser.options = value;

  /// 是否把每条原始推送也发到总线（[EegRawNotifyEvent]），默认关
  bool debugRaw = false;

  /// 是否打印日志（前缀 `[EEG]`）
  bool enableLog = true;

  /// 收到原始推送包时是否打印内容（`MYB recv …`）
  ///
  /// EEG 数据走的是 Sensor Data **特征自己的** `onValueReceived`，
  /// 不经过 [BlueManager.notifications]（那里的 MYB 日志对 EEG 链路无效），
  /// 所以要在这里单独打。
  ///
  /// **默认关**：2000Hz 下每秒上百包，每包都要做一次 [BlueHex.format]，
  /// 这在 UI isolate 上是实打实的开销（和波形重算抢同一帧）。排查丢包 /
  /// 分包异常时再临时置 true。
  bool rxLogEnabled = false;

  /// 原始包日志最多打印的字节数；null = 整包全打
  int? rxLogBytes = 1000;

  /// 攒够一整包后是否打印解析后的内容（`MYB frame …`）
  ///
  /// **默认关**，理由同 [rxLogEnabled]：每帧十几次字符串插值，20 帧/秒
  /// 就是每秒几百次字符串分配。
  bool frameLogEnabled = false;

  final EegConfigFrameDecoder _configDecoder = EegConfigFrameDecoder();
  final EegDataFrameParser _dataParser = EegDataFrameParser();
  final Map<String, BlueCharacteristic> _chars = <String, BlueCharacteristic>{};
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  StreamSubscription<BlueConnectionState>? _connectionSub;
  bool _attached = false;

  /// 是否已绑定到**当前**连接（bind 成功置位，unbind / 断开时清零）
  ///
  /// 推送入口统一靠它做守卫：不清零就会出现「断开后还在收推送」的僵尸订阅
  bool _bound = false;

  /// 绑定时的设备 id：用来识别「连的是另一台 / 已换设备」的残留推送
  String? _boundDeviceId;

  /// bind 轮次：并发 bind、或订阅途中又断开时，作废上一轮的订阅
  int _bindGeneration = 0;

  EegTimeAnchor? _anchor;
  EegImuConfig? _config;
  String? _deviceId;
  int? _battery;
  EegLabelReport? _label;

  // ---------------------------------------------------------------------------
  // 状态
  // ---------------------------------------------------------------------------

  /// 特征是否已绑定（能找到 Config Command 才认为可用）
  bool get isReady => _chars.containsKey(EegUuid.configCommand);

  /// 当前电量（未上报过为 null）
  int? get battery => _battery;

  /// 当前生效的脑电+IMU 配置（未上报过为 null）
  EegImuConfig? get config => _config;

  /// 设备唯一标识
  String? get deviceId => _deviceId;

  /// 最近一次小狗状态
  EegLabelReport? get label => _label;

  /// 时间锚点（未建立为 null）
  EegTimeAnchor? get anchor => _anchor;

  /// 已绑定的特征 UUID（调试用）
  List<String> get boundUuids => _chars.keys.toList(growable: false);

  /// 订阅事件（语法糖，等价于 `EventBusManager.i.on<T>()`）
  Stream<T> on<T extends EegEvent>() => EventBusManager.i.on<T>();

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 挂到 [BlueManager]：监听连接状态，连上自动绑定，断开自动清理
  ///
  /// 建议在 `main()` 里 `BlueManager.i.init()` 之后调用一次。
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    await _connectionSub?.cancel();
    _connectionSub = BlueManager.i.connectionState.listen(_onConnectionState);
    if (BlueManager.i.isConnected) await bind();
  }

  /// 取消挂载并释放订阅
  Future<void> detach() async {
    await _connectionSub?.cancel();
    _connectionSub = null;
    _attached = false;
    await unbind();
  }

  /// 绑定特征并订阅推送（连接成功后自动调用，也可手动重绑）
  ///
  /// 设备没提供某个服务时静默跳过，只在日志里提示。
  /// 需要订阅的推送特征（bind / unbind 共用一份，避免两边漏项）
  List<_EegNotifySpec> get _notifySpecs => <_EegNotifySpec>[
    _EegNotifySpec(EegUuid.sensorData, _onSensorData, 'Sensor Data'),
    _EegNotifySpec(EegUuid.configEvent, _onConfigEvent, 'Config Event'),
    _EegNotifySpec(EegUuid.errorRecord, _onErrorRecord, 'Error Record'),
    _EegNotifySpec(EegUuid.authStatus, _onAuthStatus, 'Auth Status'),
    _EegNotifySpec(EegUuid.otaEvent, _onOtaEvent, 'OTA Event'),
    _EegNotifySpec(EegUuid.testData, _onTestData, 'Test Data'),
  ];

  Future<void> bind() async {
    final gen = ++_bindGeneration;
    await unbind();

    for (final service in BlueManager.i.services) {
      for (final c in service.characteristics) {
        _chars[BlueUuid.normalize(c.uuid)] = c;
      }
    }
    if (_chars.isEmpty) {
      _log('未发现任何服务，请先 BlueManager.i.connect()');
      return;
    }

    for (final spec in _notifySpecs) {
      // 订阅途中又断开 / 重新绑定了：这一轮作废，否则会留下没人管的订阅
      if (gen != _bindGeneration) {
        await unbind();
        return;
      }
      await _subscribe(spec.uuid, spec.onData, spec.label);
    }
    if (gen != _bindGeneration) {
      await unbind();
      return;
    }

    _bound = true;
    _boundDeviceId = BlueManager.i.connectedDevice?.id;
    _log('已绑定 ${_chars.length} 个特征，订阅 ${_subs.length} 路推送');
  }

  /// 解绑：关闭推送订阅并清空状态
  ///
  /// 关键：**任何一步出错都不能中断后续清理**。半途退出会留下僵尸订阅，
  /// 表现就是「设备已断开，日志还在刷 MYB recv」。
  Future<void> unbind() async {
    _bound = false;
    _boundDeviceId = null;

    // 1) 先摘 Dart 侧监听（拷贝一份再清空，避免 cancel 期间列表被改动）
    final subs = List<StreamSubscription<dynamic>>.of(_subs);
    _subs.clear();
    for (final sub in subs) {
      try {
        await sub.cancel().timeout(const Duration(seconds: 2));
      } catch (_) {
        // 取消失败也要继续：剩下的订阅必须都摘掉
      }
    }

    // 2) 再关设备侧推送：不看 isNotifying（驱动状态可能与实际不同步），
    //    一律尝试关一次；超时 / 报错（设备已掉线时的常态）都不影响后续清理
    for (final spec in _notifySpecs) {
      final c = _chars[BlueUuid.normalize(spec.uuid)];
      if (c == null) continue;
      try {
        await c.setNotifyValue(false).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _chars.clear();
    _configDecoder.reset();
    _dataParser.reset();
    _anchor = null;
    _config = null;
    _deviceId = null;
    _battery = null;
    _label = null;
  }

  // ---------------------------------------------------------------------------
  // 上行：Sensor Data（二进制数据帧）
  // ---------------------------------------------------------------------------

  /// 原始推送包流：Sensor Data 特征收到的**每一包**（未解析、未组帧）
  ///
  /// ⚠️ EEG 数据不走 [BlueManager.notifications] —— Sensor Data 是在这里用
  /// 特征自己的 `onValueReceived` 单独订阅的（见 [_onSensorData]），BlueManager
  /// 那条链路上根本没有它，所以想落 EEG 原始包必须订阅这里。
  /// debug 侧的 `BleLogWriter` 就是靠这个流写盘的。
  ///
  /// broadcast：允许多路订阅；没人订阅时跳过 add，2000Hz 下不产生额外开销。
  Stream<List<int>> get rawPackets => _rawPacketCtrl.stream;

  final StreamController<List<int>> _rawPacketCtrl = StreamController<List<int>>.broadcast();

  void _onSensorData(List<int> bytes) {
    // 守卫：不属于当前绑定的连接的推送 = 僵尸订阅（状态事件丢了 / 重连竞态），
    // 直接丢弃，不再打日志也不再解析，避免断开后终端一直刷 MYB recv
    if (!_acceptNotify('Sensor Data', bytes)) return;
    // 落盘要的是解析前的原始字节，所以紧跟守卫之后就发出去
    if (_rawPacketCtrl.hasListener) _rawPacketCtrl.add(bytes);
    if (rxLogEnabled) _logRx(EegUuid.sensorData, bytes);
    if (debugRaw) {
      _fire(EegRawNotifyEvent(uuid: EegUuid.sensorData, bytes: bytes));
    }
    for (final frame in _dataParser.push(bytes)) {
      switch (frame) {
        case EegDataFrame f:
          if (frameLogEnabled) _logDataFrame(f);
          _updateBattery(f.eleQuantity);
          _fire(EegSamplesEvent(frame: f));
          // v1.0.10 起小狗状态标签以 7.2 的 LabelCode 为准（0xFF = 未就绪）
          if (f.hasDogState) _fireDogState(f.labelCode, f.timestampMs);
        case EegImpedanceFrame f:
          if (frameLogEnabled) {
            _logMyb(
              'frame 阻抗 ${f.kohm.map((v) => v.toStringAsFixed(1)).join('/')} kΩ'
              ' · bat: ${f.eleQuantity}%',
            );
          }
          _updateBattery(f.eleQuantity);
          _fire(EegImpedanceEvent(frame: f));
      }
    }
  }

  /// 残留推送的告警节流：最多 10 秒打一条，避免反而刷屏
  DateTime? _lastStaleLogAt;
  int _staleCount = 0;

  /// 推送统一守卫：不属于「绑定在当前连接上」的推送一律丢弃
  ///
  /// 比只看 `BlueManager.isConnected` 更严三种情况：
  /// * 已解绑 / 未绑定（断开后的僵尸订阅）；
  /// * 当前已无连接设备；
  /// * 连的是**另一台**设备（重连竞态下旧订阅还活着，这是最常见的残留来源）。
  bool _acceptNotify(String label, List<int> bytes) {
    if (_bound) {
      final cur = BlueManager.i.connectedDevice?.id;
      if (cur == null || _boundDeviceId == null || cur == _boundDeviceId) {
        return true;
      }
    }
    _logStaleNotify(label, bytes.length);
    return false;
  }

  /// 记录「没绑定却收到推送」，并顺手自我解绑一次（10 秒最多一条）
  void _logStaleNotify(String label, int bytes) {
    _staleCount++;
    final now = DateTime.now();
    final last = _lastStaleLogAt;
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _lastStaleLogAt = now;
    _log(
      '未绑定却收到 $label 推送 ${bytes}B（累计 $_staleCount 包）：'
      '绑定设备=${_boundDeviceId ?? '无'}，当前设备='
      '${BlueManager.i.connectedDevice?.id ?? '无'}，丢弃并重新解绑',
    );
    // 兜底解绑：把僵尸订阅砍掉，从根上止住
    unawaited(unbind());
  }

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

  /// 打印收到的原始推送包（`MYB recv …`）
  void _logRx(String uuid, List<int> bytes) {
    debugPrint('MYB recv ${DateExtension.getNowMs()}${_frameTime(bytes)}\n ');
    _logMyb('recv ${bytes.length}B · $uuid: ${BlueHex.format(bytes, limit: rxLogBytes)}');
  }

  /// 打印攒够的一整包数据帧内容（`MYB frame …`）
  ///
  /// 采样点只打每通道前 3 个（2000Hz 一包上百个点，全打会刷屏），
  /// IMU 只打首条；要看全部原始字节看上面那条 `MYB recv`。
  void _logDataFrame(EegDataFrame f) {
    final first = f.imu.isEmpty ? null : f.imu.first;
    _logMyb(
      'frame 0x${f.cmd.toRadixString(16).toUpperCase()}'
      ' · bat: ${f.eleQuantity}%'
      ' · mask: 0x${f.channelMask.toRadixString(16).toUpperCase()}'
      ' · ${f.channelNum}ch × ${f.sampleCount}点'
      ' · boot: ${f.bootId}'
      ' · t: ${f.timestampMs}ms'
      ' · label: 0x${f.labelCode.toRadixString(16).toUpperCase()}'
      ' · imu: ${f.imu.length}条'
      '${first == null ? '' : ' acc(${first.accX},${first.accY},${first.accZ})'
                ' gyro(${first.gyroX},${first.gyroY},${first.gyroZ})'
                ' temp:${first.temperature} 步:${first.stepCount}'
                ' evt:0x${first.eventMask.toRadixString(16).toUpperCase()}'}',
    );

    final head = <String>[];
    for (var c = 0; c < f.channels.length && c < 8; c++) {
      head.add('ch${c + 1}[${f.channels[c].take(3).join(',')}]');
    }
    if (head.isNotEmpty) _logMyb('frame 采样 ${head.join(' ')}');
  }

  /// 由数据帧的 LabelCode 广播小狗状态（与 0xAF 上报走同一事件）
  void _fireDogState(int code, int timestampMs) {
    if (_anchor == null) {
      _fire(EegDogStateEvent(code: code, timestampMs: timestampMs));
      return;
    }
    _fire(
      EegDogStateEvent(
        code: code,
        timestampMs: timestampMs,
        absoluteTime: _anchor!.absolute(_anchor!.bootId, timestampMs),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 上行：Config Event（配置帧）
  // ---------------------------------------------------------------------------

  void _onConfigEvent(List<int> bytes) {
    if (!_acceptNotify('Config Event', bytes)) return;
    if (debugRaw) {
      _fire(EegRawNotifyEvent(uuid: EegUuid.configEvent, bytes: bytes));
    }
    for (final frame in _configDecoder.push(bytes)) {
      _dispatchConfigFrame(frame);
    }
  }

  /// 按命令字分发上行配置帧
  @visibleForTesting
  void debugDispatchConfigFrame(EegConfigFrame frame) =>
      _dispatchConfigFrame(frame);

  void _dispatchConfigFrame(EegConfigFrame frame) {
    final cmd = frame.cmd;
    final json = frame.json ?? const <String, dynamic>{};

    // v1.0.13：事件不再占用独立命令字，改为在帧的 DATA 里带 {"event":"xxx"}
    // （见 7.3 示例 4），先按 event 字段识别，再走命令字分发。
    final eventType = EegDeviceEventType.fromName(json['event']?.toString());
    if (eventType != null) {
      _log('设备事件：${eventType.name}');
      _fire(EegDeviceEventReport(type: eventType));
      return;
    }

    switch (cmd) {
      case EegCmd.reportTimestamps:
        final raw = json['Timestamps'];
        if (raw is! Map) {
          // 数据不对：可能是老固件的专用事件命令字（DATA 为空）
          if (_reportLegacyEvent(cmd, json)) return;
          break;
        }
        final ts = EegTimestamps.fromJson(_map(raw));
        _anchor = EegTimeAnchor(
          bootId: ts.bootId,
          deviceTimestampMs: ts.timestampMs,
          realTime: DateTime.now(),
        );
        // 同步给 BLE 层（MYB 日志要打印帧时间，但它不能反过来依赖本服务）
        EegTimeAnchorHolder.current = _anchor;
        _log('时间锚点：$_anchor');
        _fire(EegTimeAnchorEvent(anchor: _anchor!));
        _reportDeviceId(json);
        break;
      case EegCmd.reportDefaultConfig:
        final cfg = EegImuConfig.fromJson(_map(json['eeg_imu_config']));
        _config = cfg;
        if (cfg.eleQuantity != null) _updateBattery(cfg.eleQuantity!);
        // 默认配置就是设备当前实际采样率：连接后立刻同步全局单例，
        // 避免 App 侧沿用旧档位（画布/上传按错的采样率工作）
        if (cfg.eegHz != null) EegSampleRate.i.set(cfg.eegHz!.toDouble());
        _fire(EegConfigReportEvent(config: cfg, isDefault: true, raw: json));
        break;
      case EegCmd.reportChangeSample:
        final change = EegChangeSample.fromJson(_map(json['change_sample']));
        if (change.eegHz != null) {
          _config =
              _config?.copyWith(eegHz: change.eegHz) ??
              EegImuConfig(eegHz: change.eegHz, imuHz: 120);
          // 设备通知采样率已切换 → 写全局单例，HomeLiveEegCard /
          // LiveEEGPage 的 _rateWorker 会清空画布并重建缓冲/滤波级联。
          // 同值 set 不触发 ever（GetX 只在变化时通知），与调试页
          // 0x21 按钮的乐观写入不冲突。
          EegSampleRate.i.set(change.eegHz!.toDouble());
        }
        _fire(EegChangeSampleEvent(eegHz: change.eegHz));
        break;
      case EegCmd.legacyReportLabel:
        final label = EegLabelReport.fromJson(_map(json['label']));
        _label = label;
        _fireDogState(label.code, label.timestampMs);
        break;
      case EegCmd.ackQueryConfig:
        final payload = EegConfigPayload.fromJson(json);
        if (payload.eegImu != null) _config = payload.eegImu;
        // 查询应答里的配置同样是设备当前真实值，顺手同步采样率
        final qHz = payload.eegImu?.eegHz;
        if (qHz != null) EegSampleRate.i.set(qHz.toDouble());
        _fire(EegConfigSnapshotEvent(config: payload));
        _fireCommandResult(cmd, json);
        break;
      default:
        if (EegCmd.isAck(cmd)) {
          _fireCommandResult(cmd, json);
          return;
        }
        // ≤ v1.0.12：事件用专用命令字上报（DATA 为空）
        if (_reportLegacyEvent(cmd, json)) return;
        // 其余：可能是独立上报的 DeviceId / 未知帧
        if (_reportDeviceId(json) || _reportConfig(json)) return;
        _log('未知配置帧：${EegCmd.nameOf(cmd)} ${frame.text}');
        _fire(EegUnknownFrameEvent(cmd: cmd, text: frame.text));
    }
  }

  /// ≤ v1.0.12 遗留的事件命令字识别：识别到返回 true
  bool _reportLegacyEvent(int cmd, Map<String, dynamic> json) {
    final type = EegDeviceEventType.fromLegacyCmd(cmd);
    if (type == null) return false;
    _log('设备事件（旧命令字）：${type.name}');
    _fire(EegDeviceEventReport(type: type));
    return true;
  }

  void _fireCommandResult(int cmd, Map<String, dynamic> json) {
    _fire(EegCommandResultEvent(cmd: cmd, result: _intOf(json['result']) ?? 0, raw: json));
  }

  /// 设备唯一标识：识别到返回 true
  bool _reportDeviceId(Map<String, dynamic> json) {
    final raw = json['DeviceId'];
    if (raw is! Map) return false;
    final identity = EegDeviceIdentity.fromJson(_map(raw));
    if (identity.id.isEmpty) return false;
    _deviceId = identity.id;
    _fire(EegDeviceIdEvent(id: identity.id));
    return true;
  }

  /// 配置上报：识别到返回 true
  bool _reportConfig(Map<String, dynamic> json) {
    final raw = json['eeg_imu_config'];
    if (raw is! Map) return false;
    final cfg = EegImuConfig.fromJson(_map(raw));
    _config = cfg;
    if (cfg.eleQuantity != null) _updateBattery(cfg.eleQuantity!);
    _fire(EegConfigReportEvent(config: cfg, raw: json));
    return true;
  }

  void _updateBattery(int? level) {
    if (level == null || level == _battery) return;
    _battery = level;
    _fire(EegBatteryEvent(level: level));
  }

  // ---------------------------------------------------------------------------
  // 上行：其它服务
  // ---------------------------------------------------------------------------

  void _onErrorRecord(List<int> bytes) {
    if (!_acceptNotify('Error Record', bytes)) return;
    _fire(EegErrorEvent(raw: bytes, text: _tryText(bytes)));
  }

  void _onAuthStatus(List<int> bytes) {
    if (!_acceptNotify('Auth Status', bytes)) return;
    _fire(EegAuthStatusEvent(raw: bytes, text: _tryText(bytes)));
  }

  void _onOtaEvent(List<int> bytes) {
    if (!_acceptNotify('OTA Event', bytes)) return;
    // 升级流程由 lib/ota 的 OtaManager 接管，这里只做通知
    _fire(EegOtaEventNotice(raw: bytes));
  }

  void _onTestData(List<int> bytes) {
    if (!_acceptNotify('Test Data', bytes)) return;
    if (debugRaw) {
      _fire(EegRawNotifyEvent(uuid: EegUuid.testData, bytes: bytes));
    }
  }

  // ---------------------------------------------------------------------------
  // 下行：感知服务（Config Command）
  // ---------------------------------------------------------------------------

  /// 脑电+IMU 配置（0x21）：`{"eeg_imu_config":{...}}`
  Future<void> setEegImuConfig({int? eegHz, int? imuHz, int? duration}) {
    return _sendJson(EegCmd.setEegImuConfig, <String, dynamic>{
      'eeg_imu_config': EegImuConfig(eegHz: eegHz, imuHz: imuHz, duration: duration).toJson(),
    });
  }

  /// 阻抗配置下发（0x22）：`{"imp_config":{"start":1,"duration_s":10}}`
  ///
  /// [start]：0 = 不进行阻抗检测（设备忽略 [durationS]），1 = 开始
  Future<void> setImpedanceConfig({int? start, int? durationS}) {
    return _sendJson(EegCmd.setImpedanceConfig, <String, dynamic>{
      'imp_config': ImpConfig(start: start, durationS: durationS).toJson(),
    });
  }

  /// 阻抗通过标准下发（0x23）：
  /// `{"imp_standard_config":{"imp_standard_kohm":50,"imp_standard_channel":5}}`
  Future<void> setImpedanceStandard({int? maxKohm, int? channel}) {
    return _sendJson(EegCmd.setImpedanceStandard, <String, dynamic>{
      'imp_standard_config': ImpedanceStandard(
        impStandardKohm: maxKohm,
        impStandardChannel: channel,
      ).toJson(),
    });
  }

  /// EEG+IMU 和阻抗测试（0x24）：`{"action":{"imp_duration_s":10,"duration_s":60}}`
  ///
  /// 设备在这段总时长里每隔 [impDurationS] 秒采一次阻抗，其余时间采 EEG+IMU。
  Future<void> setTestAction({int? impDurationS, int? durationS}) {
    return _sendJson(EegCmd.setTestAction, <String, dynamic>{
      'action': EegTestAction(impDurationS: impDurationS, durationS: durationS).toJson(),
    });
  }

  /// ≤ v1.0.12 遗留：触发规则下发（旧 0x24，v1.0.13 起该码位已改为测试命令）
  Future<void> setTriggers(List<EegTrigger> triggers) {
    return _sendJson(EegCmd.legacySetTriggers, <String, dynamic>{
      'triggers': triggers.map((e) => e.toJson()).toList(),
    });
  }

  /// ≤ v1.0.12 遗留：规则配置下发（0x25）
  Future<void> setProfiles(List<EegProfile> profiles) {
    return _sendJson(EegCmd.legacySetProfiles, <String, dynamic>{
      'profiles': profiles.map((e) => e.toJson()).toList(),
    });
  }

  /// ≤ v1.0.12 遗留：整表配置下发（0x26）
  Future<void> setFullConfig(EegConfigPayload payload) {
    return _sendJson(EegCmd.legacySetFullConfig, payload.toJson());
  }

  /// 配置查询（0x27，DATA 为空）
  Future<void> queryConfig() => _sendFrame(EegCmd.queryConfig, '');

  /// 重置设备（0x28）
  Future<void> resetDevice() {
    return _sendJson(EegCmd.reset, <String, dynamic>{'reset': '0'});
  }

  /// 读取当前生效配置快照（Config State），并投递 [EegConfigSnapshotEvent]
  Future<EegConfigPayload?> readConfigSnapshot() async {
    final bytes = await _read(EegUuid.configState);
    if (bytes == null || bytes.isEmpty) return null;

    var merged = <String, dynamic>{};
    var found = false;
    for (final frame in EegConfigFrameDecoder().push(bytes)) {
      final json = frame.json;
      if (json == null) continue;
      merged = <String, dynamic>{...merged, ...json};
      found = true;
    }
    if (!found) {
      // 有些固件直接吐裸 JSON
      final text = String.fromCharCodes(bytes).trim();
      if (text.startsWith('{')) {
        merged = (jsonDecode(text) as Map).cast<String, dynamic>();
        found = true;
      }
    }
    if (!found) return null;

    final payload = EegConfigPayload.fromJson(merged);
    if (payload.eegImu != null) _config = payload.eegImu;
    _fire(EegConfigSnapshotEvent(config: payload));
    return payload;
  }

  // ---------------------------------------------------------------------------
  // 下行：辅助服务
  // ---------------------------------------------------------------------------

  /// 读取错误记录（Error Record）
  Future<List<int>?> readErrorRecord() => _read(EegUuid.errorRecord);

  /// 下发测试命令（Test Command），内容为设备约定的文本 / JSON
  Future<void> sendTestCommand(String text) => _write(EegUuid.testCommand, utf8.encode(text));

  /// 写测试数据（Test Data，回环 / 吞吐测试）
  Future<void> writeTestData(List<int> data) => _write(EegUuid.testData, data);

  // ---------------------------------------------------------------------------
  // 下行：安全服务（身份认证流程）
  // ---------------------------------------------------------------------------

  /// 读取 Device Info（Device ID + 设备证书）
  Future<List<int>?> readDeviceInfo() => _read(EegUuid.deviceInfo);

  /// 下发 Challenge 随机数
  Future<void> writeChallenge(List<int> nonce) => _write(EegUuid.challenge, nonce);

  /// 读取设备对 Challenge 的签名
  Future<List<int>?> readAuthResponse() => _read(EegUuid.authResponse);

  /// 写 ECDH 公钥（会话密钥协商）
  Future<void> writeKeyExchange(List<int> publicKey) => _write(EegUuid.keyExchange, publicKey);

  // ---------------------------------------------------------------------------
  // 时间换算
  // ---------------------------------------------------------------------------

  /// 设备相对时间戳 → 绝对时间；BootID 对不上时返回 null
  DateTime? absoluteTime(int bootId, int deviceTimestampMs) =>
      _anchor?.absolute(bootId, deviceTimestampMs);

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  void _onConnectionState(BlueConnectionState state) {
    final connected = state == BlueConnectionState.connected;
    if (connected) {
      unawaited(bind());
    } else {
      unawaited(unbind());
    }
    _fire(EegConnectionEvent(connected: connected, deviceId: BlueManager.i.connectedDevice?.id));
  }

  Future<void> _subscribe(String uuid, void Function(List<int>) onData, String label) async {
    final c = _chars[BlueUuid.normalize(uuid)];
    if (c == null) {
      _log('设备未提供 $label（$uuid），跳过');
      return;
    }
    if (!c.properties.canNotify) {
      _log('$label 不支持 Notify，跳过');
      return;
    }
    await c.setNotifyValue(true);
    _subs.add(
      c.onValueReceived.listen(
        onData,
        onError: (Object error, StackTrace stack) {
          _log('$label 推送异常：$error');
        },
        cancelOnError: false,
      ),
    );
  }

  /// 下发记录上限（超过丢最老的）
  static const int maxSentRecords = 200;

  /// 最近下发的指令记录（最新的在索引 0），调试页用来回看「APP → 设备」
  ///
  /// 包含配置帧（含 MTU 分包后的每一帧）与裸写特征的字节；
  /// 只记录真正写出去的数据，写入失败不会进来。
  final List<EegSentRecord> sentRecords = <EegSentRecord>[];

  void _recordSent({required String uuid, int? cmd, String? note, required List<int> data}) {
    sentRecords.insert(
      0,
      EegSentRecord(time: DateTime.now(), uuid: uuid, cmd: cmd, note: note, data: data),
    );
    if (sentRecords.length > maxSentRecords) {
      sentRecords.removeRange(maxSentRecords, sentRecords.length);
    }
  }

  Future<void> _sendJson(int cmd, Map<String, dynamic> json) => _sendFrame(cmd, jsonEncode(json));

  /// 封装成配置帧并写入 Config Command（超长自动分包）
  Future<void> _sendFrame(int cmd, String json) async {
    final c = _chars[BlueUuid.normalize(EegUuid.configCommand)];
    if (c == null) {
      throw StateError('未找到 Config Command 特征（${EegUuid.configCommand}），请先连接设备');
    }
    final frames = EegConfigFrameEncoder.encode(cmd, json, mtu: BlueManager.i.mtu);
    for (var i = 0; i < frames.length; i++) {
      // 文档要求 Write With Response（ATT 层自带确认）
      await BlueManager.i.write(frames[i], characteristic: c);
      _recordSent(
        uuid: EegUuid.configCommand,
        cmd: cmd,
        note: frames.length > 1 ? '第 ${i + 1}/${frames.length} 帧' : null,
        data: frames[i],
      );
    }
    _log('下发 ${EegCmd.nameOf(cmd)}：${frames.length} 帧 / ${json.length}B');
  }

  Future<List<int>?> _read(String uuid) async {
    final c = _chars[BlueUuid.normalize(uuid)];
    if (c == null) return null;
    return BlueManager.i.read(characteristic: c);
  }

  Future<void> _write(String uuid, List<int> data) async {
    final c = _chars[BlueUuid.normalize(uuid)];
    if (c == null) {
      throw StateError('未找到特征 $uuid，设备可能未提供对应服务');
    }
    await BlueManager.i.write(data, characteristic: c);
    _recordSent(uuid: uuid, data: data);
  }

  void _fire(EegEvent event) => EventBusManager.i.fire(event);

  void _log(String message) {
    if (enableLog) debugPrint('[EEG] $message');
  }

  /// 打印 `MYB` 前缀的日志（统一前缀，`flutter logs | grep MYB` 一把捞）
  void _logMyb(String message) {
    if (enableLog) debugPrint('MYB $message');
  }
}

/// 一路推送订阅的描述（uuid + 回调 + 日志用名）
///
/// bind / unbind 共用同一份定义，避免两边漏项导致「订阅了却没关」。
class _EegNotifySpec {
  const _EegNotifySpec(this.uuid, this.onData, this.label);

  final String uuid;
  final void Function(List<int>) onData;
  final String label;
}

/// 一条「APP → 设备」的下发记录（调试页回看用）
class EegSentRecord {
  const EegSentRecord({
    required this.time,
    required this.uuid,
    required this.data,
    this.cmd,
    this.note,
  });

  /// 下发时刻（APP 侧）
  final DateTime time;

  /// 目标特征 UUID
  final String uuid;

  /// 配置帧命令字（裸写特征时为 null）
  final int? cmd;

  /// 补充标记，如 MTU 分包的「第 2/3 帧」
  final String? note;

  /// 实际写入的字节
  final List<int> data;

  /// 字节数
  int get length => data.length;
}

/// 全 ASCII 且可打印时转成文本，否则 null
String? _tryText(List<int> bytes) {
  if (bytes.isEmpty) return null;
  for (final b in bytes) {
    if (b < 0x20 || b > 0x7E) return null;
  }
  return String.fromCharCodes(bytes);
}

int? _intOf(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};
