import 'dart:typed_data';

import 'eeg_frame.dart';

/// 数据帧命令字（《业务流程 v1.0.13》第 7.1 / 7.2 节）
abstract final class EegDataCmd {
  /// 脑电 + IMU 数据帧
  static const int eegImu = 0x8B;

  /// 阻抗**结果**帧（v1.0.9 起）
  ///
  /// 设备端算好 8 通道 kΩ 后组包下发（不再发原始采样），
  /// APP 只做解析，不再做频谱计算。帧格式见 [EegImpedanceFrame]。
  static const int impedance = 0x8C;

  /// 旧协议阻抗**原始采样**帧（≤ v1.0.8）
  ///
  /// 仅用于兼容旧固件与离线日志回放（`impedance_debug_page`）。
  static const int impedanceLegacy = 0x90;

  /// 是否为已知的数据帧命令字
  static bool isValid(int cmd) =>
      cmd == eegImu || cmd == impedance || cmd == impedanceLegacy;
}

/// 小狗状态标签码（7.2 帧的 LabelCode / label 上报的 code）
abstract final class EegLabelCode {
  /// MLC 未就绪：开始采集后约 2s 内填这个值
  static const int notReady = 0xFF;
}

/// Sensor Data 上行的帧（sealed，便于调用方 switch 穷尽）
///
/// * [EegDataFrame]：0x8B 脑电+IMU（含旧协议 0x90 原始阻抗）
/// * [EegImpedanceFrame]：0x8C 阻抗结果
sealed class EegSensorFrame {}

/// 阻抗结果帧（CMD 0x8C，《业务流程 v1.0.13》7.1）
///
/// 帧结构**固定 21 字节、不含 Length 字段**：
/// ```
/// AA | 8C | Data(16) | EleQuantity(1) | XOR(1) | 55
/// ```
/// * Data：CH1~CH8 各 uint16 **小端序**，单位 KΩ，定标 ×10
///   （实际阻抗 = 帧内数值 / 10，例：帧内 1719 → 171.9 kΩ）
/// * Checksum：从 CmdType 到 EleQuantity 顺序异或（不含帧头帧尾）
class EegImpedanceFrame implements EegSensorFrame {
  const EegImpedanceFrame({required this.rawValues, required this.eleQuantity});

  /// 整帧字节数：AA + CMD + Data(16) + EleQuantity + XOR + 55
  static const int frameLength = 21;

  /// Data 段起始下标（AA、CMD 之后）
  static const int dataOffset = 2;

  /// 通道数：CH1~CH8
  static const int channelCount = 8;

  /// 8 通道原始值（定标 ×10）
  final List<int> rawValues;

  /// 电池电量百分比
  final int eleQuantity;

  /// 各通道阻抗（kΩ）：原始值 / 10
  List<double> get kohm =>
      rawValues.map((v) => v / 10.0).toList(growable: false);

  /// 第 [channel] 通道（1 起始）的阻抗（kΩ）；越界返回 null
  double? kohmOf(int channel) {
    final index = channel - 1;
    if (index < 0 || index >= rawValues.length) return null;
    return rawValues[index] / 10.0;
  }

  @override
  String toString() =>
      'EegImpedanceFrame(${rawValues.asMap().entries.map((e) => 'ch${e.key + 1}:${e.value / 10.0}kΩ').join(' ')}, '
      'bat: $eleQuantity%)';
}

/// 采样点在 Data 区的排布方式
///
/// 文档描述为「按通道排列」，实际有两种可能，默认取 [interleaved]
/// （与已解析的真实录波日志一致）；若设备是通道连续存放，改成 [channelMajor]。
enum EegSampleLayout {
  /// 按采样点交错：ch1 ch2 … ch8 | ch1 ch2 … （每点 channelNum×3 字节）
  interleaved,

  /// 按通道连续：ch1 全部采样点 | ch2 全部采样点 …
  channelMajor,
}

/// [Length] 字段的口径（Length 覆盖到哪一段）
///
/// 协议 7.2：Length = 数据帧总长度（不含 Header / CmdType / Footer），
/// 即 `Length(2) + 载荷 + Checksum(1)`；Checksum 又是「从 Length 异或到
/// IMU 记录区末尾」，两者互相印证。早期固件出现过只算载荷的写法，
/// 这里把两种口径显式列出来，不再靠「两个都试一遍」猜。
enum EegLengthScope {
  /// 自动：在 `L-3 / L-2 / L-1 / L` 里挑唯一能通过「帧尾 + 校验 + 结构自洽」的那个
  ///
  /// 协议口径是 [fromLengthToChecksum]（L-3），但固件在「Length 该不该含
  /// 自身 / 校验字节」上常有出入（差 1~3 字节），一旦差了就整帧解不出来，
  /// 表现就是调试页的事件日志里看不到任何 EEG 数据。
  /// 有了 [EegFrameOptions.strictPayload] 的结构自洽校验，多试几个偏移也
  /// 不会误判（载荷长度必须精确等于帧内字段推导值），所以默认用它。
  auto,

  /// Length 从自身起算并含校验字节：`载荷 = Length - 3`（协议 7.2 口径）
  fromLengthToChecksum,

  /// Length 只算载荷：`载荷 = Length`
  payloadOnly,
}

/// 数据帧解析选项
class EegFrameOptions {
  const EegFrameOptions({
    this.endian = Endian.little,
    this.sampleEndian = Endian.big,
    this.layout = EegSampleLayout.interleaved,
    this.lengthScope = EegLengthScope.auto,
    this.strictPayload = true,
    this.keepRawBytes = false,
    this.eegDifferential = true,
  });

