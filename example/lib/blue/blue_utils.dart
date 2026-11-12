/// BLE 常用小工具（与插件无关）
library;

/// UUID 处理
///
/// 统一以「小写字符串」描述 UUID，屏蔽不同插件的类型差异
/// （flutter_blue_plus 使用 `Guid`、多数插件使用 `String`、大小写也可能不同）。
///
/// ```dart
/// BlueUuid.equals('6E400001-B5A3-F393-E0A9-E50E24DCCA9E', BlueUuid.nusService); // true
/// ```
class BlueUuid {
  const BlueUuid._();

  /// Nordic UART Service（NUS）服务 UUID
  ///
  /// 多数 BLE 串口模块（HC-08 / JDY / nRF52 等）使用的透传服务。
  static const String nusService = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

  /// NUS RX：主机写入通道
  static const String nusRx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

  /// NUS TX：设备推送通道
  static const String nusTx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

  /// 归一化：去除空白并转小写
  static String normalize(String uuid) => uuid.trim().toLowerCase();

  /// 比较两个 UUID 是否相同（忽略大小写与空白）
  static bool equals(String a, String b) => normalize(a) == normalize(b);
}

/// 字节数组转十六进制字符串，如 `AA 0A 08 …`
///
/// ```dart
/// BlueHex.format([0xAA, 0x0A]); // 'AA 0A'
/// ```
class BlueHex {
  const BlueHex._();

  /// [limit] 为最多展示的字节数，超出部分以 `… (N 字节)` 结尾
  static String format(List<int> bytes, {int? limit}) {
    final shown = (limit != null && bytes.length > limit) ? bytes.take(limit).toList() : bytes;
    final buffer = StringBuffer();
    for (final b in shown) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    if (bytes.length > shown.length) {
      buffer.write(' … (${bytes.length} 字节)-(${shown.length} 字节)');
    }
    return buffer.toString();
  }
}
