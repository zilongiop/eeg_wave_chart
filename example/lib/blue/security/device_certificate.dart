import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'der.dart';
import 'security_crypto.dart';
import 'security_defs.dart';

// ===========================================================================
// Device Info（7A4F2C51）首包解析
// ===========================================================================

/// Device Info 特征读取的返回值（offset = 0）
///
/// 文档协议：
/// `Device ID(32B) + 证书总长度(2B big-endian) + 分片序号(1B) + 证书数据`
///
/// 313B 证书 + 35B 头超过 MTU-3（244B），依赖系统协议栈自动 READ_BLOB
/// 一次读全。App **必须校验 data.length >= totalLength**，
/// 不够重读一次，仍不够明确报错，绝不拿半张证书去验签。
class DeviceInfoFragment {
  const DeviceInfoFragment({
    required this.deviceId,
    required this.totalLength,
    required this.index,
    required this.data,
  });

  /// Device ID（32 字节 ASCII，尾部 0x00 已去除）
  final String deviceId;

  /// 证书总长度（字节）
  final int totalLength;

  /// 分片序号，从 0 递增
  final int index;

  /// 本片证书数据
  final Uint8List data;

  /// 解析特征返回值，格式非法返回 null
  static DeviceInfoFragment? parse(List<int> bytes) {
    const headerSize = SecuritySize.deviceIdBytes + 3; // 32 + 2 + 1
    if (bytes.length < headerSize) return null;

    final idBytes = bytes.sublist(0, SecuritySize.deviceIdBytes);
    final totalLength =
        (bytes[SecuritySize.deviceIdBytes] << 8) |
        bytes[SecuritySize.deviceIdBytes + 1];
    final index = bytes[SecuritySize.deviceIdBytes + 2];

    return DeviceInfoFragment(
      deviceId: _trimAscii(idBytes),
      totalLength: totalLength,
      index: index,
      data: Uint8List.fromList(bytes.sublist(headerSize)),
    );
  }

  @override
  String toString() =>
      'DeviceInfoFragment($deviceId, #$index, ${data.length}B/$totalLength)';
}

/// 去掉尾部 0x00 与空白后转 ASCII
String _trimAscii(List<int> bytes) {
  var end = bytes.length;
  while (end > 0 && bytes[end - 1] == 0x00) {
    end--;
  }
  return String.fromCharCodes(bytes.sublist(0, end)).trim();
}

// ===========================================================================
// X.509 设备证书解析
// ===========================================================================

/// 解析后的 X.509 设备证书
///
/// 只取安全通信需要的字段：TBS 原始字节（CA 验签输入）、
/// ECC P-256 公钥、有效期、subject CN（应等于 Device ID）、序列号。
class DeviceCertificate {
  const DeviceCertificate({
    required this.der,
    required this.tbsBytes,
    required this.publicKey,
    required this.signature,
    required this.serialNumber,
    this.subjectCn,
    this.notBefore,
    this.notAfter,
  });

  /// 证书 DER 原始字节
  final Uint8List der;

  /// TBSCertificate 的完整 TLV 编码（CA 签名的输入）
  final Uint8List tbsBytes;

  /// 设备 ECC P-256 公钥（来自 subjectPublicKeyInfo）
  final ECPublicKey publicKey;

  /// CA 对 TBS 的 ECDSA 签名
  final ECSignature signature;

  /// 序列号
  final Uint8List serialNumber;

  /// subject CN（文档约定 = Device ID）
  final String? subjectCn;

  /// 生效时间
  final DateTime? notBefore;

  /// 失效时间
  final DateTime? notAfter;

  /// 在 [now] 时刻是否处于有效期之外
  bool isExpiredAt(DateTime now) {
    final end = notAfter;
    if (end != null && now.isAfter(end)) return true;
    final start = notBefore;
    if (start != null && now.isBefore(start)) return true;
    return false;
  }

  /// subject CN 是否与 [deviceId] 一致
  ///
  /// 对齐 Android demo `cn.trim().equalsIgnoreCase(id)`：证书 CN 常带尾空格，
  /// 或与 Device ID 大小写不一致，原来严格的 `==` 会把合法设备误判为不合格。
  bool matchesDeviceId(String deviceId) {
    final cn = subjectCn?.trim();
    return cn != null &&
        cn.toLowerCase() == deviceId.trim().toLowerCase();
  }

  /// 序列号 hex（调试 / 日志用）
  String get serialHex => SecurityHex.encode(serialNumber);

  @override
  String toString() =>
      'DeviceCertificate(cn: $subjectCn, serial: $serialHex, '
      'valid: ${notBefore?.toIso8601String()} ~ ${notAfter?.toIso8601String()})';
}

