import 'package:pointycastle/export.dart';

import 'security_crypto.dart';
import 'security_defs.dart';

/// App 内置的公司 CA 公钥（文档第二层「产线 / 公司 CA」）
///
/// 产线为每台设备签发 X.509 设备证书，App 用内置的公司 CA 公钥验证证书，
/// 从而确认「连上的是自家真设备」。
///
/// ## 接入方式
///
/// 在 `main()` 里尽早调用一次（早于任何 BLE 连接）：
///
/// ```dart
/// CompanyCa.configure(
///   '04a1b2c3...', // 130 个 hex 字符 = 65 字节未压缩 EC 点 04||X||Y
/// );
/// ```
///
/// 公钥可用 OpenSSL 从产线 CA 证书中导出：
///
/// ```bash
/// openssl x509 -in ca.pem -pubkey -noout \
///   | openssl ec -pubin -text -noout      # 取 pub 段的 04:xx:xx:...
/// ```
///
/// ⚠️ 未配置时 [publicKey] 返回 `null`，认证会以
/// [SecurityErrorCode.certVerifyFailed] 失败（**fail-closed**，不会放行伪造设备）。
abstract final class CompanyCa {
  /// 已配置的 hex（未配置为空串）
  static String get publicKeyHex => _publicKeyHex;

  static String _publicKeyHex = '';
  static ECPublicKey? _cached;

  /// 写入内置 CA 公钥
  ///
  /// [hex] 为 65 字节未压缩 EC 点的十六进制（`04 ‖ X ‖ Y`，130 个 hex 字符）；
  /// 允许带空格 / 冒号 / 逗号 / 横线分隔。传空串表示清空。
  static void configure(String hex) {
    _publicKeyHex = hex;
    _cached = null;
  }

  /// 解析后的 CA 公钥，未配置或格式非法时为 null
  static ECPublicKey? get publicKey {
    final cached = _cached;
    if (cached != null) return cached;

    final hex = _publicKeyHex.trim();
    if (hex.isEmpty) return null;

    try {
      final parsed = SecurityCrypto.decodePublicKey(SecurityHex.decode(hex));
      _cached = parsed;
      return parsed;
    } catch (_) {
      // 格式非法：保持 null，认证阶段会 fail-closed
      return null;
    }
  }

  /// 是否已配置并解析成功
  static bool get isReady => publicKey != null;
}
