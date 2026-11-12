/// 蓝牙安全通信：常量与枚举
///
/// 依据《蓝牙认证与设备重置方案 v1.1》/《蓝牙认证流程详解_证书与挑战 v1.0》：
/// * 链路层 SMP 配对加密由 OS 完成，App 不参与；
/// * 设备身份层：X.509 证书 + ECDSA 挑战响应；
/// * 手机授权层：设备签发 96B 凭据（token），App 保存并在 24h 内提交免认证；
/// * 重置识别：读 Device State 的 generation，与本地记录 `!=` 即清凭据。
///
/// ⚠️ **业务数据加密不在本版范围**：设备不回传临时 ECDH 公钥，App 算不出
/// 同一共享秘密，因此本文件不含 AES-GCM / HKDF / 会话密钥相关定义。
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../eeg/eeg_uuid.dart';

/// 安全服务（Security Service）UUID
///
/// UUID 定义收敛在 `eeg/eeg_uuid.dart`，这里按需转出，避免同一 UUID 两处维护。
abstract final class SecurityUuid {
  /// Security Service
  static const String service = EegUuid.securityService;

  /// Device Info（35B 头 + 证书 DER，Read / READ_ENCRYPT）
  static const String deviceInfo = EegUuid.deviceInfo;

  /// Challenge（App 下发 32B 随机数，Write / WRITE_ENCRYPT）
  static const String challenge = EegUuid.challenge;

  /// Auth Response（64B RAW `r‖s`，Read + Notify / READ_ENCRYPT）
  static const String authResponse = EegUuid.authResponse;

  /// Key Exchange（App 下发 65B 临时 ECDH 公钥，Write / WRITE_ENCRYPT）
  static const String keyExchange = EegUuid.keyExchange;

  /// Auth Status（Read + Notify，0x00 = 已认证且门禁放开）
  static const String authStatus = EegUuid.authStatus;

  /// Auth Token（设备签发 96B 凭据，Read / Write）
  static const String authToken = EegUuid.authToken;

  /// Device State（16B，Read 明文 + Indicate）
  static const String deviceState = EegUuid.deviceState;
}

/// 时序与重试
abstract final class SecurityTiming {
  /// 单步超时：5 秒（与设备端「单步 5s 超时」对齐）
  static const Duration challengeTimeout = Duration(seconds: 5);

  /// 等待 Auth Status 通知的超时
  static const Duration authStatusTimeout = Duration(seconds: 5);

  /// 认证重试上限：3 次，超过断开连接
  static const int maxRetries = 3;

  /// 凭据有效期：24 小时（由手机侧计时，设备不判过期）
  static const Duration authTokenTtl = Duration(hours: 24);

  /// Key Exchange 后等待 Auth Status 0x00 的单次超时
  static const Duration authStatusWait = Duration(seconds: 2);

  /// 通知丢失时「读回确认 + 重写 Key Exchange」的重试次数
  static const int authStatusRetries = 3;
}

/// 长度常量（字节）
abstract final class SecuritySize {
  /// Challenge 长度：32 字节安全随机数
  static const int challengeBytes = 32;

  /// ECDSA P-256 签名长度：64 字节 `r ‖ s`（各 32 字节 big-endian）
  static const int signatureBytes = 64;

  /// Device ID 长度：32 字节，不足补 0x00
  static const int deviceIdBytes = 32;

  /// Device Info 单包证书数据上限：244 字节（MTU 247 - 3B 头）
  static const int certFragmentMax = 244;

  /// 证书总长上限（设备侧 cert_storage 分区限制）
  static const int certMaxBytes = 2048;

  /// 设备签发的凭据长度：96 字节 = DeviceID(32) + 签名(64)
  static const int authTokenBytes = 96;

  /// Device State 固定长度：16 字节
  static const int deviceStateMinBytes = 16;

  /// 生成临时 EC 私钥时的随机字节长度（P-256 阶长）
  static const int ecdhSecretBytes = 32;

  /// 未压缩 EC 点长度：`04 ‖ X ‖ Y`
  static const int ecPointBytes = 65;
}

/// 认证状态码（Auth Status 特征首字节）
///
/// `0x00 = 已认证且会话有效`、`0x01 = 未认证 / 认证中`、`0x03 = 认证失败`。
enum SecurityAuthStatus {
  /// 0x00 已认证（门禁放开）
  authenticated(0x00, '已认证'),

  /// 0x01 未认证 / 认证进行中
  unauthenticated(0x01, '未认证'),

  /// 0x02 认证中（兼容旧固件）
  authenticating(0x02, '认证中'),

  /// 0x03 认证失败
  failed(0x03, '认证失败'),

  /// 0x04 凭据无效（设备返回 GATT 0x90）
  tokenInvalid(0x04, '凭据无效');

  const SecurityAuthStatus(this.code, this.label);

  /// 状态码
  final int code;

  /// 中文名
  final String label;

  /// 是否已认证（门禁放开）
  bool get isAuthenticated => this == authenticated;

  /// 按 code 映射，未知 code 视为 [unauthenticated]
  static SecurityAuthStatus fromCode(int? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return unauthenticated;
  }
}

