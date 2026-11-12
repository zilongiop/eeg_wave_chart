import 'dart:async';
import 'dart:typed_data';

import '../blue_gatt.dart';
import '../blue_manager.dart';
import 'auth_token_store.dart';
import 'ca_trust_store.dart';
import 'company_ca.dart';
import 'device_certificate.dart';
import 'security_crypto.dart';
import 'security_defs.dart';
import 'security_error.dart';

/// GATT 传输抽象
///
/// 把「读 / 写 / 订阅」抽象出来，认证器不直接依赖 [BlueManager]，
/// 便于单元测试与后期替换通道。
abstract class SecurityTransport {
  /// 读特征值
  Future<List<int>> read(String characteristicUuid);

  /// 写特征值（Write With Response）
  Future<void> write(String characteristicUuid, List<int> data);

  /// 订阅特征推送
  Stream<List<int>> notifications(String characteristicUuid);
}

/// 基于 [BlueManager] 的默认传输实现
///
/// 要求调用前已完成 `BlueManager.i.connect(...)` 并 discover 过服务
/// （`characteristicOf` 依赖已发现的服务列表）。
class BlueManagerSecurityTransport implements SecurityTransport {
  BlueManagerSecurityTransport({BlueManager? manager})
    : _blue = manager ?? BlueManager.i;

  final BlueManager _blue;

  @override
  Future<List<int>> read(String characteristicUuid) async {
    final c = _require(characteristicUuid);
    return _blue.read(characteristic: c);
  }

  @override
  Future<void> write(String characteristicUuid, List<int> data) async {
    final c = _require(characteristicUuid);
    await _blue.write(data, characteristic: c);
  }

  @override
  Stream<List<int>> notifications(String characteristicUuid) {
    final c = _blue.characteristicOf(characteristicUuid);
    if (c == null) return const Stream<List<int>>.empty();
    return c.onValueReceived;
  }

  BlueCharacteristic _require(String uuid) {
    final c = _blue.characteristicOf(uuid);
    if (c == null) {
      throw SecurityException(
        SecurityErrorCode.unauthenticated,
        message: '未发现特征 $uuid，请确认已完成服务发现',
      );
    }
    return c;
  }
}

/// 设备身份（Device Info 读取结果）
class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.certificateDer});

  /// Device ID（32 字节 ASCII）
  final String deviceId;

  /// 设备证书 DER
  final Uint8List certificateDer;
}

/// 认证结果（方案 v1.2）
///
/// v1.2 起会话密钥由**设备**派生，App 不持有、不存储，因此这里不再返回
/// `sessionKey`；认证通过的标志是设备 Auth Status 变为 0x00。
class DeviceAuthResult {
  const DeviceAuthResult({
    required this.deviceId,
    required this.reused,
    this.viaToken = false,
    this.authToken,
    this.generation,
    this.certificate,
  });

  /// Device ID
  final String deviceId;

  /// 是否跳过完整握手（本地令牌免认证 / 设备端会话仍有效）
  final bool reused;

  /// 是否由 24h 本地令牌直接免认证
  final bool viaToken;

  /// 设备签发的 96B 令牌（完整认证成功后读取，可能为 null = 旧固件）
  final Uint8List? authToken;

  /// Device State 代际号，-1 / null 表示旧固件不支持
  final int? generation;

  /// 设备证书；免认证短路时为 null
  final DeviceCertificate? certificate;
}

