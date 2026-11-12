# EEG 蓝牙通信模块

依据《业务流程 v1.0.7》实现的头戴 EEG 设备通信层，位于 `core/blue` 之下：
**不直接依赖任何蓝牙插件**（底层仍走 `BlueManager` / `flutter_blue_plus`），
上行数据一律解析后投递到全局事件总线（`common/event_bus_manager.dart`），
页面只订阅关心的事件类型。

```
lib/core/blue/
├── blue_manager.dart        # BLE 门面（本次新增 mtu / characteristicOf）
└── eeg/
    ├── eeg.dart             # 库导出
    ├── eeg_uuid.dart        # 5 大服务 + 16 个特征 UUID
    ├── eeg_cmd.dart         # 命令字 0x21~0x28 / 0xA1~0xAF + 设备事件类型
    ├── eeg_frame.dart       # 配置帧 AA|CMD|DATA|XOR|55 编解码 + 流式解码器
    ├── eeg_config.dart      # 第 5/6 章 JSON 模型 + 小狗状态标签
    ├── eeg_data_frame.dart  # 第 7.1/7.2 节二进制帧 + IMU 记录 + 时间锚点
    ├── eeg_event.dart       # 投到事件总线的事件类型
    └── eeg_service.dart     # 门面 EegDeviceService（绑定/订阅/下发/分发）
```

---

## 1. 快速开始

`main()` 里已接好（`BlueManager.i.init()` 之后）：

```dart
await EegDeviceService.i.attach();
```

页面里：

```dart
// 订阅（记得在 dispose / onClose 里 cancel）
final sub = EegDeviceService.i.on<EegDogStateEvent>().listen((e) {
  debugPrint('小狗：${e.state.label} @ ${e.absoluteTime}');
});

// 下发
await EegDeviceService.i.setEegImuConfig(eegHz: 1000, imuHz: 120);
```

连接设备仍走原来的「蓝牙设备」页（`BlueManager.i.connect()`），
`EegDeviceService` 监听连接状态：**连上自动绑定特征并订阅推送，断开自动清理**。

调试页：**调试入口 → 蓝牙通信（EEG）**，可下发全部命令并实时看所有事件。

---

## 2. 服务与 UUID（`eeg_uuid.dart`）

| 分类 | Service | Characteristic | 属性 |
| --- | --- | --- | --- |
| 数据交互 | `7A4F2C20-…-8B01` | `…21` Sensor Data | Notify + CCC |
| | | `…22` 预留（流控/时间同步） | — |
| 感知 | `7A4F2C30-…-8B01` | `…31` Config Command | Write With Response |
| | | `…32` Config Event | Notify + CCC |
| | | `…33` Config State | Read |
| 辅助 | `7A4F2C40-…-8B01` | `…41` Error Record | Read + Notify |
| | | `…42` Test Command | Write With Response |
| | | `…43` Test Data | Write Response + Notify |
| OTA | `7A4F2C10-…-8B01` | `…11` OTA Command / `…12` OTA Event / `…13` OTA Version | 与 `lib/ota` 的 `OtaUuid` 一致 |
| 安全 | `7A4F2C50-…-8B01` | `…51` Device Info（Read） | |
| | | `…52` Challenge（Write） | |
| | | `…53` Auth Response（Read + Notify） | |
| | | `…54` Key Exchange（Write） | |
| | | `…55` Auth Status（Notify） | |

> UUID 前缀统一为 `7A4F2Cxx-9B3D-4E5A-8C61-2D0F6E4A8B01`，量产前设备端会重新随机生成，**换 UUID 只改 `eeg_uuid.dart` 一个文件**。
> 扫描过滤可用 `EegUuid.serviceUuids`。

OTA 升级流程不在这里实现，仍走 `lib/ota`（`OtaManager` / `OtaBleTransport`）；本模块只订阅 OTA Event 并转发 `EegOtaEventNotice`。

---

## 3. 命令字（`eeg_cmd.dart`）

### APP → EEG（0x21~0x28）

| CMD | 名称 | DATA |
| --- | --- | --- |
| 0x21 | 脑电+IMU 配置 | `{"eeg_hz":250,"imu_hz":120,"duration":0}` |
| 0x22 | 阻抗配置 | `{"sample_hz":250,"duration":0}` |
| 0x23 | 阻抗通过标准 | `{"impedance_max_kohm":50,"channel":5}` |
| 0x24 | 触发规则 | triggers JSON Array |
| 0x25 | 规则配置 | profiles JSON Array |
| 0x26 | 整表配置 | 第 5 章完整 JSON |
| 0x27 | 配置查询 | 空 = 查全部生效配置 |
| 0x28 | 重置 | `{"reset":"0"}` |

