import 'security_defs.dart';

/// 安全通信异常
///
/// 携带文档第 6 章的 [SecurityErrorCode]，便于上层直接映射到 UI 提示。
class SecurityException implements Exception {
  const SecurityException(
    this.code, {
    this.message,
    this.cause,
    this.stackTrace,
  });

  /// 错误码
  final SecurityErrorCode code;

  /// 补充说明（可选）
  final String? message;

  /// 原始异常（可选）
  final Object? cause;

  /// 原始堆栈（可选）
  final StackTrace? stackTrace;

  /// 是否为「需要重新走完整认证」的错误
  bool get needsReauth =>
      code == SecurityErrorCode.unauthenticated ||
      code == SecurityErrorCode.authRetryExceeded ||
      code == SecurityErrorCode.certExpired;

  /// 是否为「认证重试已超限，应断开连接」
  bool get shouldDisconnect => code == SecurityErrorCode.authRetryExceeded;

  @override
  String toString() {
    final buffer = StringBuffer('SecurityException(0x')
      ..write(code.code.toRadixString(16).padLeft(2, '0'))
      ..write(' ${code.label}');
    final text = message;
    if (text != null && text.isNotEmpty) {
      buffer
        ..write(': ')
        ..write(text);
    }
    final error = cause;
    if (error != null) {
      buffer
        ..write(' (cause: ')
        ..write(error)
        ..write(')');
    }
    return buffer.toString();
  }
}

/// GATT 层门禁拒绝异常
///
/// 未认证时访问 data / sensing / aux / ota，设备返回 0x8F；
/// 本地令牌失效时返回 0x90。两者都要转入认证流程，**不按传输失败处理**。
class SecurityGateException extends SecurityException {
  const SecurityGateException({String? message, super.cause})
    : super(
        SecurityErrorCode.unauthenticated,
        message: message ?? '设备门禁拒绝：未认证',
      );
}

/// 是否为「需要重新认证」的 GATT 应用错误码（0x8F / 0x90）
bool isGateRejected(int? gattErrorCode) =>
    gattErrorCode == gattErrorNotAuthenticated ||
    gattErrorCode == gattErrorTokenInvalid;

/// 令牌已被设备判为失效（0x90）：清本地令牌后走完整认证
bool isTokenInvalid(int? gattErrorCode) =>
    gattErrorCode == gattErrorTokenInvalid;

/// 参数非法（0x8E）：写入长度 / 格式问题，按普通失败处理
bool isInvalidArgument(int? gattErrorCode) =>
    gattErrorCode == gattErrorInvalidArgument;