/// 设备认证器（方案 v1.2 第二层：应用层身份认证 + 门禁）
///
/// 对齐 Android demo `EegAuthEngine.java`（security_service.c / 方案 v1.2）：
/// 1. OS 完成链路层配对加密（App 侧无代码）；
/// 2. 读 Device Info → Device ID + 设备 X.509 证书；
/// 3. 读 Device State → 代际号，与本机记录比对，变化即判定设备被重置、清令牌；
/// 4. 本地 24h Auth Token 写回设备验签，通过则免完整认证；
/// 5. 读 Auth Status == 0x00 则设备端会话有效，同样短路；
/// 6. CA 校验证书（签发 / 有效期 / CN == Device ID）；
/// 7. 写 32B Challenge → 读 64B `r‖s` → ECDSA P-256 + SHA-256 验签；
/// 8. 生成临时 ECDH 密钥对，写 65B `04‖X‖Y` 公钥，**由设备派生会话密钥**；
/// 9. 等 Auth Status 0x00（通知 + 读回兜底 + 重写公钥重试），放开业务门禁；
/// 10. 读回设备签发的 96B Auth Token 持久化，24h 内重连免完整认证。
///
/// BLE 业务数据保持明文帧，加密由第一层 OS 链路负责；App 侧**不做** AES-GCM。
class DeviceAuthenticator {
  DeviceAuthenticator({
    required this.transport,
    AuthTokenStore? tokenStore,
    SecurityConfig? config,
    CaTrustStore? trustStore,
    this.logger,
  }) : _tokenStore = tokenStore ?? PrefsAuthTokenStore(),
       _config = config ?? SecurityConfig(),
       _trustStore = trustStore ?? _defaultTrustStore(config);

  /// GATT 传输
  final SecurityTransport transport;

  /// 日志输出（为空不打印）
  final void Function(String message)? logger;

  final AuthTokenStore _tokenStore;
  final SecurityConfig _config;
  final CaTrustStore _trustStore;

  /// 当前配置
  SecurityConfig get config => _config;

  static CaTrustStore _defaultTrustStore(SecurityConfig? config) {
    final ca = config?.caPublicKey ?? CompanyCa.publicKey;
    return ca == null ? const DenyAllCaTrustStore() : SingleCaTrustStore(ca);
  }

  // ---------------------------------------------------------------------------
  // 对外 API
  // ---------------------------------------------------------------------------

  /// 确保已认证
  ///
  /// v1.2 不再靠「本地会话密钥」判断能否免认证：令牌是否仍有效只有设备说了算，
  /// 因此每次都进入握手，由内部依次尝试令牌免认证 / 设备端会话短路。
  /// [deviceId] 仅为兼容旧调用签名保留。
  Future<DeviceAuthResult> ensureAuthenticated({String? deviceId}) =>
      authenticate();

  /// 完整认证（跳过所有本地缓存，直接走 CA + Challenge 流程）
  Future<DeviceAuthResult> authenticate({bool forceFull = false}) async {
    for (var attempt = 1; attempt <= _config.maxRetries; attempt++) {
      try {
        return await _runHandshake(forceFull: forceFull);
      } on SecurityException catch (e) {
        _log('认证失败（第 $attempt/${_config.maxRetries} 次）：$e');
        if (attempt >= _config.maxRetries) {
          throw SecurityException(
            SecurityErrorCode.authRetryExceeded,
            message: '已重试 $_attempts 次仍未通过认证',
            cause: e,
          );
        }
      } on TimeoutException catch (e) {
        _log('认证超时（第 $attempt/${_config.maxRetries} 次）：$e');
        if (attempt >= _config.maxRetries) {
          throw SecurityException(
            SecurityErrorCode.authRetryExceeded,
            message:
                '已重试 $_attempts 次，单次超时 ${_config.challengeTimeout.inSeconds}s',
            cause: e,
          );
        }
      } on FormatException catch (e) {
        // 证书 DER 解析失败：直接判为证书校验失败，不再重试
        throw SecurityException(
          SecurityErrorCode.certVerifyFailed,
          message: '设备证书解析失败',
          cause: e,
        );
      } catch (e, stack) {
        // GATT 层错误（0x8E/0x8F/0x90 等）也要能触发重试，不能穿透到上层
        _log('认证异常（第 $attempt/${_config.maxRetries} 次）：$e');
        if (attempt >= _config.maxRetries) {
          throw SecurityException(
            SecurityErrorCode.unauthenticated,
            message: '认证失败：$e',
            cause: e,
            stackTrace: stack,
          );
        }
      }
    }
    throw const SecurityException(SecurityErrorCode.authRetryExceeded);
  }

  int get _attempts => _config.maxRetries;

  /// 作废本地凭据（设备重置 / 解绑 / 换机时调用）
  Future<void> invalidate([String? deviceId]) async {
    if (deviceId == null) {
      await _tokenStore.clearAll();
      return;
    }
    await _tokenStore.clearToken(deviceId);
  }

