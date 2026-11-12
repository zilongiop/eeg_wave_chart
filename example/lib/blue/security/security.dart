/// 蓝牙安全通信（方案 v1.1 / 认证流程详解 v1.0）
///
/// 三层各管一件事：
///
/// | 层 | 机制 | 管什么 |
/// | --- | --- | --- |
/// | 链路层 | SMP 配对 + 加密 | 防窃听，不承担授权 |
/// | 设备身份层 | X.509 证书 + ECDSA 挑战响应 | App 确认对面是真设备 |
/// | 手机授权层 | 96B 凭据（token） | 设备确认这台手机此前认证过 |
///
/// ⚠️ **业务数据加密明确不做**：设备不回传自己的临时 ECDH 公钥，App 算不出
/// 同一个共享秘密，会话密钥只有设备侧有。Key Exchange 的作用是完成握手、
/// 触发 Auth Status 0x00，不是真正的密钥协商。因此本模块不含 AES-GCM /
/// HKDF / 会话密钥存储，也不要自行加回来。
///
/// 认证 6 步（全部 GATT 特征直读直写，无 `AA CMD DATA XOR 55` 命令帧）：
///
/// 1. 读 Device Info（35B 头 + 证书 DER，**必须校验读满总长**）
/// 2. 四道校验：CA 验签 / 有效期 / CN == DeviceID / 公钥曲线 P-256
/// 3. 写 32B Challenge（每次重新生成）
/// 4. 读 64B RAW `r‖s` 签名并验签（SHA256withECDSA）
/// 5. 写 65B ECDH 临时公钥 → 等 Auth Status 0x00（通知 + 读回 + 重写重试 3 次）
/// 6. 读 96B 凭据，按 {DeviceID, generation, token, saved_at} 本地保存
///
/// 重置判定：连接后读 Device State（7A4F2C57，16B，明文），generation 与本地
/// 记录 `!=` 即判定设备被重置 → 清凭据 → 走完整认证；读不到特征视为旧固件，
/// 跳过判定。
library;

export 'auth_token_store.dart';
export 'ca_trust_store.dart';
export 'company_ca.dart';
export 'der.dart';
export 'device_authenticator.dart';
export 'device_certificate.dart';
export 'security_crypto.dart';
export 'security_defs.dart';
export 'security_error.dart';
export 'security_switch.dart';