### EEG → APP（0xA1~0xAF，应答 = 命令 +0x80）

| CMD | 名称 | 说明 |
| --- | --- | --- |
| 0xA1~0xA7 | 对应 0x21~0x27 的应答 | `result`：0 = 成功；0xA7 携带全部生效配置 |
| 0xA8 | 事件：ble_force_switch_phone | 无 DATA（整帧 `AA A8 00 55`） |
| 0xA9 | 事件：ble_switch_gate | 无 DATA |
| 0xAB | 事件：imu_state_active | 无 DATA |
| 0xAC | 事件：imu_state_sleep | 无 DATA |
| 0xAD | 连接信息上报 | `{"Timestamps":{"BootID":38,"Timestamp":60000}}` |
| 0xAE | 默认配置上报 | `{"eeg_imu_config":{"eeg_hz":250,"imu_hz":120,"EleQuantity":85}}` |
| 0xAF | 小狗状态标签（周期 2s） | `{"label":{"code":0,"Timestamp":80000}}` |

> 0xAA 故意留空，避免与帧头 0xAA 混淆。

---

## 4. 配置帧（`eeg_frame.dart`）

```
AA | CMD(1) | DATA(ASCII JSON, 变长) | XOR(1) | 55
```

- XOR 只覆盖 **DATA** 段，不含帧头 / CMD / 帧尾；DATA 为空时 XOR = 0x00
- 单帧 DATA 上限 = `MTU - 3 - 4`（ATT 载荷 `MTU-3`，再扣 4 个定界字节），超出自动分包，**每帧都是完整帧**，设备端需自行重组
- 校验失败整帧丢弃，由应用层超时重传兜底

```dart
final frames = EegConfigFrameEncoder.encode(EegCmd.setEegImuConfig, '{"eeg_hz":250}', mtu: 247);
final decoded = EegConfigFrameDecoder().push(notifyBytes); // 流式切帧
```

---

## 5. 二进制数据帧（`eeg_data_frame.dart`）

### 阻抗帧（0x90）

`AA | 90 | Length(2) | EleQuantity(1) | ChannelMask(2) | ChannelNum(1) | SampleCount(2) | Data(N) | XOR | 55`

### 脑电+IMU 帧（0x8B）

`AA | 8B | Length(2) | EleQuantity | ChannelMask | ChannelNum | SampleCount | Timestamp(4) | BootID(2) | Data(N) | IMURecordCount(2) | IMURecord(M×45) | XOR | 55`

- **Data（EEG 段）为差分压缩格式**（协议 v1.1《EEG差分压缩方案》，恒压缩、无兼容标志）：
  按通道掩码置位数排列的通道块，每块 = `3B 基准点（大端有符号 24bit）+ 差值 bit 流`；
  bit 流不按字节对齐、MSB 先出，每点 `1bit 标记 + 8bit/16bit 有符号差值`，
  `0x8000` 为逃逸哨兵（后跟 24bit 绝对原值），块末补零到整字节。
  解压**无损**，恢复后的 24bit 值与 µV 换算和未压缩帧完全一致（`EegDifferentialCodec`）。
  Length = 压缩段实际字节数。需要回放 v1.0 旧格式录波时传
  `EegFrameOptions(eegDifferential: false)`。
- IMU 每条 45 字节：加速度 ×3、陀螺仪 ×3、温度、步数、事件掩码（1B）、重力向量（3×float32）、四元数（4×float32）
- 事件掩码位：0 步数 / 1 倾斜 / 2 显著运动 / 3 自由落体 / 4 唤醒 / 5 6D 方向 / 6 单击 / 7 双击

### 时间戳与 BootID

设备时间戳是**开机相对时间**（ms，上电从 0 计数），只有 `(BootID, Timestamp)` 二元组才唯一。
连接建立时设备上报 0xAD，APP 以收到的真实时刻为锚点：

```
T_abs = T_real + (t_frame - t_now)      // 同 BootID 内
```

`EegTimeAnchor` 封装该换算，`EegDeviceService.absoluteTime(bootId, ts)` 直接取绝对时间；
采样点相对时间：`t_i = Timestamp - (SampleCount - 1 - i) × 1000 / eegHz`（见 `EegDataFrame.sampleOffsetMs`）。

---

## 6. 事件（`eeg_event.dart`）