  /// **头部**多字节字段（Length / ChannelMask / SampleCount / Timestamp /
  /// BootID / IMURecordCount，以及 IMU 里的 int16、float32）的字节序
  ///
  /// 默认**小端**：真机抓包确认（`AA 8B 26 0A 58 FF 00 08 64 00 5F 35 00 00
  /// 0B 00 FF …`）：
  /// * Length `26 0A` → 0x0A26 = 2598 = 载荷 2595 + 3（协议 L-3 口径）
  /// * SampleCount `64 00` → 100（大端会读成 25600，一帧根本装不下）
  /// * ChannelMask `FF 00` → 0x00FF = 8 通道全开，与 ChannelNum=8 对得上
  /// * Timestamp `5F 35 00 00` → 13663ms；BootID `0B 00` → 11
  /// * IMU 首条 accZ `FB 0F` → 4091 ≈ 1g，重力向量 / 四元数是小端 float
  /// 同理，0x8C 阻抗帧也是小端（见 [_parseImpedanceFrame]）。
  ///
  /// ⚠️ **不含 24 位采样点** —— 那个走 [sampleEndian]，与头部相反。
  final Endian endian;

  /// **24 位采样点**的字节序，默认**大端**
  ///
  /// 协议是「头部小端 + 采样值大端」的混合，两者必须分开配置，
  /// 早先共用一个 [endian] 时根本没法正确表达（只能二选一错一个）。
  /// 大端由真机抓包三条独立判据定死，详见 [_i24]。
  final Endian sampleEndian;

  /// 采样点排布
  final EegSampleLayout layout;

  /// [Length] 字段的口径（默认 [EegLengthScope.auto]，协议口径是 L-3）
  final EegLengthScope lengthScope;

  /// 是否要求「载荷长度 == 由帧内字段推导出的长度」
  ///
  /// 开启后 Length / SampleCount / IMURecordCount 三者必须自洽：
  /// `载荷 = 15 + 采样点×通道×3 + 2 + IMU 条数×45`（0x8B）。
  /// 这能挡掉帧体里「碰巧凑成 0xAA … 0x55 且异或也对」的错误定界，
  /// 也是判断 [lengthScope] 有没有选对的直接依据。
  final bool strictPayload;

  /// 是否把整帧原始字节挂到 [EegDataFrame.raw]（调试页事件日志看整包 HEX 用）
  ///
  /// 默认关：2000Hz 下每帧 2~3 KB，一直留着会白白多占内存。
  final bool keepRawBytes;

  /// 0x8B 帧的 EEG 段是否按**差分压缩格式**解析（协议 v1.1
  /// 《EEG差分压缩方案》：`8 通道块（3B 基准点 + bit 流差值）`）
  ///
  /// 设备端 0x8B **恒为压缩格式**、无兼容标志，所以默认开。
  /// 解压是**无损**的，恢复出的 24bit 原始值与未压缩帧逐点一致，
  /// 之后的 µV 换算不变。
  ///
  /// 置 false 可回退到「逐点 24bit 绝对值」的旧格式（v1.0 固件 / 历史
  /// 录波日志回放联调时用）。
  final bool eegDifferential;

  EegFrameOptions copyWith({
    Endian? endian,
    Endian? sampleEndian,
    EegSampleLayout? layout,
    EegLengthScope? lengthScope,
    bool? strictPayload,
    bool? keepRawBytes,
    bool? eegDifferential,
  }) {
    return EegFrameOptions(
      endian: endian ?? this.endian,
      sampleEndian: sampleEndian ?? this.sampleEndian,
      layout: layout ?? this.layout,
      lengthScope: lengthScope ?? this.lengthScope,
      strictPayload: strictPayload ?? this.strictPayload,
      keepRawBytes: keepRawBytes ?? this.keepRawBytes,
      eegDifferential: eegDifferential ?? this.eegDifferential,
    );
  }
}

/// IMU 记录（每条 45 字节）
///
/// | 字节 | 内容 |
/// | --- | --- |
/// | 1~6 | XYZ 加速度 |
/// | 7~12 | XYZ 陀螺仪 |
/// | 13~14 | 芯片温度 |
/// | 15~16 | 步数计数器 |
/// | 17 | 事件掩码 |
/// | 18~29 | 重力向量（3 × float32） |
/// | 30~45 | 姿态四元数（4 × float32） |
class EegImuRecord {
  const EegImuRecord({
    required this.accX,
    required this.accY,
    required this.accZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
    required this.temperature,
    required this.stepCount,
    required this.eventMask,
    required this.gravity,
    required this.quaternion,
  });

  /// X 轴加速度
  final int accX;

  /// Y 轴加速度
  final int accY;

  /// Z 轴加速度
  final int accZ;

  /// X 轴陀螺仪
  final int gyroX;

  /// Y 轴陀螺仪
  final int gyroY;

  /// Z 轴陀螺仪
  final int gyroZ;

  /// 芯片温度
  final int temperature;

  /// 步数计数器
  final int stepCount;

  /// 事件掩码，位定义见下方各 getter
  final int eventMask;

  /// 重力向量 [x, y, z]
  final List<double> gravity;

  /// 姿态四元数 [w?, x, y, z]（顺序以嵌入式为准）
  final List<double> quaternion;

  /// 单条记录固定 45 字节（协议 7.2：2×6 + 2 + 2 + 1 + 12 + 16）
  static const int size = 45;

  /// 位 0：步数检测器触发
  bool get stepDetected => _bit(0);

  /// 位 1：倾斜检测触发
  bool get tiltDetected => _bit(1);

  /// 位 2：显著运动检测触发
  bool get significantMotion => _bit(2);

