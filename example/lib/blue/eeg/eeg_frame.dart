import 'dart:convert';
import 'dart:typed_data';

import 'eeg_cmd.dart';

/// 帧头
const int eegFrameHeader = 0xAA;

/// 帧尾
const int eegFrameFooter = 0x55;

/// 异或校验工具
///
/// 配置帧：只覆盖 DATA 段，不含 CMD / 帧头 / 帧尾；
/// 数据帧：从 Length 字段到数据区末尾。
abstract final class EegXor {
  /// 逐字节异或，空数据返回 0x00
  static int of(List<int> bytes) {
    var value = 0;
    for (final b in bytes) {
      value ^= b & 0xFF;
    }
    return value & 0xFF;
  }
}

/// 配置帧：AA | CMD(1) | DATA(ASCII JSON) | XOR(1) | 55
///
/// ```dart
/// final frame = EegConfigFrame(
///   cmd: EegCmd.setEegImuConfig,
///   data: utf8.encode('{"eeg_hz":250}'),
/// );
/// await blue.write(frame.encode(), characteristic: configCommand);
/// ```
class EegConfigFrame {
  const EegConfigFrame({required this.cmd, this.data = const <int>[]});

  /// 命令字，见 [EegCmd]
  final int cmd;

  /// DATA 段：ASCII JSON 字节（不含帧头帧尾与校验）
  final List<int> data;

  /// DATA 文本（ASCII / UTF-8 解码）
  String get text => data.isEmpty ? '' : String.fromCharCodes(data);

  /// DATA 解析成 JSON 对象，失败返回 null
  Map<String, dynamic>? get json {
    if (data.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 编码成完整帧（含帧头 / 命令字 / 校验 / 帧尾）
  Uint8List encode() => Uint8List.fromList(<int>[
    eegFrameHeader,
    cmd & 0xFF,
    ...data,
    EegXor.of(data),
    eegFrameFooter,
  ]);

  @override
  String toString() => 'EegConfigFrame(${EegCmd.nameOf(cmd)}, ${text.length}B)';
}

/// 配置帧编码器：JSON → 一帧或多帧（超长自动分包）
abstract final class EegConfigFrameEncoder {
  /// 编码
  ///
  /// - [json]：ASCII JSON 文本（不含结束符）
  /// - [mtu]：当前连接 MTU，默认 247
  ///
  /// ATT 层单包可用载荷为 `MTU-3`，再扣掉 `AA / CMD / XOR / 55` 共 4 字节，
  /// 故单帧 DATA 上限 = `mtu - 7`。超出时按该上限切成多帧，
  /// **每帧都是完整帧**（各自带帧头帧尾与校验），设备端需自行重组。
  static List<Uint8List> encode(int cmd, String json, {int mtu = 247}) {
    final data = utf8.encode(json);
    final maxData = mtu - 3 - 4;
    if (maxData <= 0) {
      throw ArgumentError.value(mtu, 'mtu', 'MTU 过小，无法封装配置帧');
    }

    if (data.length <= maxData) {
      return <Uint8List>[EegConfigFrame(cmd: cmd, data: data).encode()];
    }

    final frames = <Uint8List>[];
    for (var offset = 0; offset < data.length; offset += maxData) {
      final end = (offset + maxData > data.length)
          ? data.length
          : offset + maxData;
      frames.add(
        EegConfigFrame(cmd: cmd, data: data.sublist(offset, end)).encode(),
      );
    }
    return frames;
  }
}

/// 配置帧流式解码器：notify 字节流 → 完整帧
///
/// DATA 为 ASCII（不含 0xAA / 0x55），因此可以用帧头帧尾定界；
/// 校验失败整帧丢弃（文档约定由应用层超时重传兜底）。
///
/// ```dart
/// final decoder = EegConfigFrameDecoder();
/// for (final frame in decoder.push(notifyBytes)) {
///   debugPrint('${EegCmd.nameOf(frame.cmd)} ${frame.text}');
/// }
/// ```
class EegConfigFrameDecoder {
  /// 缓冲区上限，防止设备异常时无限堆积
  static const int maxBuffer = 64 * 1024;

  final List<int> _buffer = <int>[];
  final List<EegConfigFrame> _frames = <EegConfigFrame>[];

  /// 喂入字节，返回本次解析出的完整帧（可能为空）
  List<EegConfigFrame> push(List<int> bytes) {
    _buffer.addAll(bytes);
    if (_buffer.length > maxBuffer) _buffer.clear();
    _frames.clear();

    while (_buffer.isNotEmpty) {
      final start = _buffer.indexOf(eegFrameHeader);
      if (start < 0) {
        _buffer.clear();
        break;
      }
      if (start > 0) _buffer.removeRange(0, start);

      // 至少要有 AA + CMD
      if (_buffer.length < 2) break;

      final cmd = _buffer[1];
      final end = _buffer.indexOf(eegFrameFooter, 2);
      if (end < 0) break; // 等帧尾

      final body = _buffer.sublist(2, end); // DATA + XOR
      _buffer.removeRange(0, end + 1);

      if (body.isEmpty) continue; // 异常帧：没有 XOR 字节
      final data = body.sublist(0, body.length - 1);
      if (EegXor.of(data) != body.last) continue; // 校验失败：丢弃

      _frames.add(EegConfigFrame(cmd: cmd, data: data));
    }

    return List<EegConfigFrame>.unmodifiable(_frames);
  }

  /// 清空缓冲（断开重连时调用）
  void reset() {
    _buffer.clear();
    _frames.clear();
  }
}
