import 'package:pointycastle/export.dart';

import 'device_certificate.dart';
import 'security_crypto.dart';
import 'security_defs.dart';

/// 证书校验结果
class CaVerifyResult {
  /// 校验通过
  const CaVerifyResult.ok() : ok = true, error = null, message = null;

  /// 校验失败
  const CaVerifyResult.fail(this.error, [this.message]) : ok = false;

  /// 是否通过
  final bool ok;

  /// 失败时的错误码，通过时为 null
  final SecurityErrorCode? error;

  /// 失败原因说明
  final String? message;

  @override
  String toString() => ok
      ? 'CaVerifyResult(ok)'
      : 'CaVerifyResult(fail: ${error?.label}${message == null ? '' : ' - $message'})';
}

/// 公司 CA 信任库
///
/// App 内置公司 CA 公钥，用来验证设备证书是否由自家 CA 签发，
/// 从而确认「连上的是真设备」而非中间人伪造设备。
abstract class CaTrustStore {
  /// 校验设备证书
  ///
  /// - [cert]：从 Device Info 读出的设备证书
  /// - [now]：校验时刻（便于测试），默认取 [DateTime.now]
  CaVerifyResult verify(DeviceCertificate cert, {DateTime? now});
}

/// 单 CA 信任库（样机 / 量产共用一套根 CA 时使用）
///
/// ```dart
/// CompanyCa.configure('04a1b2...');
/// final store = SingleCaTrustStore(CompanyCa.publicKey!);
/// final result = store.verify(certificate);
/// if (!result.ok) throw SecurityException(result.error!, message: result.message);
/// ```
class SingleCaTrustStore implements CaTrustStore {
  SingleCaTrustStore(this.caPublicKey);

  /// 公司 CA 公钥（ECC P-256）
  final ECPublicKey caPublicKey;

  @override
  CaVerifyResult verify(DeviceCertificate cert, {DateTime? now}) {
    final at = now ?? DateTime.now();

    // 1. 有效期
    if (cert.isExpiredAt(at)) {
      final end = cert.notAfter;
      final start = cert.notBefore;
      return CaVerifyResult.fail(
        SecurityErrorCode.certExpired,
        '证书不在有效期内'
        '${start == null ? '' : '（起 ${start.toIso8601String()}）'}'
        '${end == null ? '' : '（止 ${end.toIso8601String()}）'}',
      );
    }

    // 2. CA 签名：ECDSA P-256 + SHA-256 验签（输入为 TBS 原始字节）
    final signatureOk = SecurityCrypto.verifyEcdsaP256(
      caPublicKey,
      cert.tbsBytes,
      cert.signature,
    );
    if (!signatureOk) {
      return const CaVerifyResult.fail(
        SecurityErrorCode.certVerifyFailed,
        'CA 签名校验不通过，证书可能由非授权 CA 签发',
      );
    }

    return const CaVerifyResult.ok();
  }
}

/// 未配置 CA 公钥时的占位信任库：一律拒绝（fail-closed）
class DenyAllCaTrustStore implements CaTrustStore {
  const DenyAllCaTrustStore();

  @override
  CaVerifyResult verify(DeviceCertificate cert, {DateTime? now}) =>
      const CaVerifyResult.fail(
        SecurityErrorCode.certVerifyFailed,
        '未配置公司 CA 公钥，拒绝一切设备证书',
      );
}