/// Device State（7A4F2C57，固定 16 字节，明文）
///
/// `ver | reason | flags | rsv | generation(LE32) | rsv[8]`。
/// generation 与本地记录不相等即判定设备被重置，本地凭据必须作废。
/// 判断用 `!=`，不能用 `>`：整片擦除会让 generation 归 0。
abstract final class SecurityDeviceState {
  /// 固定长度
  static const int minLength = SecuritySize.deviceStateMinBytes;

  static const int offsetVersion = 0;
  static const int offsetReason = 1;
  static const int offsetFlags = 2;
  static const int offsetGeneration = 4;

  /// flags bit0：正在 reset 中
  static const int flagResetting = 0x01;

  /// 长度是否足够解析
  static bool isValid(List<int> bytes) => bytes.length >= minLength;

  /// 读取 LE32 代际号；长度不足返回 null
  static int? generationOf(List<int> bytes) {
    if (bytes.length < offsetGeneration + 4) return null;
    return (bytes[offsetGeneration] & 0xFF) |
        ((bytes[offsetGeneration + 1] & 0xFF) << 8) |
        ((bytes[offsetGeneration + 2] & 0xFF) << 16) |
        ((bytes[offsetGeneration + 3] & 0xFF) << 24);
  }

  /// 是否收到「设备正在 reset」的 indication
  static bool isResetting(List<int> bytes) =>
      bytes.length > offsetFlags &&
      (bytes[offsetFlags] & flagResetting) != 0;

  /// 重置原因原始值
  static int reasonOf(List<int> bytes) =>
      bytes.length > offsetReason ? bytes[offsetReason] & 0xFF : 0;

  /// 重置原因文案（与设备端枚举一致）
  static String reasonLabel(int reason) => switch (reason) {
    1 => '解绑',
    2 => '恢复出厂',
    3 => '远程指令',
    _ => '无/未知',
  };
}

/// 错误码枚举
enum SecurityErrorCode {
  /// 0x00 无错误
  none(0x00, '无错误'),

  /// 0x01 未认证（门禁拒绝）
  unauthenticated(0x01, '未认证（门禁拒绝）'),

  /// 0x02 证书校验失败（CA 验签 / CN / 曲线 / 长度）
  certVerifyFailed(0x02, '证书校验失败'),

  /// 0x03 证书过期
  certExpired(0x03, '证书过期'),

  /// 0x04 签名验证失败（ECDSA P-256 验签不通过）
  signatureVerifyFailed(0x04, '签名验证失败'),

  /// 0x05 Challenge 超时（5 秒）
  challengeTimeout(0x05, 'Challenge 超时'),

  /// 0x06 认证重试超限（3 次后断开）
  authRetryExceeded(0x06, '认证重试超限'),

  /// 0x07 设备读取不完整（证书没读满总长）
  deviceInfoIncomplete(0x07, 'Device Info 读取不完整');

  const SecurityErrorCode(this.code, this.label);

  /// 错误码
  final int code;

  /// 中文名
  final String label;

  /// 按 code 映射，未知 code 视为 [unauthenticated]
  static SecurityErrorCode fromCode(int? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return unauthenticated;
  }
}

/// GATT 应用错误码（设备端 security_service.c，0x80~0x9F 自定义区间）
///
/// * 0x8E 参数非法：写入长度 / 格式不对，不要重试
/// * 0x8F 未认证门禁：未认证时访问 data / sensing / aux / ota 统一返回
/// * 0x90 凭据失效：设备被重置 / 换盐，本地凭据作废后走完整认证
///
/// 0x88 已被《EEG+IMU 协议》电量回复 CmdType 占用，故不使用。
const int gattErrorInvalidArgument = 0x8E;
const int gattErrorNotAuthenticated = 0x8F;
const int gattErrorTokenInvalid = 0x90;

/// 安全模块配置
class SecurityConfig {
  SecurityConfig({
    this.challengeTimeout = SecurityTiming.challengeTimeout,
    this.authStatusTimeout = SecurityTiming.authStatusTimeout,
    this.maxRetries = SecurityTiming.maxRetries,
    this.authStatusRetries = SecurityTiming.authStatusRetries,
    this.caPublicKey,
    this.verifySubjectCn = true,
  });

  /// 单步超时
  final Duration challengeTimeout;

  /// 等待 Auth Status 通知的超时
  final Duration authStatusTimeout;

  /// 认证重试上限
  final int maxRetries;

  /// Key Exchange 后等待 Auth Status 0x00 的重试次数
  final int authStatusRetries;

  /// 公司 CA 公钥（未配置时为 null，认证会 fail-closed）
  final ECPublicKey? caPublicKey;

  /// 是否校验证书 subject CN == Device ID
  final bool verifySubjectCn;
}

/// hex / 字节互转小工具
abstract final class SecurityHex {
  /// 字节 → 小写 hex
  static String encode(List<int> bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// hex → 字节（自动忽略空白、冒号、逗号、横线）
  static Uint8List decode(String hex) {
    final clean = hex.replaceAll(RegExp(r'[\s:,\-]'), '').toLowerCase();
    if (clean.length % 2 != 0) {
      throw const FormatException('hex 字符串长度必须为偶数');
    }
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