  /// 位 3：自由落体触发
  bool get freeFall => _bit(3);

  /// 位 4：唤醒触发
  bool get wakeup => _bit(4);

  /// 位 5：6D 方向改变
  bool get orientationChanged => _bit(5);

  /// 位 6：单击触发
  bool get singleTap => _bit(6);

  /// 位 7：双击触发
  bool get doubleTap => _bit(7);

  bool _bit(int index) => ((eventMask >> index) & 0x01) == 1;

  factory EegImuRecord.fromBytes(List<int> p, int offset, Endian endian) {
    int s16(int i) {
      final v = endian == Endian.big
          ? (p[offset + i] << 8) | p[offset + i + 1]
          : (p[offset + i + 1] << 8) | p[offset + i];
      return v >= 0x8000 ? v - 0x10000 : v;
    }

    double f32(int i) {
      final bytes = Uint8List(4);
      for (var k = 0; k < 4; k++) {
        bytes[k] = p[offset + i + k];
      }
      return ByteData.view(bytes.buffer).getFloat32(0, endian);
    }

    return EegImuRecord(
      accX: s16(0),
      accY: s16(2),
      accZ: s16(4),
      gyroX: s16(6),
      gyroY: s16(8),
      gyroZ: s16(10),
      temperature: s16(12),
      stepCount: endian == Endian.big
          ? (p[offset + 14] << 8) | p[offset + 15]
          : (p[offset + 15] << 8) | p[offset + 14],
      eventMask: p[offset + 16],
      gravity: <double>[f32(17), f32(21), f32(25)],
      quaternion: <double>[f32(29), f32(33), f32(37), f32(41)],
    );
  }
}

/// 设备时间锚点（文档「Timestamp / BootID 说明」）
///
/// 连接建立时设备上报 (BootID, t_now)，APP 以收到该帧的真实时刻 [realTime]
/// 为锚点，同 BootID 内：`T_abs = realTime + (t_frame - deviceTimestampMs)`。
/// 每次连接重新取锚。
class EegTimeAnchor {
  const EegTimeAnchor({
    required this.bootId,
    required this.deviceTimestampMs,
    required this.realTime,
  });

  /// 开机会话号
  final int bootId;

  /// 锚点时刻对应的设备相对时间戳（ms）
  final int deviceTimestampMs;

  /// 锚点对应的真实时间
  final DateTime realTime;

  /// 把设备相对时间戳换算成绝对时间；BootID 不一致时返回 null
  DateTime? absolute(int bootId, int deviceTimestampMs) {
    if (bootId != this.bootId) return null;
    return realTime.add(
      Duration(milliseconds: deviceTimestampMs - this.deviceTimestampMs),
    );
  }

  @override
  String toString() =>
      'EegTimeAnchor(boot: $bootId, t: ${deviceTimestampMs}ms @ $realTime)';
}

/// 当前时间锚点的共享副本
///
/// BLE 层（`BlueManager`）打 MYB 日志时也要把设备时间戳换算成绝对时间，但它
/// 不能反过来依赖 `EegDeviceService` —— 后者依赖 `BlueManager`，会形成循环
/// import。锚点因此在这里存一份：设备服务建立锚点时写入，BLE 层只读。
abstract final class EegTimeAnchorHolder {
  static EegTimeAnchor? current;
}

/// 从一包 notify 字节里窥探 0x8B 帧的 Timestamp / BootID（够打日志用）
///
/// 帧结构 `AA 8B Length(2) | EleQuantity(1) ChannelMask(2) ChannelNum(1)
/// SampleCount(2) Timestamp(4) BootID(2) …`，于是 Timestamp 落在整帧偏移
/// 10~13、BootID 在 14~15；头部是小端（见 [EegFrameOptions.endian]）。
///
/// 分包时只有第一片带帧头，后续分片返回 null；非 0x8B 帧同样返回 null。
({int timestampMs, int bootId})? peekEegFrameTime(List<int> bytes) {
  if (bytes.length < 16) return null;
  if (bytes[0] != eegFrameHeader || bytes[1] != EegDataCmd.eegImu) return null;
  return (
    timestampMs:
        bytes[10] | (bytes[11] << 8) | (bytes[12] << 16) | (bytes[13] << 24),
    bootId: bytes[14] | (bytes[15] << 8),
  );
}

/// 解析出的数据帧（脑电+IMU 0x8B；旧协议原始阻抗 0x90）
class EegDataFrame implements EegSensorFrame {
  const EegDataFrame({
    required this.cmd,
    required this.eleQuantity,
    required this.channelMask,
    required this.channelNum,
    required this.sampleCount,
    required this.timestampMs,
    required this.bootId,
    required this.labelCode,
    required this.channels,
    required this.imu,
    this.raw,
    this.differential = false,
  });

  /// 命令字：0x8B（0x90 为旧协议原始阻抗）
  final int cmd;

  /// 电池电量百分比
  final int eleQuantity;

  /// 通道掩码，每个 bit 表示一个通道是否开启
  final int channelMask;

  /// 有效通道数
  final int channelNum;

  /// 每通道采样点数量
  final int sampleCount;

  /// 本包末尾时刻（设备相对时间戳，ms）；阻抗帧为 0
  final int timestampMs;

  /// 开机会话号；阻抗帧为 0
  final int bootId;

  /// 小狗状态标签码（0x8B 帧，v1.0.8 起随帧下发）
  ///
  /// 表示「本包末尾时刻 MLC 最近一次的稳定分类结果」，精度 2s，
  /// 同一标签会在连续多包重复出现（无需去重）；[EegLabelCode.notReady]
  /// (0xFF) 表示 MLC 未就绪。取值见 [DogState]。
  final int labelCode;

