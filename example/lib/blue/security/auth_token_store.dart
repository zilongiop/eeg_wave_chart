import 'dart:convert';
import 'dart:typed_data';

import '../../common/prefs_manager.dart';
import 'security_defs.dart';

/// 方案 v1.2：设备签发的 96B 认证令牌与设备代际号的本地存储
///
/// 令牌由设备签发、App 只做持久化；24h 内重连时写回 Auth Token 特征，
/// 由设备验签通过后即可免完整认证。所有 key 都按 Device ID 隔离，
/// 避免 A 设备的令牌被用到 B 设备上。
abstract class AuthTokenStore {
  /// 读取未过期的令牌；过期 / 脏数据返回 null
  Future<Uint8List?> loadToken(String deviceId);

  /// 保存令牌并刷新签发时刻
  Future<void> saveToken(String deviceId, Uint8List token);

  /// 清除该设备的令牌（0x90 令牌失效、设备重置时用）
  Future<void> clearToken(String deviceId);

  /// 本机记录的该设备代际号，null = 无记录
  Future<int?> loadGeneration(String deviceId);

  /// 记录代际号，作为下次判断「设备是否被重置」的基线
  Future<void> saveGeneration(String deviceId, int generation);

  /// 清空全部令牌 / 时间戳 / 代际号
  Future<void> clearAll();
}

/// 基于 [PrefsManager] 的实现
///
/// ⚠️ 令牌以 base64 明文存于 SharedPreferences（样机联调阶段）。
/// 量产时换实现注入 DeviceAuthenticator 即可，例如 Keychain / Keystore。
class PrefsAuthTokenStore implements AuthTokenStore {
  PrefsAuthTokenStore({PrefsManager? prefs}) : _prefs = prefs ?? PrefsManager.i;

  final PrefsManager _prefs;

  @override
  Future<Uint8List?> loadToken(String deviceId) async {
    final ts = _prefs.getInt(PrefsKeys.bleAuthTokenTsOf(deviceId));
    if (ts == null ||
        DateTime.now().millisecondsSinceEpoch - ts >=
            SecurityTiming.authTokenTtl.inMilliseconds) {
      return null;
    }
    final encoded = _prefs.getString(PrefsKeys.bleAuthTokenOf(deviceId));
    if (encoded == null) return null;
    try {
      final token = base64Decode(encoded);
      if (token.length != SecuritySize.authTokenBytes) return null;
      return Uint8List.fromList(token);
    } catch (_) {
      await clearToken(deviceId);
      return null;
    }
  }

  @override
  Future<void> saveToken(String deviceId, Uint8List token) async {
    await _prefs.setString(
      PrefsKeys.bleAuthTokenOf(deviceId),
      base64Encode(token),
    );
    await _prefs.setInt(
      PrefsKeys.bleAuthTokenTsOf(deviceId),
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> clearToken(String deviceId) async {
    await _prefs.remove(PrefsKeys.bleAuthTokenOf(deviceId));
    await _prefs.remove(PrefsKeys.bleAuthTokenTsOf(deviceId));
  }

  @override
  Future<int?> loadGeneration(String deviceId) async =>
      _prefs.getInt(PrefsKeys.bleGenerationOf(deviceId));

  @override
  Future<void> saveGeneration(String deviceId, int generation) async {
    if (generation < 0) return;
    await _prefs.setInt(PrefsKeys.bleGenerationOf(deviceId), generation);
  }

  @override
  Future<void> clearAll() async {
    const prefixes = <String>[
      PrefsKeys.bleAuthTokenPrefix,
      PrefsKeys.bleAuthTokenTsPrefix,
      PrefsKeys.bleGenerationPrefix,
    ];
    for (final key in _prefs.keys) {
      if (prefixes.any(key.startsWith)) {
        await _prefs.remove(key);
      }
    }
  }
}