全部继承 `EegEvent`，经 `EventBusManager`（event_bus）分发。订阅基类即可收到所有事件。

| 事件 | 触发来源 | 关键字段 |
| --- | --- | --- |
| `EegConnectionEvent` | 连接状态变化 | `connected`、`deviceId` |
| `EegSamplesEvent` | Sensor Data 0x8B | `frame`（通道数据 / IMU / 时间戳） |
| `EegImpedanceEvent` | Sensor Data 0x90 | `frame` |
| `EegBatteryEvent` | 帧内 EleQuantity / 0xAE | `level` |
| `EegTimeAnchorEvent` | 0xAD | `anchor`（BootID + 时间戳 + 真实时刻） |
| `EegDeviceIdEvent` | DeviceId 上报 | `id` |
| `EegDogStateEvent` | 0xAF（2s） | `code`、`state`、`absoluteTime` |
| `EegDeviceEventReport` | 0xA8/A9/AB/AC | `type` |
| `EegConfigReportEvent` | 0xAE 默认配置 | `config`、`isDefault` |
| `EegConfigSnapshotEvent` | 0xA7 / Config State | `config`（全量） |
| `EegCommandResultEvent` | 0xA1~0xA7 应答 | `cmd`、`result`、`isOk` |
| `EegErrorEvent` | Error Record | `raw`、`text` |
| `EegAuthStatusEvent` | Auth Status | `raw`、`text` |
| `EegOtaEventNotice` | OTA Event | `raw`（升级流程走 `lib/ota`） |
| `EegRawNotifyEvent` | 原始推送（默认关） | `uuid`、`bytes` |
| `EegUnknownFrameEvent` | 未归类配置帧 | `cmd`、`text` |

高频的 `EegSamplesEvent` 只持帧引用，不要在监听回调里做重活。

---

## 7. EegDeviceService API

| 分类 | 方法 |
| --- | --- |
| 生命周期 | `attach()`（监听连接状态）/ `detach()` / `bind()` / `unbind()` |
| 下行配置 | `setEegImuConfig` / `setImpedanceConfig` / `setImpedanceQuality` / `setTriggers` / `setProfiles` / `setFullConfig` / `queryConfig` / `resetDevice` |
| 读取 | `readConfigSnapshot()` / `readErrorRecord()` / `readDeviceInfo()` / `readAuthResponse()` |
| 辅助 | `sendTestCommand(text)` / `writeTestData(bytes)` |
| 安全 | `writeChallenge(nonce)` / `writeKeyExchange(pubKey)` |
| 状态 | `isReady` / `battery` / `config` / `deviceId` / `label` / `anchor` / `boundUuids` |
| 其它 | `on<T>()` 订阅、`absoluteTime(bootId, ts)`、`debugRaw` 开关、`frameOptions`（字节序 / 采样点排布） |

---

## 8. 待与嵌入式确认的点

1. **Length 字段口径**：文档两处说法不一致（"不含 Header/Footer/CmdType" vs "含 EEG Data/IMU 记录"）。解析器兼容 `length-3` 与 `length` 两种（靠 XOR + 帧尾 0x55 自动判定），定稿后建议只留一种。
2. **采样点排布**：文档写"按通道排列"，默认按**采样点交错**解析（与真实录波日志一致）；`EegFrameOptions.layout` 可切 `channelMajor`。
3. ~~**多字节字节序**：默认大端（EEG 24 位大端，ADS1299 风格）；`EegFrameOptions.endian` 可改小端。~~ **已定稿**：协议是**混合字节序** —— 头部（Length / ChannelMask / SampleCount / Timestamp / BootID / IMU）小端，24 位采样点**大端**。两者已拆成 `EegFrameOptions.endian`（头部，默认 little）与 `EegFrameOptions.sampleEndian`（采样点，默认 big）。判据见 `eeg_data_frame.dart` 的 `_i24` 注释（真机抓包：字节分布 + 相邻差分 + 上位机参考实现三证）。
4. **小狗状态 0x06 重复**：文档 `0x06` 同时写了 `sit` 与 `sniff` 且缺 `0x05`，当前按 `0x05=sit, 0x06=sniff`。
5. **安全服务验签未实现**：`crypto` 包只有哈希/HMAC，ECDSA 验签 + ECDH 需要 `pointycastle` 或原生通道；目前只提供流程接口（发 Challenge、读签名、写公钥）。identityToken 的签名 / `aud` / `exp` 校验同样只能由后端完成。
6. **配置帧多包重组规则**文档未定义，当前每帧独立完整，由设备端重组。