  // ---------------------------------------------------------------------------
  // 内部：v1.2 握手
  // ---------------------------------------------------------------------------

  Future<DeviceAuthResult> _runHandshake({required bool forceFull}) async {
    // ① Device Info（分片）
    final identity = await _readDeviceInfo().timeout(_config.challengeTimeout);
    final id = identity.deviceId;
    _log('Device ID = $id，证书 ${identity.certificateDer.length}B');

    // ② Device State：代际号变化 = 设备被重置，本地令牌作废
    final generation = await _readDeviceState(id);

    if (!forceFull) {
      // ③ 本地 24h Auth Token 免认证
      final byToken = await _tryTokenAuth(id, generation);
      if (byToken != null) return byToken;

      // ④ 设备端会话仍有效（同连接内重复触发 / 手动重试）
      if (await _isDeviceAuthenticated()) {
        _log('设备端已认证(0x00)，跳过完整认证');
        return DeviceAuthResult(
          deviceId: id,
          reused: true,
          generation: generation,
        );
      }
    }

    // ⑤ 解析 + CA 校验证书
    final certificate = X509Parser.parse(identity.certificateDer);
    final verify = _trustStore.verify(certificate);
    if (!verify.ok) {
      throw SecurityException(
        verify.error ?? SecurityErrorCode.certVerifyFailed,
        message: verify.message,
      );
    }
    if (_config.verifySubjectCn && !certificate.matchesDeviceId(id)) {
      throw SecurityException(
        SecurityErrorCode.certVerifyFailed,
        message:
            '证书 subject CN(${certificate.subjectCn}) 与 Device ID($id) 不一致',
      );
    }
    _log('证书校验通过：${certificate.subjectCn}');

    // ⑥ Challenge + ECDSA 验签
    final challenge = SecurityCrypto.newChallenge();
    await transport
        .write(SecurityUuid.challenge, challenge)
        .timeout(_config.challengeTimeout);

    final signature = await _readSignature().timeout(_config.challengeTimeout);
    final signatureOk = SecurityCrypto.verifySignatureRaw(
      certificate.publicKey,
      challenge,
      signature,
    );
    if (!signatureOk) {
      throw const SecurityException(
        SecurityErrorCode.signatureVerifyFailed,
        message: '设备对 Challenge 的签名校验不通过',
      );
    }
    _log('Challenge 验签通过');

    // ⑦ Key Exchange：只下发公钥，会话密钥由设备派生
    final keyPair = SecurityCrypto.generateKeyPair();
    final publicKeyBytes = SecurityCrypto.encodePublicKey(keyPair.publicKey);
    final accepted = await _exchangeKeyAndAwaitStatus(publicKeyBytes);
    if (!accepted) {
      throw const SecurityException(
        SecurityErrorCode.unauthenticated,
        message: 'Key Exchange 后设备未上报 Auth Status 0x00，门禁未放开',
      );
    }
    _log('Auth Status 0x00：设备已派生会话密钥并放开门禁');

    // ⑧ 读取并持久化设备签发的 96B 令牌
    final authToken = await _readAuthToken();
    if (authToken != null) {
      await _tokenStore.saveToken(id, authToken);
      _log('已保存设备认证令牌（24h 免完整认证）');
    }
    if (generation != null) {
      await _tokenStore.saveGeneration(id, generation);
    }

    return DeviceAuthResult(
      deviceId: id,
      reused: false,
      authToken: authToken,
      generation: generation,
      certificate: certificate,
    );
  }