  /// 采样数据：`channels[通道][采样点]`，24 位有符号原始值
  final List<Int32List> channels;

  /// IMU 记录（仅 0x8B 帧）
  final List<EegImuRecord> imu;

  /// 整帧原始字节（含帧头帧尾），仅 [EegFrameOptions.keepRawBytes] 打开时有值
  ///
  /// 分包组装后才有意义：调试页事件日志拿它显示「一整包」的 HEX，
  /// 而不是某个 notify 分片的 HEX。
  final Uint8List? raw;

  /// EEG 段是否由差分压缩解压而来（协议 v1.1）
  ///
  /// 解压是**无损**的：`channels` 里的值与未压缩帧逐点一致，
  /// 这个标记只用于日志 / 结构校验分流，不影响下游 µV 换算。
  final bool differential;

  /// 是否为脑电+IMU 帧
  bool get isEegImu => cmd == EegDataCmd.eegImu;

  /// 是否为阻抗帧（含旧协议 0x90 原始采样）
  bool get isImpedance =>
      cmd == EegDataCmd.impedance || cmd == EegDataCmd.impedanceLegacy;

  /// 本帧的小狗状态是否已就绪（0xFF = 未就绪）
  bool get hasDogState => labelCode != EegLabelCode.notReady;

  /// 本包末尾的绝对时间（需先由 0xAD 上报建立锚点）
  DateTime? absoluteEndTime(EegTimeAnchor? anchor) =>
      anchor?.absolute(bootId, timestampMs);

  /// 脑电样本 i（0 起始）相对包末尾的时间偏移（负数，单位 ms）
  double sampleOffsetMs(int index, int eegHz) {
    if (eegHz <= 0) return 0;
    return -(sampleCount - 1 - index) * 1000.0 / eegHz;
  }

  /// IMU 记录 j（0 起始）相对包末尾的时间偏移（负数，单位 ms）
  double imuOffsetMs(int index, int imuHz) {
    if (imuHz <= 0 || imu.isEmpty) return 0;
    return -(imu.length - index) * 1000.0 / imuHz;
  }

  /// 脑电样本 i（0 起始）的设备时间戳（ms）
  ///
  /// 协议：`t_i = Timestamp - (SampleCount - 1 - i) × 1000 / EEG采样率`
  /// （Timestamp 是本包**末尾**时刻，所以越靠前的样本时间越小）
  double sampleTimeMs(int index, int eegHz) =>
      timestampMs + sampleOffsetMs(index, eegHz);

  /// IMU 记录 j（0 起始）的设备时间戳（ms）
  ///
  /// 协议：`t_j = Timestamp - (M - j) × 1000 / IMU采样率`
  double imuTimeMs(int index, int imuHz) =>
      timestampMs + imuOffsetMs(index, imuHz);

  @override
  String toString() =>
      'EegDataFrame(0x${cmd.toRadixString(16).toUpperCase()}, '
      '${channelNum}ch×${sampleCount}, imu: ${imu.length}, '
      'boot: $bootId, t: ${timestampMs}ms, bat: $eleQuantity%)';
}

/// 数据帧流式解析器：Sensor Data notify 字节流 → 完整数据帧
///
/// 协议 7.2 帧结构：`AA | CMD | Length(2) | 载荷 | Checksum | 55`。
/// 蓝牙 notify 一包最多一个 MTU（20~244 字节），而 2000Hz × 8 通道的
/// 一帧要 2~3 KB，所以**一帧必然被拆成多包下发**，一包里也可能同时带着
/// 上一帧的尾巴和下一帧的头。本类负责把碎片攒成完整帧：
///
/// * **累积**：喂进来的字节先进缓冲，凑够一整帧才吐出来
/// * **定界**：帧头 0xAA → CmdType → Length → 算出整帧长度，字节不够就继续等
/// * **校验**：帧尾 0x55 + Checksum（从 Length 异或到 IMU 记录区末尾），
///   再叠加 [EegFrameOptions.strictPayload] 的结构自洽校验
///   （Length 必须等于 `15 + 采样点×通道×3 + 2 + IMU条数×45`）
/// * **重同步**：任何环节对不上就把当前 0xAA 当假帧头丢掉 1 字节，
///   从下一个 0xAA 重新开始 —— 不会因为一帧损坏把整条流卡死
///
/// ```dart
/// final parser = EegDataFrameParser();
/// for (final frame in parser.push(notifyBytes)) {  // 分包时返回空列表
///   debugPrint('$frame');
/// }
/// ```
class EegDataFrameParser {
  EegDataFrameParser({EegFrameOptions? options})
    : options = options ?? const EegFrameOptions();

  /// 解析选项（可在运行时替换）
  EegFrameOptions options;

  /// 累积缓冲上限：异常时防止无限堆积（满速约 6 KB/s，64 KB 足够几十帧）
  static const int maxBuffer = 64 * 1024;

  /// 单帧字节上限（含帧头帧尾）
  ///
  /// 最大档位估算：AA CMD Length(2) + 头 15 + 采样 250×8×3
  /// + IMURecordCount(2) + 64×45 + XOR + 55 ≈ 9 KB，取 16 KB 留余量。
  /// 超过这个数说明 Length 是脏数据，直接重同步而不是傻等。
  static const int maxFrameBytes = 16 * 1024;

  /// 单帧允许的 EEG 通道数 / 每通道采样点数 / IMU 记录条数上限（脏数据兜底）
  static const int maxChannels = 32;
  static const int maxSampleCount = 4096;
  static const int maxImuRecords = 256;

  final List<int> _buffer = <int>[];

