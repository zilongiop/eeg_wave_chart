import '../blue_utils.dart';

/// 《业务流程 v1.0.13》定义的 5 大类服务与特征 UUID
///
/// 设备端当前为开发版本，量产前会重新随机生成；换 UUID 只改本文件。
abstract final class EegUuid {
  // ---------------------------------------------------------------------------
  // 1. 数据交互服务：EEG+IMU 数据流、阻抗数据
  // ---------------------------------------------------------------------------

  /// Data Service
  static const String dataService = '7a4f2c20-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Sensor Data（Notify + CCC）：EEG+IMU 采样数据流 / 阻抗数据，分包下发
  static const String sensorData = '7a4f2c21-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// 预留（流控 / 时间同步）
  static const String dataReserved = '7a4f2c22-9b3d-4e5a-8c61-2d0f6e4a8b01';

  // ---------------------------------------------------------------------------
  // 2. 感知服务：改采样率 / 下发配置 / 连接信息上报 / 小狗状态标签
  // ---------------------------------------------------------------------------

  /// Sensing Service
  static const String sensingService = '7a4f2c30-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Config Command（Write With Response）：APP 下发配置帧
  static const String configCommand = '7a4f2c31-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Config Event（Notify + CCC）：配置应答 / 事件 / 连接信息 / 默认配置 / 标签
  static const String configEvent = '7a4f2c32-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Config State（Read）：当前全部生效配置快照
  static const String configState = '7a4f2c33-9b3d-4e5a-8c61-2d0f6e4a8b01';

  // ---------------------------------------------------------------------------
  // 3. 辅助服务：错误码、蓝牙性能测试
  // ---------------------------------------------------------------------------

  /// Aux Service
  static const String auxService = '7a4f2c40-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Error Record（Read + Notify）：设备错误码 / 异常日志
  static const String errorRecord = '7a4f2c41-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Test Command（Write With Response）：进入 / 退出测试模式
  static const String testCommand = '7a4f2c42-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Test Data（Write Response + Notify）：吞吐量 / 回环测试数据通道
  static const String testData = '7a4f2c43-9b3d-4e5a-8c61-2d0f6e4a8b01';

  // ---------------------------------------------------------------------------
  // 4. OTA 服务：固件升级（与 OtaUuid 一致，升级流程走 lib/ota）
  // ---------------------------------------------------------------------------

  /// OTA Service
  static const String otaService = '7a4f2c10-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// OTA Command（Write With Response）
  static const String otaCommand = '7a4f2c11-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// OTA Event（Notify + CCC）
  static const String otaEvent = '7a4f2c12-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// OTA Version（Read）
  static const String otaVersion = '7a4f2c13-9b3d-4e5a-8c61-2d0f6e4a8b01';

  // ---------------------------------------------------------------------------
  // 5. 安全服务：应用层身份认证（证书校验 / 挑战签名 / 认证门禁 / 令牌）
  // ---------------------------------------------------------------------------

  /// Security Service
  static const String securityService = '7a4f2c50-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Device Info（Read）：Device ID + 设备证书
  static const String deviceInfo = '7a4f2c51-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Challenge（Write With Response）：APP 下发随机数
  static const String challenge = '7a4f2c52-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Auth Response（Read + Notify）：设备对 Challenge 的签名
  static const String authResponse = '7a4f2c53-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Key Exchange（Write With Response）：ECDH 公钥交换
  static const String keyExchange = '7a4f2c54-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Auth Status（Read / Notify + CCC）：认证结果，0x00 = 已认证且门禁放开
  static const String authStatus = '7a4f2c55-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Auth Token（Read / Write）：设备签发的 96B 认证令牌，24h 内可免完整认证
  static const String authToken = '7a4f2c56-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// Device State（Read / Indicate）：ver / reason / flags / generation(LE32)
  ///
  /// 代际号变化表示设备被重置，本地令牌必须作废。
  static const String deviceState = '7a4f2c57-9b3d-4e5a-8c61-2d0f6e4a8b01';

  /// 5 大服务 UUID：扫描时可用于过滤（`startScan(serviceUuids: EegUuid.serviceUuids)`）
  static const List<String> serviceUuids = <String>[
    dataService,
    sensingService,
    auxService,
    otaService,
    securityService,
  ];

  /// 需要订阅推送的特征（Notify）
  static const List<String> notifyUuids = <String>[
    sensorData,
    configEvent,
    errorRecord,
    otaEvent,
    authStatus,
    deviceState,
    testData,
  ];

  /// 判断服务列表里是否包含某个特征
  static bool hasCharacteristic(List<String> uuids, String uuid) =>
      uuids.map(BlueUuid.normalize).contains(BlueUuid.normalize(uuid));
}