  /// 读 Device State，比对代际号；旧固件 / 读取失败时返回 null 并跳过
  Future<int?> _readDeviceState(String deviceId) async {
    List<int> raw;
    try {
      raw = await transport
          .read(SecurityUuid.deviceState)
          .timeout(_config.challengeTimeout);
    } catch (e) {
      _log('无 Device State（旧固件或读取失败），跳过重置检测：$e');
      return null;
    }
    // 文档 4.2：固定 16 字节；读不到 / 长度不足按旧固件降级，不报错
    if (!SecurityDeviceState.isValid(raw)) {
      _log('无有效 Device State（${raw.length}B，需 16B），跳过重置检测');
      return null;
    }
    final generation = SecurityDeviceState.generationOf(raw);
    if (generation == null) {
      _log('Device State 代际号解析失败，跳过重置检测');
      return null;
    }
    final reason = SecurityDeviceState.reasonOf(raw);
    final previous = await _tokenStore.loadGeneration(deviceId);
    _log('Device State：代际=$generation 原因=${SecurityDeviceState.reasonLabel(reason)}'
        ' 本机记录=${previous ?? '无'}');
    if (previous != null && previous != generation) {
      _log('*** 设备已被重置：代际 $previous → $generation，本地凭据作废 ***');
      await _tokenStore.clearToken(deviceId);
      // 文档 10.3：先更新为新代际再做后续判断，否则每次连接都会重复判定重置
      await _tokenStore.saveGeneration(deviceId, generation);
    }
    return generation;
  }

  /// 本地令牌免认证：写 Auth Token → 等设备确认 0x00
  Future<DeviceAuthResult?> _tryTokenAuth(
    String deviceId,
    int? generation,
  ) async {
    final token = await _tokenStore.loadToken(deviceId);
    if (token == null) {
      _log('无有效本地认证令牌（24h 内），走完整认证');
      return null;
    }
    _log('本地令牌有效，写 Auth Token 让设备验签...');
    try {
      await transport
          .write(SecurityUuid.authToken, token)
          .timeout(_config.challengeTimeout);
      if (!await _awaitAuthStatusAccepted()) {
        _log('令牌验证后认证状态非 0x00，清令牌走完整认证');
        await _tokenStore.clearToken(deviceId);
        return null;
      }
      _log('令牌验签通过(0x00)，免完整认证');
      return DeviceAuthResult(
        deviceId: deviceId,
        reused: true,
        viaToken: true,
        authToken: token,
        generation: generation,
      );
    } catch (e) {
      // 0x8E 参数非法 / 0x8F 门禁 / 0x90 令牌失效：一律清令牌转完整认证
      _log('令牌验证失败($e)，清令牌走完整认证');
      await _tokenStore.clearToken(deviceId);
      return null;
    }
  }

  /// 读 Auth Status 判断设备端是否已认证（短超时快速判定）
  Future<bool> _isDeviceAuthenticated() async {
    try {
      final raw = await transport
          .read(SecurityUuid.authStatus)
          .timeout(const Duration(milliseconds: 800));
      final ok = raw.isNotEmpty &&
          (raw[0] & 0xFF) == SecurityAuthStatus.authenticated.code;
      _log(ok ? '读认证状态: 已认证(0x00)' : '读认证状态: 未认证');
      return ok;
    } catch (e) {
      _log('读认证状态失败：$e');
      return false;
    }
  }

  /// 写 Key Exchange → 等 Auth Status 0x00
  ///
  /// 设备可能在 write 期间就 notify 0x00，所以**先挂订阅再写**，否则通知会丢；
  /// 通知偶发丢失时读回 Auth Status 确认，仍未认证则重写公钥重试（对齐 demo）。
  Future<bool> _exchangeKeyAndAwaitStatus(Uint8List publicKey) async {
    final accepted = Completer<bool>();
    StreamSubscription<List<int>>? subscription;
    try {
      subscription = transport.notifications(SecurityUuid.authStatus).listen(
        (bytes) {
          if (!accepted.isCompleted &&
              bytes.isNotEmpty &&
              (bytes[0] & 0xFF) == SecurityAuthStatus.authenticated.code) {
            accepted.complete(true);
          }
        },
        onError: (Object _) {},
      );

      for (var attempt = 1; attempt <= _config.authStatusRetries; attempt++) {
        _log('Key Exchange 尝试 $attempt/${_config.authStatusRetries}');
        await transport
            .write(SecurityUuid.keyExchange, publicKey)
            .timeout(_config.challengeTimeout);

        final notified = await accepted.future.timeout(
          SecurityTiming.authStatusWait,
          onTimeout: () => false,
        );
        if (notified) return true;
        if (await _isDeviceAuthenticated()) return true;

        if (attempt < _config.authStatusRetries) {
          _log('未收到 Auth Status 0x00，重写 Key Exchange 重试...');
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
      }
      return false;
    } finally {
      if (!accepted.isCompleted) accepted.complete(false);
      await subscription?.cancel();
    }
  }

  /// 令牌路径：写 Auth Token 后设备内部验签，轮询读回 Auth Status 判定
  ///
  /// demo 该路径也是「写令牌 → 读状态」，不依赖 notify。
  Future<bool> _awaitAuthStatusAccepted() async {
    for (var i = 0; i < _config.authStatusRetries; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await _isDeviceAuthenticated()) return true;
    }
    return false;
  }