  /// 解析统计（排查「帧一直攒不出来」时先看这里）
  final EegFrameStats stats = EegFrameStats();

  /// 缓冲里当前攒着多少字节（一直涨 = 某帧始终凑不齐）
  int get pendingBytes => _buffer.length;

  /// 喂入一段字节，返回本次攒够的完整帧
  ///
  /// 一帧没凑齐时返回空列表，字节留在缓冲里等下一包 —— 这就是分包组装。
  List<EegSensorFrame> push(List<int> bytes) {
    if (bytes.isEmpty) return const <EegSensorFrame>[];

    _buffer.addAll(bytes);
    stats.receivedBytes += bytes.length;
    if (_buffer.length > maxBuffer) {
      // 异常堆积（一直没能定界成功）：只丢前半段，后半段更可能含完整帧
      final drop = _buffer.length - maxBuffer ~/ 2;
      _buffer.removeRange(0, drop);
      stats.overflowBytes += drop;
    }

    final frames = <EegSensorFrame>[];
    while (_buffer.isNotEmpty) {
      final start = _buffer.indexOf(eegFrameHeader);
      if (start < 0) {
        // 一段字节里连一个帧头都没有：全是残帧，丢掉重新同步
        stats.droppedBytes += _buffer.length;
        _buffer.clear();
        break;
      }
      if (start > 0) {
        // 帧头前面的垃圾字节（上一帧尾巴损坏后的残留）
        _buffer.removeRange(0, start);
        stats.droppedBytes += start;
        continue;
      }

      final result = _parseAtHead();
      switch (result.kind) {
        case _ParseKind.needMore:
          // 分包场景的正常出口：还差尾巴，等下一包
          stats.incomplete++;
          return frames;
        case _ParseKind.invalid:
          // 这个 0xAA 不是帧头，或帧尾 / 校验 / 结构对不上：
          // 丢 1 字节重新同步，不再死等
          _buffer.removeRange(0, 1);
          stats.resyncs++;
          stats.droppedBytes += 1;
          continue;
        case _ParseKind.ok:
          frames.add(result.frame!);
          stats.frames++;
          _buffer.removeRange(0, result.consumed);
          continue;
      }
    }
    return frames;
  }

  /// 清空缓冲（断开重连时调用）
  void reset() {
    _buffer.clear();
    stats.resets++;
  }

  _ParseResult _parseAtHead() {
    final b = _buffer;
    // AA CMD Length(2)：至少这 4 字节到手，才知道整帧有多长
    if (b.length < 4) return _ParseResult.needMore();

    final cmd = b[1];
    if (!EegDataCmd.isValid(cmd)) return _ParseResult.invalid();

    // 0x8C 阻抗结果帧：固定 21 字节、无 Length 字段，单独解析
    if (cmd == EegDataCmd.impedance) return _parseImpedanceFrame();

    final length = _u16(b, 2, options.endian);
    final ordered = _lengthCandidates(length);

    // 过滤掉明显是脏数据的候选（长度非正 / 超过单帧上限）
    final candidates = ordered
        .where((p) => p > 0 && (4 + p + 2) <= maxFrameBytes)
        .toList(growable: false);
    if (candidates.isEmpty) return _ParseResult.invalid();

    // 显式口径：只看主口径收齐没有 —— 收齐还全对不上就是坏帧，立即重同步。
    // auto：只要还有候选没收齐就再等等，固件口径可能差 1~3 字节，
    // 提前判死会把一整帧丢掉（表现就是调试页看不到 EEG 数据）。
    final judgeOnPrimaryOnly = options.lengthScope != EegLengthScope.auto;
    final primaryComplete = b.length >= 4 + candidates.first + 2;
    var anyIncomplete = false;

    for (final payloadLen in candidates) {
      final total = 4 + payloadLen + 2; // AA CMD Length(2) + 载荷 + XOR + 55
      if (b.length < total) {
        anyIncomplete = true; // 分包中：还差尾巴
        continue;
      }
      if (b[total - 1] != eegFrameFooter) continue;
      // Checksum：从 Length 异或到 IMU 记录区末尾（协议 7.2）
      if (EegXor.of(b.sublist(2, 4 + payloadLen)) != b[total - 2]) continue;

      final frame = _decode(
        cmd,
        b.sublist(4, 4 + payloadLen),
        raw: options.keepRawBytes
            ? Uint8List.fromList(b.sublist(0, total))
            : null,
      );
      if (frame == null) continue;
      if (options.strictPayload && !_payloadMatches(frame, payloadLen)) {
        continue;
      }

      return _ParseResult.ok(frame, total);
    }
    final waitMore = judgeOnPrimaryOnly ? !primaryComplete : anyIncomplete;
    return waitMore ? _ParseResult.needMore() : _ParseResult.invalid();
  }

  /// 按 [EegFrameOptions.lengthScope] 列出候选载荷长度（命中由校验说了算）
  List<int> _lengthCandidates(int length) => switch (options.lengthScope) {
    EegLengthScope.auto => <int>[length - 3, length - 2, length - 1, length],
    EegLengthScope.fromLengthToChecksum => <int>[length - 3, length],
    EegLengthScope.payloadOnly => <int>[length, length - 3],
  };

