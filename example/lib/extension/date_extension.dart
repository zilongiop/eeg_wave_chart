import '../blue/eeg/eeg_data_frame.dart' show EegTimeAnchor;

/// BLE 日志里用到的时间工具
///
/// `blue_manager.dart` 与 `eeg_service.dart` 打 `MYB recv` 日志时，用它把
/// 0x8B 帧里的设备相对时间戳（BootID + Timestamp）换算成可读时间。
abstract final class DateExtension {
  /// 当前毫秒时间戳
  static int getNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// 帧内时间戳 → 展示文本
  ///
  /// 建立过时间锚点且 BootID 匹配时给出真实时间，否则返回 [fallback]
  /// （通常是 `dev 12345ms` 这样的设备相对时间）。
  static String frameTimestamp(
    int timestampMs, {
    int? bootId,
    EegTimeAnchor? anchor,
    bool withDate = false,
    String fallback = '',
  }) {
    if (anchor == null || bootId == null) return fallback;
    final DateTime? absolute = anchor.absolute(bootId, timestampMs);
    if (absolute == null) return fallback;
    if (withDate) return absolute.toIso8601String();

    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(absolute.hour)}:${two(absolute.minute)}:'
        '${two(absolute.second)}.${three(absolute.millisecond)}';
  }
}
