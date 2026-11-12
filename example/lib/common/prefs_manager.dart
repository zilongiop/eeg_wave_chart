import 'package:shared_preferences/shared_preferences.dart';

/// `lib/blue/` 用到的本地存储 key
///
/// 上次连接设备（自动回连）与设备认证令牌都按这些 key 存放，令牌还按
/// Device ID 隔离，避免 A 设备的令牌被写到 B 设备上。
abstract final class PrefsKeys {
  static const String bleLastDeviceId = 'ble.last_device.id';
  static const String bleLastDeviceName = 'ble.last_device.name';
  static const String bleLastDeviceTime = 'ble.last_device.time';
  static const String bleAutoReconnectDisabled =
      'ble.auto_reconnect.disabled';

  static const String bleAuthTokenPrefix = 'ble.auth.token.';
  static const String bleAuthTokenTsPrefix = 'ble.auth.token_ts.';
  static const String bleGenerationPrefix = 'ble.auth.generation.';

  static String bleAuthTokenOf(String deviceId) =>
      '$bleAuthTokenPrefix$deviceId';

  static String bleAuthTokenTsOf(String deviceId) =>
      '$bleAuthTokenTsPrefix$deviceId';

  static String bleGenerationOf(String deviceId) =>
      '$bleGenerationPrefix$deviceId';
}

/// 同步读、异步写的轻量本地存储
///
/// `blue/blue_reconnect.dart` 与 `security/auth_token_store.dart` 里的读取
/// 都是同步的（`getString` / `getInt`），因此内部保留一份内存镜像；
/// [init] 之后写入会同时落到 SharedPreferences，重启后仍可恢复。
/// 未调用 [init] 时退化为纯内存，不影响蓝牙扫描 / 连接主流程。
class PrefsManager {
  PrefsManager._();

  /// 单例
  static final PrefsManager i = PrefsManager._();

  final Map<String, Object> _cache = <String, Object>{};
  SharedPreferences? _prefs;

  /// 在 `main()` 里、蓝牙初始化之前调用一次
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    for (final String key in prefs.getKeys()) {
      final Object? value = prefs.get(key);
      if (value != null) _cache[key] = value;
    }
  }

  /// 当前已保存的所有 key（令牌清理时按前缀过滤用）
  Set<String> get keys => _cache.keys.toSet();

  String? getString(String key) => _cache[key] as String?;
  int? getInt(String key) => _cache[key] as int?;
  bool? getBool(String key) => _cache[key] as bool?;

  Future<void> setString(String key, String value) async {
    _cache[key] = value;
    await _prefs?.setString(key, value);
  }

  Future<void> setInt(String key, int value) async {
    _cache[key] = value;
    await _prefs?.setInt(key, value);
  }

  Future<void> setBool(String key, bool value) async {
    _cache[key] = value;
    await _prefs?.setBool(key, value);
  }

  Future<void> remove(String key) async {
    _cache.remove(key);
    await _prefs?.remove(key);
  }

  Future<void> removeAll(Iterable<String> keys) async {
    for (final String key in keys) {
      await remove(key);
    }
  }
}