  /// 载荷长度是否与帧内字段自洽（[EegFrameOptions.strictPayload]）
  ///
  /// 0x8B：`EleQuantity(1) + ChannelMask(2) + ChannelNum(1) + SampleCount(2)
  /// + Timestamp(4) + BootID(2) + LabelCode(1) + 采样点(N×3)
  /// + IMURecordCount(2) + IMU 记录(M×45)`
  static bool _payloadMatches(EegDataFrame f, int payloadLen) {
    // 差分压缩帧：EEG 段长度由 bit 流决定，无法从帧头字段预判
    //（`采样点×通道×3` 不再成立）。结构自洽已由 _decode 内的
    //「解压 + IMU 段恰好耗尽载荷」保证，这里直接放行。
    if (f.differential) return true;
    var expected = 1 + 2 + 1 + 2;
    if (f.isEegImu) expected += 4 + 2 + 1;
    expected += f.sampleCount * f.channels.length * 3;
    if (f.isEegImu) expected += 2 + f.imu.length * EegImuRecord.size;
    return expected == payloadLen;
  }

  /// 解析 0x8C 阻抗结果帧：`AA | 8C | Data(16) | EleQuantity | XOR | 55`
  _ParseResult _parseImpedanceFrame() {
    final b = _buffer;
    const total = EegImpedanceFrame.frameLength;
    if (b.length < total) return _ParseResult.needMore();
    if (b[total - 1] != eegFrameFooter) return _ParseResult.invalid();

    // 校验：从 CmdType 到 EleQuantity（b[1] ~ b[18]）
    if (EegXor.of(b.sublist(1, 19)) != b[19]) return _ParseResult.invalid();

    // Data：8 通道 uint16 小端（文档明确小端，与 options.endian 无关）
    // 偏移：AA(0) CMD(1) Data(2~17) EleQuantity(18) XOR(19) 55(20)
    final values = List<int>.generate(
      EegImpedanceFrame.channelCount,
      (i) =>
          (b[EegImpedanceFrame.dataOffset + i * 2 + 1] << 8) |
          b[EegImpedanceFrame.dataOffset + i * 2],
      growable: false,
    );

    return _ParseResult.ok(
      EegImpedanceFrame(rawValues: values, eleQuantity: b[18]),
      total,
    );
  }

  EegDataFrame? _decode(int cmd, List<int> p, {Uint8List? raw}) {
    final e = options.endian;
    if (p.length < 6) return null;

    var offset = 0;
    final eleQuantity = p[offset++];
    final channelMask = _u16(p, offset, e);
    offset += 2;
    final channelNumRaw = p[offset++];
    final sampleCount = _u16(p, offset, e);
    offset += 2;

    var timestampMs = 0;
    var bootId = 0;
    var labelCode = EegLabelCode.notReady;
    if (cmd == EegDataCmd.eegImu) {
      if (p.length < offset + 7) return null;
      timestampMs = _u32(p, offset, e);
      offset += 4;
      bootId = _u16(p, offset, e);
      offset += 2;
      // v1.0.8 起：BootID 之后紧跟 1 字节 LabelCode（0xFF = 未就绪）
      labelCode = p[offset++];
    }

    final channelCount = channelNumRaw > 0
        ? channelNumRaw
        : _popCount(channelMask);
    // 上限兜底：Length 定界错了的时候这些值会离谱，直接判非法走重同步
    if (channelCount <= 0 || channelCount > maxChannels) return null;
    if (sampleCount <= 0 || sampleCount > maxSampleCount) return null;

    /// 0x8B 差分压缩（协议 v1.1）：EEG 段 = 掩码置位数个通道块
    ///（3B 基准点 + bit 流差值），长度可变、由解压耗尽决定。
    /// 0x90 / 旧格式回放走下面的逐点 24bit 绝对值路径。
    var differential = false;
    var reportedChannels = channelCount;
    late final List<Int32List> channels;

    if (cmd == EegDataCmd.eegImu && options.eegDifferential) {
      // 通道块数 = 掩码置位数（协议 §9.5：不得硬编码 8，按掩码解析）
      final maskBlocks = _popCount(channelMask);
      final blocks = maskBlocks > 0 ? maskBlocks : channelCount;
      final decoded = EegDifferentialCodec.decode(
        p,
        offset,
        blocks,
        sampleCount,
      );
      if (decoded == null) return null;
      channels = decoded.$1;
      offset += decoded.$2;
      differential = true;
      reportedChannels = blocks;
    } else {
      final dataBytes = sampleCount * channelCount * 3;
      if (p.length < offset + dataBytes) return null;

      channels = List<Int32List>.generate(
        channelCount,
        (_) => Int32List(sampleCount),
        growable: false,
      );
      final interleaved = options.layout == EegSampleLayout.interleaved;
      for (var s = 0; s < sampleCount; s++) {
        for (var c = 0; c < channelCount; c++) {
          final at = interleaved
              ? offset + (s * channelCount + c) * 3
              : offset + (c * sampleCount + s) * 3;
          // 采样点走 [EegFrameOptions.sampleEndian]（大端），与头部相反
          channels[c][s] = _i24(p, at, options.sampleEndian);
        }
      }
      offset += dataBytes;
    }

    // IMURecordCount(2) + IMU 记录(M × 45)，按时间先后排列
    final imu = <EegImuRecord>[];
    if (cmd == EegDataCmd.eegImu) {
      if (p.length < offset + 2) {
        // 没有 IMURecordCount：严格模式判非法，宽松模式按 0 条处理
        if (options.strictPayload) return null;
      } else {
        final count = _u16(p, offset, e);
        offset += 2;
        if (count > maxImuRecords) return null;
        if (p.length < offset + count * EegImuRecord.size) return null;
        for (var i = 0; i < count; i++) {
          imu.add(EegImuRecord.fromBytes(p, offset, e));
          offset += EegImuRecord.size;
        }
      }
    }

    // 压缩帧的结构自洽：EEG 段长度可变（由 bit 流决定），无法像旧格式那样
    // 在 _payloadMatches 里用帧头字段预判 —— 这里要求「解压 + IMU 段」
    // 恰好耗尽整个载荷，否则说明 Length 口径 / 定界错了，判非法走重同步。
    if (differential && options.strictPayload && offset != p.length) {
      return null;
    }

    return EegDataFrame(
      cmd: cmd,
      eleQuantity: eleQuantity,
      channelMask: channelMask,
      channelNum: reportedChannels,
      sampleCount: sampleCount,
      timestampMs: timestampMs,
      bootId: bootId,
      labelCode: labelCode,
      channels: channels,
      imu: imu,
      raw: raw,
      differential: differential,
    );
  }

