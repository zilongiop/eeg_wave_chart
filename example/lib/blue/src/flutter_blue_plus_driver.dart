import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../blue_defs.dart';
import '../blue_device.dart';
import '../blue_driver.dart';
import '../blue_exception.dart';
import '../blue_gatt.dart';
import '../blue_scan_result.dart';
import '../blue_utils.dart';

/// 基于 flutter_blue_plus 的默认驱动
///
/// 这是 core/blue 中**唯一** import flutter_blue_plus 的文件。
/// 后期要替换插件时：新写一个 `BlueDriver` 实现，并在
/// `BlueManager.i.init(driver: XxxDriver())` 中传入，本文件即可删除。
///
/// flutter_blue_plus 版本：2.3.x
class FlutterBluePlusDriver implements BlueDriver {
  FlutterBluePlusDriver();

  @override
  String get name => 'flutter_blue_plus';

  @override
  Future<bool> isSupported() => fbp.FlutterBluePlus.isSupported;

  @override
  Future<void> turnOn() => fbp.FlutterBluePlus.turnOn();

  @override
  Stream<BlueAdapterState> get adapterState =>
      fbp.FlutterBluePlus.adapterState.map(_toAdapterState);

  @override
  Stream<bool> get isScanning => fbp.FlutterBluePlus.isScanning;

  @override
  Stream<List<BlueScanResult>> get scanResults => fbp
      .FlutterBluePlus
      .scanResults
      .map((results) => results.map(_toScanResult).toList(growable: false));

  @override
  Stream<BlueConnectionEvent> get connectionEvents =>
      fbp.FlutterBluePlus.events.onConnectionStateChanged.map(
        (event) => BlueConnectionEvent(
          device: _FbpDevice(event.device),
          state: _toConnectionState(event.connectionState),
        ),
      );

  @override
  Future<void> startScan({
    Duration? timeout,
    List<String>? serviceUuids,
    bool continuousUpdates = true,
    bool androidUsesFineLocation = false,
  }) {
    return fbp.FlutterBluePlus.startScan(
      withServices: serviceUuids?.map(_guid).toList() ?? const <fbp.Guid>[],
      timeout: timeout,
      continuousUpdates: continuousUpdates,
      androidUsesFineLocation: androidUsesFineLocation,
    );
  }

  @override
  Future<void> stopScan() => fbp.FlutterBluePlus.stopScan();

  @override
  BlueDevice deviceFromId(String remoteId) =>
      _FbpDevice(fbp.BluetoothDevice.fromId(remoteId));

  @override
  Future<List<BlueDevice>> systemDevices({List<String>? serviceUuids}) async {
    final devices = await fbp.FlutterBluePlus.systemDevices(
      serviceUuids?.map(_guid).toList() ?? const <fbp.Guid>[],
    );
    return devices
        .map((device) => _FbpDevice(device) as BlueDevice)
        .toList(growable: false);
  }

  @override
  Future<void> configure({
    bool restoreState = false,
    BlueLogLevel logLevel = BlueLogLevel.warning,
  }) async {
    // 插件默认 LogLevel.debug，Android 原生层会为每条 notify 打两条 DEBUG 日志
    // （onCharacteristicChanged / chr: …）。Sensor Data 高频推送时直接刷屏，
    // 这里降到 warning：只保留警告与错误，需要时可用 setLogLevel 开回 debug。
    await setLogLevel(logLevel);

    // iOS / macOS CoreBluetooth State Restoration：对应
    // CBCentralManagerOptionRestoreIdentifierKey。
    // 注意插件里 identifier 是写死的 "flutterBluePlusRestoreIdentifier"，
    // 只暴露一个 bool 开关，无法自定义标识。
    // 其他平台没有这套机制，setOptions 无对应语义，跳过。
    if (!Platform.isIOS && !Platform.isMacOS) return;

    await fbp.FlutterBluePlus.setOptions(restoreState: restoreState);
  }

  @override
  Future<void> setLogLevel(BlueLogLevel level) =>
      fbp.FlutterBluePlus.setLogLevel(_toLogLevel(level));

  static fbp.LogLevel _toLogLevel(BlueLogLevel level) => switch (level) {
    BlueLogLevel.none => fbp.LogLevel.none,
    BlueLogLevel.error => fbp.LogLevel.error,
    BlueLogLevel.warning => fbp.LogLevel.warning,
    BlueLogLevel.info => fbp.LogLevel.info,
    BlueLogLevel.debug => fbp.LogLevel.debug,
    BlueLogLevel.verbose => fbp.LogLevel.verbose,
  };

  // ---- 类型映射 ----

  static fbp.Guid _guid(String uuid) => fbp.Guid(uuid);

  static BlueAdapterState _toAdapterState(fbp.BluetoothAdapterState state) {
    switch (state) {
      case fbp.BluetoothAdapterState.unknown:
        return BlueAdapterState.unknown;
      case fbp.BluetoothAdapterState.unavailable:
        return BlueAdapterState.unavailable;
      case fbp.BluetoothAdapterState.unauthorized:
        return BlueAdapterState.unauthorized;
      case fbp.BluetoothAdapterState.turningOn:
        return BlueAdapterState.turningOn;
      case fbp.BluetoothAdapterState.on:
        return BlueAdapterState.on;
      case fbp.BluetoothAdapterState.turningOff:
        return BlueAdapterState.turningOff;
      case fbp.BluetoothAdapterState.off:
        return BlueAdapterState.off;
    }
  }

