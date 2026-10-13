import 'dart:typed_data';

/// 真实设备日志的解析结果。
class EegLogData {
  const EegLogData({
    required this.channels,
    required this.sampleRate,
    required this.durationSec,
    required this.skippedFrames,
  });

  /// 每个通道一段 µV 序列，下标 0 对应文件中第一个被选中的通道。
  final List<List<double>> channels;

  final double sampleRate;
  final double durationSec;

  /// 因帧头丢失而跳过的帧数。
  final int skippedFrames;

  int get sampleCount => channels.isEmpty ? 0 : channels.first.length;
}

/// 解析「OnDataReceived」日志里的 EEG 数据包。
///
/// 协议（由实测字节流反推）：
/// ```
/// [10B 帧头] AA 82 69 09 3C FF 00 08 64 00
/// [2400B 数据] 100 个采样点 × 8 通道 × 3 字节（24 位有符号，大端）
/// [2B 尾部]
/// 每帧 2412 字节
/// ```
/// 日志把字节按 BLE 分片写成多行，且每行只放 hex，所以要先拼成连续
/// 字节流再按帧切分；分片边界与帧边界并不对齐。
class EegLogParser {
  const EegLogParser._();

  static const int frameLen = 2412;
  static const int headerLen = 10;
  static const int samplesPerFrame = 100;
  static const int channelCount = 8;

  /// ADC 计数 → µV 的标定系数。
  ///
  /// 由设备的 24 位 ADC 推得：Vref / (增益 × 2^23) = 4.5V / (3 × 8388608)
  /// ≈ 0.1788 µV/LSB。实测通道 7/8 的 5Hz 正弦振幅约 5589 LSB，乘以该系数
  /// 得 999µV，与文件名标注的「1mV」吻合。
  static const double uvPerLsb = 0.1788;

  static final RegExp _hexLine =
      RegExp(r'OnDataReceived\]:([0-9A-Fa-f\-]+)');

  /// 解析日志文本，返回 [wantedChannels]（1 起算的通道号）对应的 µV 序列。
  static EegLogData parse(String text, {List<int>? wantedChannels}) {
    final Uint8List bytes = _extractBytes(text);
    final List<int> want = wantedChannels ?? const <int>[7, 8];

    final List<List<double>> out = List<List<double>>.generate(
      want.length,
      (_) => <double>[],
      growable: false,
    );

    final int frames = bytes.length ~/ frameLen;
    int skipped = 0;

    for (int f = 0; f < frames; f++) {
      final int base = f * frameLen;
      // 帧头丢失的帧无法定位，整帧跳过（实测 302 帧里只有 2 帧如此）。
      if (bytes[base] != 0xAA || bytes[base + 1] != 0x82) {
        skipped++;
        continue;
      }
      for (int s = 0; s < samplesPerFrame; s++) {
        final int o = base + headerLen + s * 24;
        for (int w = 0; w < want.length; w++) {
          final int c = want[w] - 1; // 转成 0 起算
          final int i = o + c * 3;
          out[w].add(_s24(bytes[i], bytes[i + 1], bytes[i + 2]) * uvPerLsb);
        }
      }
    }

    final int n = out.isEmpty ? 0 : out.first.length;
    return EegLogData(
      channels: out,
      sampleRate: 500.0,
      durationSec: n / 500.0,
      skippedFrames: skipped,
    );
  }

  /// 把日志里所有 hex 片段拼成连续字节流。
  static Uint8List _extractBytes(String text) {
    // 先把所有匹配段的字符数统计出来，一次性分配，避免反复扩容。
    int total = 0;
    final List<RegExpMatch> matches = _hexLine.allMatches(text).toList();
    for (final RegExpMatch m in matches) {
      total += m.group(1)!.length;
    }
    // 每 3 个字符（"XX-"）产出 1 字节，末段少一个分隔符。
    final Uint8List buf = Uint8List((total / 3).ceil() + matches.length);
    int w = 0;
    for (final RegExpMatch m in matches) {
      final String seg = m.group(1)!;
      for (int i = 0; i < seg.length; i += 3) {
        if (i + 2 > seg.length) break;
        buf[w++] = _hex2(seg.codeUnitAt(i), seg.codeUnitAt(i + 1));
      }
    }
    return Uint8List.sublistView(buf, 0, w);
  }

  static int _hex2(int hi, int lo) => (_hex1(hi) << 4) | _hex1(lo);

  static int _hex1(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10; // A-F
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10; // a-f
    return 0;
  }

  /// 3 字节大端 → 24 位有符号。
  static double _s24(int b0, int b1, int b2) {
    final int v = (b0 << 16) | (b1 << 8) | b2;
    return (v >= 0x800000 ? v - 0x1000000 : v).toDouble();
  }
}