  static int _u16(List<int> p, int offset, Endian endian) =>
      endian == Endian.big
      ? (p[offset] << 8) | p[offset + 1]
      : (p[offset + 1] << 8) | p[offset];

  static int _u32(List<int> p, int offset, Endian endian) {
    final a = p[offset];
    final b = p[offset + 1];
    final c = p[offset + 2];
    final d = p[offset + 3];
    return endian == Endian.big
        ? (a << 24) | (b << 16) | (c << 8) | d
        : (d << 24) | (c << 16) | (b << 8) | a;
  }

  /// 24 位有符号采样点，字节序由调用方指定（[EegFrameOptions.sampleEndian]）
  ///
  /// 真机是**大端**（`b0<<16 | b1<<8 | b2`），由一帧真机抓包
  ///（`AA 8B B8 0E 57 FF 00 08 64 00 …`，8 通道 × 100 点）三条判据定死：
  /// 1. **字节分布**：采样点形如 `79 E8 0A`，第 0 字节只有 3 个取值
  ///    （0x10 / 0x79 / 0x7A）—— 小幅信号的最高字节是符号扩展，必然几乎恒定；
  ///    第 1、2 字节各有 114 / 181 个取值（变化剧烈）→ 它们是中低字节。
  /// 2. **信号连续性**：大端解出各通道相邻样本差分中位 ≈ 3551 LSB（平滑）；
  ///    小端解出 ≈ 5.37e6 LSB（相邻两点差半帧满量程）= 纯噪声，不可能是 EEG。
  /// 3. **旁证**：上位机参考实现注释「与官方 eeg_tool
  ///    `ReciveCollectionData.MoveNext` 逐字节一致，大端」。
  ///
  /// ⚠️ 之前这条注释写「真机是小端」，依据只是「`7F FF FF` 小端读 = -129
  /// 看起来合理」—— 单看一个值两种读法都能凑出像样的数，判据不成立；
  /// 按小端解真机的实际表现就是原始值在 ±838 万之间乱跳。
  static int _i24(List<int> p, int offset, Endian endian) {
    final v = endian == Endian.big
        ? (p[offset] << 16) | (p[offset + 1] << 8) | p[offset + 2]
        : (p[offset + 2] << 16) | (p[offset + 1] << 8) | p[offset];
    return v >= 0x800000 ? v - 0x1000000 : v;
  }

  static int _popCount(int value) {
    var v = value;
    var count = 0;
    while (v != 0) {
      count += v & 0x01;
      v >>= 1;
    }
    return count;
  }
}

/// EEG 差分压缩编解码（协议 v1.1《EEG差分压缩方案_APP端》）
///
/// 0x8B 帧的 EEG 段不再是「逐点 24bit 绝对值」，而是按通道掩码排列的通道块：
///
/// ```
/// [ch0: 3B 基准点 | 差值 bit 流] [ch1: …] …
/// ```
///
/// * **基准点**：该通道第 1 点的 24bit 原始值，大端有符号（与设备端
///   `adc_append_sample` 一致）
/// * **差值 bit 流**（不按字节对齐、MSB 先出）：每点先 1 bit 标记 ——
///   `0` → 8bit 有符号差值；`1` → 16bit 有符号差值，其中 `0x8000`
///   是逃逸哨兵（后跟 24bit 该点绝对原值，差值基准重置为它）
/// * 每通道 bit 流末尾补 0 到整字节；**块数 = 通道掩码置位数**（不硬编码 8）
///
/// 解压**无损**：恢复出的 24bit 值逐点等于未压缩帧，µV 换算不变。
/// [encode] 与设备端打包规则一致（真实差值恰为 -32768 时也改写为逃逸），
/// 供单测构造压缩帧 / 三端联调对拍。
abstract final class EegDifferentialCodec {
  /// 16bit 差值里的逃逸哨兵：真实差值 `-32768` 恒被改写成逃逸
  static const int escapeSentinel = 0x8000;

  /// 解压 EEG 压缩段
  ///
  /// [p] 整个载荷，[offset] EEG 段起点（LabelCode 之后），
  /// [blocks] 通道块数（掩码置位数），[sampleCount] 每通道采样点数。
  ///
  /// 返回 `(通道数据, EEG 段字节数)`；字节不够时返回 null
  /// （调用方判非法帧走重同步）。
  static (List<Int32List>, int)? decode(
    List<int> p,
    int offset,
    int blocks,
    int sampleCount,
  ) {
    if (blocks <= 0 || sampleCount <= 0 || offset < 0) return null;
    final channels = List<Int32List>.generate(
      blocks,
      (_) => Int32List(sampleCount),
      growable: false,
    );

    var pos = offset;
    for (var c = 0; c < blocks; c++) {
      if (pos + 3 > p.length) return null;
      // 基准点：3B 大端有符号 24bit
      var prev = _signed24((p[pos] << 16) | (p[pos + 1] << 8) | p[pos + 2]);
      pos += 3;
      channels[c][0] = prev;

      var bits = 0; // 本通道块 bit 流已消耗位数
      for (var i = 1; i < sampleCount; i++) {
        final tag = _bit(p, pos, bits);
        if (tag < 0) return null;
        bits += 1;

        if (tag == 0) {
          final raw = _bits(p, pos, bits, 8);
          if (raw < 0) return null;
          bits += 8;
          prev += _signed8(raw);
        } else {
          final raw = _bits(p, pos, bits, 16);
          if (raw < 0) return null;
          bits += 16;
          if (raw == escapeSentinel) {
            // 逃逸：后跟 24bit 绝对原值，差值基准重置为该值
            final abs = _bits(p, pos, bits, 24);
            if (abs < 0) return null;
            bits += 24;
            prev = _signed24(abs);
          } else {
            prev += _signed16(raw);
          }
        }
        channels[c][i] = prev;
      }
      // 跳过本通道 bit 流的补零 padding，前进到下一通道块的基准点
      pos += (bits + 7) >> 3;
    }
    return (channels, pos - offset);
  }