  /// 完整认证成功后读取设备签发的 96B 令牌（旧固件无此特征时返回 null）
  Future<Uint8List?> _readAuthToken() async {
    try {
      final raw = await transport
          .read(SecurityUuid.authToken)
          .timeout(_config.challengeTimeout);
      if (raw.length != SecuritySize.authTokenBytes) {
        _log('Auth Token 长度异常(${raw.length}B)，不保存');
        return null;
      }
      return Uint8List.fromList(raw);
    } catch (e) {
      _log('读取 Auth Token 失败（旧固件可忽略）：$e');
      return null;
    }
  }

  /// 读 Device Info：一次读全并校验「读满总长」
  ///
  /// 文档 2.5 做法 B：系统协议栈自动 READ_BLOB 后一次拿到完整值；
  /// 校验 `data.length >= totalLength`，不够重读一次，仍不够就明确报错。
  /// ⚠️ 拿半张证书去验签会报「CA 签名校验不通过」，被误判成非授权 CA，
  /// 所以这里必须先判长度，再交给 X509Parser / CA 验签。
  Future<DeviceIdentity> _readDeviceInfo() async {
    DeviceInfoFragment? head;
    Uint8List? der;
    var received = 0;

    for (var attempt = 0; attempt < 2; attempt++) {
      final raw = await transport
          .read(SecurityUuid.deviceInfo)
          .timeout(_config.challengeTimeout);
      final fragment = DeviceInfoFragment.parse(raw);
      if (fragment == null) {
        throw SecurityException(
          SecurityErrorCode.certVerifyFailed,
          message: 'Device Info 返回格式非法（${raw.length}B）',
        );
      }
      head ??= fragment;
      received = fragment.data.length;
      if (fragment.index == 0 && received >= fragment.totalLength) {
        der = Uint8List.fromList(
          fragment.data.sublist(0, fragment.totalLength),
        );
        break;
      }
      _log('证书未读全（${received}B/${fragment.totalLength}B），重读一次');
    }

    final first = head;
    if (first == null || der == null) {
      throw SecurityException(
        SecurityErrorCode.deviceInfoIncomplete,
        message:
            'Device Info 读取不完整（收到 ${received}B / 需 '
            '${first?.totalLength ?? 0}B），拒绝用半张证书验签；'
            '请确认协议栈 READ_BLOB 已生效或提升固件 MTU',
      );
    }
    if (first.totalLength > SecuritySize.certMaxBytes) {
      throw SecurityException(
        SecurityErrorCode.certVerifyFailed,
        message:
            '证书总长 ${first.totalLength}B 超过上限 ${SecuritySize.certMaxBytes}B',
      );
    }
    if (first.deviceId.isEmpty) {
      throw const SecurityException(
        SecurityErrorCode.certVerifyFailed,
        message: 'Device Info 未取到 Device ID',
      );
    }
    _log('证书读满 ${der.length}B / ${first.totalLength}B');
    return DeviceIdentity(deviceId: first.deviceId, certificateDer: der);
  }

  /// 读取设备对 Challenge 的 64 字节签名
  Future<Uint8List> _readSignature() async {
    final raw = await transport.read(SecurityUuid.authResponse);
    if (raw.length < SecuritySize.signatureBytes) {
      throw SecurityException(
        SecurityErrorCode.signatureVerifyFailed,
        message:
            'Auth Response 长度不足（${raw.length}B，需 ${SecuritySize.signatureBytes}B）',
      );
    }
    return Uint8List.fromList(raw.take(SecuritySize.signatureBytes).toList());
  }

  void _log(String message) => logger?.call('[BLE-Security] $message');
}
