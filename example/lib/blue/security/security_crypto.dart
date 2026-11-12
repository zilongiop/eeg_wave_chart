import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'security_defs.dart';

/// 安全通信密码学门面（方案 v1.1）
///
/// 只保留认证链路实际用到的能力：
/// * ECDSA P-256 + SHA-256 —— CA 证书验签 / Challenge 响应验签
/// * ECDH P-256 临时密钥对 —— 生成并导出 65B 未压缩公钥
///
/// ⚠️ 设备不回传自己的临时公钥，App 算不出共享秘密，**业务数据加密不在本版
/// 范围**。因此这里没有 HKDF / AES-GCM / 会话密钥派生，也不要自行加回来。
abstract final class SecurityCrypto {
  static final Random _random = Random.secure();

  /// P-256 曲线参数（与 `prime256v1` / `secp256r1` 同义）
  static ECDomainParameters get curve => ECCurve_prime256v1();

  // ---------------------------------------------------------------------------
  // 随机数
  // ---------------------------------------------------------------------------

  /// 生成 [length] 字节安全随机数
  ///
  /// 对应文档「安全随机源」：iOS `SecRandomCopyBytes` /
  /// Android `SecureRandom`（`Random.secure()` 即映射到底层平台 CSPRNG）。
  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  /// 生成 32 字节 Challenge（每次认证必须重新生成，不能复用）
  static Uint8List newChallenge() => randomBytes(SecuritySize.challengeBytes);

  // ---------------------------------------------------------------------------
  // EC 密钥
  // ---------------------------------------------------------------------------

  /// 生成临时 ECDH 密钥对（App 每次连接重新生成，写完公钥即可丢弃私钥）
  static AsymmetricKeyPair<ECPublicKey, ECPrivateKey> generateKeyPair() {
    final params = curve;
    final n = params.n;

    BigInt d;
    do {
      d = _randomBigInt(SecuritySize.ecdhSecretBytes);
    } while (d == BigInt.zero || d >= n);

    return AsymmetricKeyPair<ECPublicKey, ECPrivateKey>(
      ECPublicKey(params.G * d, params),
      ECPrivateKey(d, params),
    );
  }

  /// 导出公钥为未压缩点 `04 ‖ X ‖ Y`（65 字节）
  static Uint8List encodePublicKey(ECPublicKey key) {
    final q = key.Q;
    if (q == null) {
      throw ArgumentError('EC 公钥缺少 Q 参数');
    }
    return q.getEncoded(false);
  }

  /// 从未压缩点（65 字节 `04 ‖ X ‖ Y`）解析公钥
  static ECPublicKey decodePublicKey(Uint8List encoded) {
    if (encoded.length != SecuritySize.ecPointBytes) {
      throw ArgumentError.value(
        encoded.length,
        'encoded',
        'EC 点应为 ${SecuritySize.ecPointBytes} 字节',
      );
    }
    final params = curve;
    final q = params.curve.decodePoint(encoded);
    if (q == null) {
      throw const FormatException('EC 点解码失败');
    }
    return ECPublicKey(q, params);
  }

  // ---------------------------------------------------------------------------
  // ECDSA P-256 + SHA-256
  // ---------------------------------------------------------------------------

  /// 把 64 字节 `r ‖ s`（各 32 字节 big-endian）解成 [ECSignature]
  ///
  /// 设备返回的是 RAW 而非 DER；这里直接还原 r/s 交给 pointycastle，
  /// 避免了 RAW→DER 转换里「去前导 0 / 高位补 0」的经典坑。
  static ECSignature decodeSignature(Uint8List raw) {
    if (raw.length != SecuritySize.signatureBytes) {
      throw ArgumentError.value(
        raw.length,
        'raw',
        'ECDSA P-256 签名应为 ${SecuritySize.signatureBytes} 字节',
      );
    }
    final r = _bytesToBigInt(Uint8List.sublistView(raw, 0, 32));
    final s = _bytesToBigInt(Uint8List.sublistView(raw, 32, 64));
    return ECSignature(r, s);
  }

  /// ECDSA P-256 + SHA-256 验签
  ///
  /// - [publicKey]：验签公钥（设备证书公钥 / 公司 CA 公钥）
  /// - [message]：原始消息（证书验签传 TBS 原始字节；Challenge 验签传 Challenge）
  /// - [signature]：`r ‖ s` 形式的签名
  static bool verifyEcdsaP256(
    ECPublicKey publicKey,
    Uint8List message,
    ECSignature signature,
  ) {
    final signer = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(publicKey));
    try {
      return signer.verifySignature(message, signature);
    } catch (_) {
      return false;
    }
  }

  /// `r ‖ s` 字节串直接验签
  static bool verifySignatureRaw(
    ECPublicKey publicKey,
    Uint8List message,
    Uint8List rawSignature,
  ) => verifyEcdsaP256(publicKey, message, decodeSignature(rawSignature));

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  static BigInt _randomBigInt(int byteLength) {
    var value = BigInt.zero;
    for (var i = 0; i < byteLength; i++) {
      value = (value << 8) | BigInt.from(_random.nextInt(256));
    }
    return value;
  }

  /// 定长 big-endian 字节 → BigInt
  static BigInt _bytesToBigInt(Uint8List bytes) {
    var value = BigInt.zero;
    for (final b in bytes) {
      value = (value << 8) | BigInt.from(b & 0xFF);
    }
    return value;
  }
}