  /// 把一帧采样数据打包成压缩 EEG 段（测试 / 与设备端对拍用）
  ///
  /// [channels]：`channels[c][i]` 为通道 c 第 i 点的 24bit 原始值。
  static Uint8List encode(Iterable<List<int>> channels) {
    final out = BytesBuilder();

    for (final ch in channels) {
      final n = ch.length;
      if (n == 0) continue;

      // 基准点：3B 大端
      final base = ch[0];
      out
        ..addByte((base >> 16) & 0xFF)
        ..addByte((base >> 8) & 0xFF)
        ..addByte(base & 0xFF);

      // 差值 bit 流：MSB 先出，块末补零对齐到整字节
      var acc = 0;
      var used = 0;
      void put(int value, int width) {
        for (var i = width - 1; i >= 0; i--) {
          acc = (acc << 1) | ((value >> i) & 1);
          if (++used == 8) {
            out.addByte(acc);
            acc = 0;
            used = 0;
          }
        }
      }

      var prev = base;
      for (var i = 1; i < n; i++) {
        final v = ch[i];
        final d = v - prev;
        if (d < -32767 || d > 32767) {
          // 差值超出 16bit 表示范围（含哨兵值 -32768）：走逃逸
          put(1, 1);
          put(escapeSentinel, 16);
          put(v & 0xFFFFFF, 24);
        } else if (d >= -128 && d <= 127) {
          put(0, 1);
          put(d & 0xFF, 8);
        } else {
          put(1, 1);
          put(d & 0xFFFF, 16);
        }
        prev = v;
      }
      if (used > 0) out.addByte((acc << (8 - used)) & 0xFF);
    }
    return out.toBytes();
  }

  // ---------- bit 读取（MSB 先出，与基准点字节序一致） ----------

  static int _bit(List<int> p, int base, int bitIndex) {
    final at = base + (bitIndex >> 3);
    if (at >= p.length) return -1;
    return (p[at] >> (7 - (bitIndex & 7))) & 1;
  }

  static int _bits(List<int> p, int base, int start, int width) {
    var v = 0;
    for (var i = 0; i < width; i++) {
      final bit = _bit(p, base, start + i);
      if (bit < 0) return -1;
      v = (v << 1) | bit;
    }
    return v;
  }

  static int _signed8(int v) => v >= 0x80 ? v - 0x100 : v;
  static int _signed16(int v) => v >= 0x8000 ? v - 0x10000 : v;
  static int _signed24(int v) => v >= 0x800000 ? v - 0x1000000 : v;
}

/// 解析结果类型
enum _ParseKind {
  /// 解析成功
  ok,

  /// 字节还不够一整帧：留在缓冲里等下一包
  needMore,

  /// 这个 0xAA 不是帧头 / 帧已损坏：丢 1 字节重新同步
  invalid,
}

/// 解析中间结果
class _ParseResult {
  final _ParseKind kind;

  /// 解析出的帧；[kind] 为 [ok] 时非空
  final EegSensorFrame? frame;

  /// 本帧占掉的字节数（[ok] 时有效）
  final int consumed;

  const _ParseResult.needMore()
    : kind = _ParseKind.needMore,
      frame = null,
      consumed = 0;

  const _ParseResult.invalid()
    : kind = _ParseKind.invalid,
      frame = null,
      consumed = 1;

  const _ParseResult.ok(EegSensorFrame f, int c)
    : kind = _ParseKind.ok,
      frame = f,
      consumed = c;
}

/// 解析器统计（调试「帧攒不出来 / 一直在丢字节」时最先看这里）
class EegFrameStats {
  /// 喂入的总字节数
  int receivedBytes = 0;

  /// 成功解析出的帧数
  int frames = 0;

  /// 因字节不足而等待的次数（分包正常时会频繁 +1）
  int incomplete = 0;

  /// 重同步次数：假帧头 / 帧尾或 Checksum 不对 / 结构不自洽
  ///
  /// 持续上涨 = Length 口径或字节序没对齐（试试另一个 [EegLengthScope]）。
  int resyncs = 0;

  /// 被丢弃的字节数（帧头前的垃圾 + 坏帧）
  int droppedBytes = 0;

  /// 缓冲溢出丢掉的字节数（正常应一直为 0）
  int overflowBytes = 0;

  /// [EegDataFrameParser.reset] 次数（每次断线重连 +1）
  int resets = 0;

  @override
  String toString() =>
      'EegFrameStats(frames: $frames, bytes: $receivedBytes, '
      'incomplete: $incomplete, resyncs: $resyncs, '
      'dropped: $droppedBytes, overflow: $overflowBytes, resets: $resets)';
}