  static BlueConnectionState _toConnectionState(
    fbp.BluetoothConnectionState state,
  ) => state == fbp.BluetoothConnectionState.connected
      ? BlueConnectionState.connected
      : BlueConnectionState.disconnected;

  static fbp.License _toLicense(BlueLicense? license) =>
      license == BlueLicense.commercial
      ? fbp.License.commercial
      : fbp.License.nonprofit;

  static BlueScanResult _toScanResult(fbp.ScanResult result) {
    final adv = result.advertisementData;
    return BlueScanResult(
      device: _FbpDevice(result.device),
      name: _displayName(result.device.platformName, adv.advName),
      rssi: result.rssi,
      advertisement: BlueAdvertisement(
        advName: adv.advName,
        serviceUuids: adv.serviceUuids
            .map((uuid) => uuid.toString())
            .toList(growable: false),
        serviceData: adv.serviceData.map(
          (uuid, bytes) => MapEntry<String, List<int>>(uuid.toString(), bytes),
        ),
        manufacturerData: adv.manufacturerData,
        txPowerLevel: adv.txPowerLevel,
        connectable: adv.connectable,
      ),
      timeStamp: result.timeStamp,
    );
  }

  /// 展示名：优先广播名，其次平台名
  static String _displayName(String platformName, String advName) =>
      advName.isNotEmpty
      ? advName
      : (platformName.isNotEmpty ? platformName : '未知设备');
}

/// flutter_blue_plus 的设备实现
class _FbpDevice implements BlueDevice {
  _FbpDevice(this._raw);

  final fbp.BluetoothDevice _raw;

  @override
  String get id => _raw.remoteId.toString();

  @override
  String get name => _raw.platformName;

  @override
  bool get isConnected => _raw.isConnected;

  @override
  Stream<BlueConnectionState> get connectionState =>
      _raw.connectionState.map(FlutterBluePlusDriver._toConnectionState);

  @override
  Future<void> connect({
    Duration? timeout,
    int? mtu,
    BlueLicense? license,
    bool autoConnect = false,
  }) => _raw.connect(
    timeout: timeout ?? const Duration(seconds: 15),
    // flutter_blue_plus 有 `assert((mtu == null) || !autoConnect)`：
    // autoConnect 与 mtu 互斥，自动连接时必须传 null，
    // 连上后由 BlueManager 补一次 requestMtu。
    mtu: autoConnect ? null : (mtu ?? 517),
    license: FlutterBluePlusDriver._toLicense(license),
    autoConnect: autoConnect,
  );

  @override
  Future<void> disconnect() => _raw.disconnect();

  @override
  Future<List<BlueService>> discoverServices() async {
    final services = await _raw.discoverServices();
    return services
        .map(
          (service) => BlueService(
            uuid: service.uuid.toString(),
            characteristics: service.characteristics
                .map((c) => _FbpCharacteristic(c) as BlueCharacteristic)
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
  }

  @override
  Stream<int> get mtu => _raw.mtu;

  @override
  Future<int> requestMtu(int desiredMtu) => _raw.requestMtu(desiredMtu);

  @override
  Stream<void> get servicesReset => _raw.onServicesReset;

  @override
  String toString() => 'BlueDevice(${_raw.remoteId})';
}

/// flutter_blue_plus 的特征实现
class _FbpCharacteristic implements BlueCharacteristic {
  _FbpCharacteristic(this._raw);

  final fbp.BluetoothCharacteristic _raw;

  @override
  String get uuid => BlueUuid.normalize(_raw.uuid.toString());

  @override
  String get serviceUuid => BlueUuid.normalize(_raw.serviceUuid.toString());

  @override
  BlueCharacteristicProperties get properties {
    final p = _raw.properties;
    return BlueCharacteristicProperties(
      read: p.read,
      write: p.write,
      writeWithoutResponse: p.writeWithoutResponse,
      notify: p.notify,
      indicate: p.indicate,
    );
  }

  @override
  bool get isNotifying => _raw.isNotifying;

  @override
  Stream<List<int>> get onValueReceived => _raw.onValueReceived;

  @override
  Future<void> setNotifyValue(bool enable) =>
      _att(() => _raw.setNotifyValue(enable), BlueExceptionType.notify);

  @override
  Future<List<int>> read() => _att(_raw.read, BlueExceptionType.read);

  @override
  Future<void> write(List<int> value, {bool withoutResponse = false}) => _att(
    () => _raw.write(value, withoutResponse: withoutResponse),
    BlueExceptionType.write,
  );

  /// 把 flutter_blue_plus 的 GATT 异常转成 [BlueException] 并保留错误码
  ///
  /// 这是 `core/blue` 里唯一知道插件异常类型的地方。上层的门禁拦截
  /// （GATT 0x8F）依赖 [BlueException.gattCode]，所以必须在这里透传，
  /// 不能让原始异常直接冒泡。
  Future<T> _att<T>(Future<T> Function() action, BlueExceptionType type) async {
    try {
      return await action();
    } on fbp.FlutterBluePlusException catch (error, stack) {
      throw BlueException(
        type: type,
        message: _messageOf(type),
        error: error,
        stackTrace: stack,
        gattCode: error.code,
      );
    }
  }

  static String _messageOf(BlueExceptionType type) => switch (type) {
    BlueExceptionType.read => '读取特征值失败',
    BlueExceptionType.write => '写入特征值失败',
    _ => '开启 / 关闭推送失败',
  };

  @override
  String toString() => 'BlueCharacteristic(${_raw.uuid})';
}