/// X.509 DER 解析器
///
/// 只解析验证所需字段，不实现完整 X.509（扩展 / CRL / 证书链）校验。
/// 量产若引入完整 PKI，替换本类即可。
abstract final class X509Parser {
  /// 解析证书 DER；格式非法抛 [FormatException]
  static DeviceCertificate parse(Uint8List der) {
    final cert = DerReader(der).readNode();
    if (cert.tag != DerTag.sequence) {
      throw const FormatException('X.509 顶层应为 SEQUENCE');
    }
    final top = cert.children;
    if (top.length < 3) {
      throw const FormatException(
        'X.509 字段不足（需 tbsCertificate / '
        'signatureAlgorithm / signatureValue）',
      );
    }

    final tbs = top[0];
    final signature = _parseSignature(top[2]);

    final fields = tbs.children;

    // 按结构特征定位字段，避免受 version / issuerUniqueID 等可选字段影响
    final serialNumber = _locate(
      fields,
      (DerNode f) => f.tag == DerTag.integer,
      'serialNumber',
    ).content;
    final validity = _locate(fields, _looksLikeValidity, 'validity');
    final spki = _locate(fields, _looksLikeSpki, 'subjectPublicKeyInfo');

    // subject 恒为 SPKI 的前一个字段（RFC 5280 顺序）
    final spkiIndex = fields.indexOf(spki);
    if (spkiIndex <= 0) {
      throw const FormatException(
        'X.509 subject 位于 subjectPublicKeyInfo 之前，但索引非法',
      );
    }
    final subject = fields[spkiIndex - 1];

    final validityFields = validity.children;
    if (validityFields.length < 2) {
      throw const FormatException('X.509 validity 字段不足');
    }

    return DeviceCertificate(
      der: der,
      tbsBytes: Uint8List.fromList(tbs.encoded),
      publicKey: _parseEcPublicKey(spki),
      signature: signature,
      serialNumber: Uint8List.fromList(serialNumber),
      subjectCn: _findCommonName(subject),
      notBefore: validityFields[0].asTime,
      notAfter: validityFields[1].asTime,
    );
  }

  /// 按谓词在 TBSCertificate 字段中定位，找不到则抛异常
  static DerNode _locate(
    List<DerNode> fields,
    bool Function(DerNode) test,
    String fieldName,
  ) {
    for (final field in fields) {
      if (test(field)) return field;
    }
    throw FormatException('X.509 缺少 $fieldName 字段');
  }

  /// validity：子节点恰好是两个时间类型的 SEQUENCE
  static bool _looksLikeValidity(DerNode node) {
    if (node.tag != DerTag.sequence) return false;
    final children = node.children;
    return children.length == 2 &&
        DerTag.isTime(children[0].tag) &&
        DerTag.isTime(children[1].tag);
  }

  /// subjectPublicKeyInfo：`SEQUENCE { AlgorithmIdentifier(id-ecPublicKey), BIT STRING }`
  static bool _looksLikeSpki(DerNode node) {
    if (node.tag != DerTag.sequence) return false;
    final children = node.children;
    if (children.length != 2 || children[1].tag != DerTag.bitString) {
      return false;
    }
    final algorithm = children[0];
    if (algorithm.tag != DerTag.sequence) return false;
    final algorithmFields = algorithm.children;
    return algorithmFields.isNotEmpty &&
        algorithmFields[0].asOid == _oidEcPublicKey;
  }

  /// 解析 `signatureValue`（BIT STRING 内的 `SEQUENCE { r, s }`）
  static ECSignature _parseSignature(DerNode bitString) {
    final content = bitString.content;
    if (content.isEmpty) {
      throw const FormatException('X.509 signatureValue 为空');
    }
    // 跳过 BIT STRING 首字节「未使用位数」
    final sigSeq = DerReader(Uint8List.sublistView(content, 1)).readNode();
    final ints = sigSeq.children;
    if (ints.length < 2) {
      throw const FormatException('ECDSA 签名应含 r、s 两个 INTEGER');
    }
    return ECSignature(ints[0].asInteger, ints[1].asInteger);
  }

  /// 解析 subjectPublicKeyInfo → ECC P-256 公钥
  static ECPublicKey _parseEcPublicKey(DerNode spki) {
    final fields = spki.children;
    if (fields.length < 2) {
      throw const FormatException('subjectPublicKeyInfo 字段不足');
    }
    final algorithm = fields[0].children;
    if (algorithm.isEmpty) {
      throw const FormatException('subjectPublicKeyInfo 缺少算法标识');
    }
    if (algorithm[0].asOid != _oidEcPublicKey) {
      throw const FormatException(
        '设备证书公钥算法不是 id-ecPublicKey（$_oidEcPublicKey）',
      );
    }
    if (algorithm.length > 1 && algorithm[1].asOid != _oidPrime256v1) {
      throw const FormatException(
        '设备证书公钥曲线不是 prime256v1 / P-256（$_oidPrime256v1）',
      );
    }
    return SecurityCrypto.decodePublicKey(fields[1].asBitString);
  }

  /// 在 Name 中查找 CommonName（OID 2.5.4.3）
  static String? _findCommonName(DerNode name) {
    for (final rdn in name.children) {
      for (final atv in rdn.children) {
        final parts = atv.children;
        if (parts.length < 2) continue;
        if (parts[0].asOid != _oidCommonName) continue;
        return String.fromCharCodes(parts[1].content);
      }
    }
    return null;
  }

  /// id-ecPublicKey
  static const String _oidEcPublicKey = '1.2.840.10045.2.1';

  /// prime256v1（P-256 / secp256r1）
  static const String _oidPrime256v1 = '1.2.840.10045.3.1.7';

  /// CommonName
  static const String _oidCommonName = '2.5.4.3';
}
