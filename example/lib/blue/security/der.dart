/// DER（Distinguished Encoding Rules）最小实现
///
/// 只覆盖解析 X.509 证书所需的 TLV 读取能力：
/// 定长长度字段、单层 / 嵌套读取、OID 解码、INTEGER 解码、时间解码。
///
/// 不处理：不定长编码、多字节 tag、BER 宽松规则。
library;

import 'dart:typed_data';

/// DER 标签
abstract final class DerTag {
  /// SEQUENCE（0x30）
  static const int sequence = 0x30;

  /// SET（0x31）
  static const int set = 0x31;

  /// INTEGER（0x02）
  static const int integer = 0x02;

  /// BIT STRING（0x03）
  static const int bitString = 0x03;

  /// OCTET STRING（0x04）
  static const int octetString = 0x04;

  /// OBJECT IDENTIFIER（0x06）
  static const int objectIdentifier = 0x06;

  /// UTCTime（0x17）
  static const int utcTime = 0x17;

  /// GeneralizedTime（0x18）
  static const int generalizedTime = 0x18;

  /// 是否为时间类型（UTCTime / GeneralizedTime）
  static bool isTime(int tag) => tag == utcTime || tag == generalizedTime;

  /// [0] EXPLICIT：X.509 的 version 字段（0xA0）
  static const int context0 = 0xA0;

  /// 是否为「构造类型」（内容可继续拆成 TLV）
  static bool isConstructed(int tag) => (tag & 0x20) != 0;
}

/// 一个 DER TLV 节点
class DerNode {
  const DerNode(this.tag, this.content, this.encoded);

  /// 标签字节
  final int tag;

  /// 内容字节（不含 tag 与长度字段）
  final Uint8List content;

  /// 完整 TLV 字节
  final Uint8List encoded;

  /// 子节点；primitive 类型恒为空列表
  List<DerNode> get children {
    if (!DerTag.isConstructed(tag)) return const <DerNode>[];
    final reader = DerReader(content);
    final list = <DerNode>[];
    while (reader.hasMore) {
      list.add(reader.readNode());
    }
    return list;
  }

  /// 以 INTEGER 解析；内容为空返回 0
  BigInt get asInteger => Der.decodeInteger(content);

  /// 以 OBJECT IDENTIFIER 解析成点分字符串
  String get asOid => Der.decodeOid(content);

  /// 以 BIT STRING 解析（去掉首字节的「未使用位数」）
  Uint8List get asBitString {
    if (content.isEmpty) return Uint8List(0);
    return Uint8List.sublistView(content, 1);
  }

  /// 以时间类型（UTCTime / GeneralizedTime）解析，失败返回 null
  DateTime? get asTime => Der.decodeTime(content);

  @override
  String toString() =>
      'DerNode(0x${tag.toRadixString(16)}, ${content.length}B)';
}

/// DER 顺序读取器
class DerReader {
  DerReader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  /// 是否还有未读数据
  bool get hasMore => _pos < _buf.length;

  /// 当前读取位置
  int get position => _pos;

  /// 读取下一个 TLV 节点
  DerNode readNode() {
    if (_pos >= _buf.length) {
      throw const FormatException('DER 数据不足，无法读取 TLV');
    }
    final start = _pos;
    final tag = _buf[_pos++];
    if ((tag & 0x1F) == 0x1F) {
      throw const FormatException('暂不支持多字节 DER tag');
    }
    final length = _readLength();
    if (_pos + length > _buf.length) {
      throw FormatException(
        'DER 长度越界（声明 $length 字节，剩余 ${_buf.length - _pos} 字节）',
      );
    }
    final content = Uint8List.sublistView(_buf, _pos, _pos + length);
    _pos += length;
    return DerNode(tag, content, Uint8List.sublistView(_buf, start, _pos));
  }

  int _readLength() {
    if (_pos >= _buf.length) {
      throw const FormatException('DER 缺少长度字段');
    }
    final first = _buf[_pos++];
    if (first < 0x80) return first; // 短形式

    final count = first & 0x7F;
    if (count == 0) {
      throw const FormatException('DER 不支持不定长编码');
    }
    if (count > 4) {
      throw FormatException('DER 长度字段过长（$count 字节）');
    }
    var length = 0;
    for (var i = 0; i < count; i++) {
      if (_pos >= _buf.length) {
        throw const FormatException('DER 长度字段不完整');
      }
      length = (length << 8) | _buf[_pos++];
    }
    return length;
  }
}

/// DER 基础类型解码工具
abstract final class Der {
  /// INTEGER → BigInt（按补码处理负数）
  static BigInt decodeInteger(Uint8List content) {
    if (content.isEmpty) return BigInt.zero;
    final negative = (content[0] & 0x80) != 0;
    var value = BigInt.zero;
    for (final b in content) {
      value = (value << 8) | BigInt.from(negative ? (b ^ 0xFF) : b);
    }
    return negative ? -(value + BigInt.one) : value;
  }

  /// OBJECT IDENTIFIER → 点分字符串
  static String decodeOid(Uint8List content) {
    if (content.isEmpty) return '';
    final first = content[0];
    final buffer = StringBuffer()
      ..write(first ~/ 40)
      ..write('.')
      ..write(first % 40);

    var value = BigInt.zero;
    for (var i = 1; i < content.length; i++) {
      value = (value << 7) | BigInt.from(content[i] & 0x7F);
      if ((content[i] & 0x80) == 0) {
        buffer
          ..write('.')
          ..write(value);
        value = BigInt.zero;
      }
    }
    return buffer.toString();
  }

  /// UTCTime（`YYMMDDHHMMSSZ`）或 GeneralizedTime（`YYYYMMDDHHMMSSZ`）
  /// → DateTime，格式不符返回 null
  static DateTime? decodeTime(Uint8List content) {
    final text = String.fromCharCodes(content);
    try {
      if (text.length == 13 && text.endsWith('Z')) {
        final twoDigitYear = int.parse(text.substring(0, 2));
        // RFC 5280：50~99 → 19xx，00~49 → 20xx
        final year = twoDigitYear >= 50
            ? 1900 + twoDigitYear
            : 2000 + twoDigitYear;
        return DateTime.utc(
          year,
          int.parse(text.substring(2, 4)),
          int.parse(text.substring(4, 6)),
          int.parse(text.substring(6, 8)),
          int.parse(text.substring(8, 10)),
          int.parse(text.substring(10, 12)),
        );
      }
      if (text.length == 15 && text.endsWith('Z')) {
        return DateTime.utc(
          int.parse(text.substring(0, 4)),
          int.parse(text.substring(4, 6)),
          int.parse(text.substring(6, 8)),
          int.parse(text.substring(8, 10)),
          int.parse(text.substring(10, 12)),
          int.parse(text.substring(12, 14)),
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
