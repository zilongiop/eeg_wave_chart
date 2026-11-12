import 'dart:async';
import 'dart:io' show Platform;

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'blue/blue.dart' as ble;

/// 蓝牙实时脑波页
///
/// 扫描 / 连接走 `blue/blue_manager.dart`，数据解析走 `blue/eeg/`：
/// Sensor Data 的 notify 分片由 `EegDataFrameParser` 攒成完整的 0x8B 帧，
/// `EegDeviceService` 以 [ble.EegSamplesEvent] 分发，这里只做两件事：
/// 1. 用 `blue/eeg/eeg_scale.dart` 的标定系数把 24 位 LSB 换算成 µV；
/// 2. 按采样率生成连续时间轴，转成 [EegSample] 喂给 [EegWaveChartWidget]。
///
/// 这样波形图里画的是设备真实采样值，不是模拟信号、也不是日志回放。
class BleEegPage extends StatefulWidget {
  const BleEegPage({super.key});

  @override
  State<BleEegPage> createState() => _BleEegPageState();
}

class _BleEegPageState extends State<BleEegPage> {
  static const List<int> _sampleRateOptions = <int>[250, 500, 1000, 2000];
  static const List<int> _channelOptions = <int>[1, 2, 4, 8];
  static const List<double> _rangeOptions = <double>[100, 500, 1200];

  /// 波形图的唯一数据入口。缓存 stream 实例，保证父级 setState 重建时
  /// `didUpdateWidget` 的 `identical` 判断成立、不会反复退订重订。
  final StreamController<EegSample> _sampleCtrl =
      StreamController<EegSample>.broadcast();
  late final Stream<EegSample> _sampleStream = _sampleCtrl.stream;

  StreamSubscription<List<ble.BlueScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<ble.BlueAdapterState>? _adapterSub;
  StreamSubscription<ble.BlueConnectionState>? _connectionSub;
  StreamSubscription<ble.BlueException>? _errorSub;
  StreamSubscription<ble.EegSamplesEvent>? _samplesSub;
  StreamSubscription<ble.EegConfigReportEvent>? _configSub;
  StreamSubscription<ble.EegChangeSampleEvent>? _rateSub;
  StreamSubscription<List<int>>? _packetSub;

  List<ble.BlueScanResult> _scanResults = const <ble.BlueScanResult>[];
  bool _scanning = false;
  bool _onlyEegDevices = true;
  bool _busy = false;
  bool _connected = false;
  String? _error;
  String _status = '未连接';
  ble.BlueAdapterState _adapter = ble.BlueAdapterState.unknown;

  double _sampleRate = 500;
  int _channelCount = 8;
  double _uvRange = 500;

  /// 时间轴用的样本计数：按采样率换算成秒，避免设备时间戳回绕 / 分包抖动
  /// 让波形窗口跳变。丢包时时间轴会略快于真实时间，但不影响波形形状。
  int _sampleCursor = 0;
  int _frameCount = 0;
  int _sampleCount = 0;
  int _packetCount = 0;
  int? _battery;
  List<double> _lastUv = List<double>.filled(8, 0);
  int _waveKey = 0;
  int _lastUiUpdateMs = 0;

  @override
  void initState() {
    super.initState();
    final ble.BlueManager blue = ble.BlueManager.i;
    _connected = blue.isConnected;
    _scanning = blue.isScanningNow;
    _adapter = blue.adapterStateNow;
    if (_connected) {
      _status = '已连接 ${blue.connectedDevice?.name ?? ''}';
    }

    _scanSub = blue.scanResults.listen((List<ble.BlueScanResult> results) {
      if (!mounted) return;
      setState(() => _scanResults = results);
    });
    _scanningSub = blue.isScanning.listen((bool value) {
      if (mounted) setState(() => _scanning = value);
    });
    _adapterSub = blue.adapterState.listen((ble.BlueAdapterState value) {
      if (mounted) setState(() => _adapter = value);
    });
    _connectionSub = blue.connectionState.listen(_onConnectionState);
    _errorSub = blue.errors.listen((ble.BlueException error) {
      if (mounted) setState(() => _error = error.message);
    });

    // EEG 协议层已经完成「分包重组 → XOR 校验 → 差分解压 → EegDataFrame」，
    // 页面只订阅解析后的事件即可。
    _samplesSub = ble.EegDeviceService.i
        .on<ble.EegSamplesEvent>()
        .listen(_onSamples);
    _configSub = ble.EegDeviceService.i
        .on<ble.EegConfigReportEvent>()
        .listen(_onConfigReport);
    _rateSub = ble.EegDeviceService.i
        .on<ble.EegChangeSampleEvent>()
        .listen((ble.EegChangeSampleEvent event) {
      final int? hz = event.eegHz;
      if (hz != null && hz > 0) _applyDeviceSampleRate(hz);
    });
    _packetSub = ble.EegDeviceService.i.rawPackets.listen((List<int> bytes) {
      _packetCount++;
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _scanningSub?.cancel();
    _adapterSub?.cancel();
    _connectionSub?.cancel();
    _errorSub?.cancel();
    _samplesSub?.cancel();
    _configSub?.cancel();
    _rateSub?.cancel();
    _packetSub?.cancel();
    _sampleCtrl.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 扫描 / 连接
  // ---------------------------------------------------------------------------

  /// Android 12+ 的 BLUETOOTH_SCAN / BLUETOOTH_CONNECT 是运行时权限；
  /// Android 11 及以下则靠定位权限才能扫描 BLE。iOS 由系统按 Info.plist
  /// 的描述自动弹窗，不需要手动申请。
  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final Map<Permission, PermissionStatus> statuses =
        await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final bool nearby =
        (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
            (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
    final bool location =
        statuses[Permission.locationWhenInUse]?.isGranted ?? false;
    return nearby || location;
  }

  Future<void> _startScan() async {
    if (!await _ensurePermissions()) {
      if (mounted) {
        setState(() => _error = '未获得蓝牙权限，请在系统设置里开启后重试');
      }
      return;
    }
    if (mounted) {
      setState(() {
        _error = null;
        _scanResults = const <ble.BlueScanResult>[];
      });
    }
    try {
      // 不按服务 UUID 过滤扫描：部分设备广播里不含完整服务列表，
      // 交给 UI 的 DeviceFilter 按设备名（16CH-ASI）过滤更可靠。
      await ble.BlueManager.i.startScan(timeout: const Duration(seconds: 15));
    } catch (error) {
      if (mounted) setState(() => _error = '扫描失败：$error');
    }
  }

  Future<void> _stopScan() async {
    try {
      await ble.BlueManager.i.stopScan();
    } catch (error) {
      if (mounted) setState(() => _error = '停止扫描失败：$error');
    }
  }

  Future<void> _connect(ble.BlueScanResult result) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在连接 ${result.name}…';
    });
    try {
      await ble.BlueManager.i.connect(
        result.device,
        manual: true,
        notifyUuids: ble.EegUuid.notifyUuids,
        writeUuids: <String>[ble.EegUuid.configCommand],
      );

      // 特征绑定由 EegDeviceService 监听连接状态后自动完成（不要在这里重复
      // bind：并发的两轮 bind 会互相 unbind，反而把推送订阅清掉）。
      _resetTimeline();
      if (mounted) setState(() => _status = '已连接 ${result.name}');

      // 设备通常连上订阅 Sensor Data 后就会推流；若固件要求显式启动采集，
      // 等协议层绑定就绪后补一条 0x21 配置。失败不影响接收数据。
      unawaited(_startAcquisition());
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _status = '连接失败';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 等协议层完成特征绑定后，按当前采样率下发 0x21 采集配置
  ///
  /// 连接状态事件是异步派发的，bind 可能还没跑完；`isReady` 为真表示
  /// Config Command 特征已登记。设备若本来就持续推流，这条命令只是对齐
  /// 采样率，写失败也不影响波形接收。
  Future<void> _startAcquisition() async {
    for (int i = 0; i < 20; i++) {
      if (!mounted) return;
      if (ble.EegDeviceService.i.isReady) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted || !ble.EegDeviceService.i.isReady) return;
    try {
      await ble.EegDeviceService.i.setEegImuConfig(
        eegHz: _sampleRate.round(),
        imuHz: 120,
        duration: 0,
      );
      await ble.EegDeviceService.i.queryConfig();
    } catch (error) {
      if (mounted) setState(() => _error = '下发采集配置失败：$error');
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await ble.BlueManager.i.disconnect();
    } catch (error) {
      if (mounted) setState(() => _error = '断开失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeSampleRate(int hz) async {
    setState(() {
      _sampleRate = hz.toDouble();
      _sampleCursor = 0;
      _waveKey++;
    });
    if (!_connected) return;
    try {
      await ble.EegDeviceService.i.setEegImuConfig(
        eegHz: hz,
        imuHz: 120,
        duration: 0,
      );
    } catch (error) {
      if (mounted) setState(() => _error = '切换采样率失败：$error');
    }
  }

  void _onConnectionState(ble.BlueConnectionState state) {
    final bool connected = state == ble.BlueConnectionState.connected;
    if (!connected) _resetTimeline();
    if (mounted) {
      setState(() {
        _connected = connected;
        _status = connected
            ? '已连接 ${ble.BlueManager.i.connectedDevice?.name ?? ''}'
            : '未连接';
      });
    }
  }

  void _onConfigReport(ble.EegConfigReportEvent event) {
    final int? hz = event.config.eegHz;
    if (hz != null && hz > 0) _applyDeviceSampleRate(hz);
    final int? battery = event.config.eleQuantity;
    if (battery != null) _battery = battery;
  }

  /// 以设备上报的采样率为准重建波形管线（滤波系数与时间轴都依赖它）
  void _applyDeviceSampleRate(int hz) {
    if (hz.toDouble() == _sampleRate) return;
    if (mounted) {
      setState(() {
        _sampleRate = hz.toDouble();
        _sampleCursor = 0;
        _waveKey++;
      });
    }
  }

  void _resetTimeline() {
    _sampleCursor = 0;
    _frameCount = 0;
    _sampleCount = 0;
    _packetCount = 0;
    _battery = null;
    _lastUv = List<double>.filled(8, 0);
    _waveKey++;
    ble.EegDeviceService.i.resetFrameParser();
  }

  // ---------------------------------------------------------------------------
  // 真实脑波数据 → EegSample
  // ---------------------------------------------------------------------------

  void _onSamples(ble.EegSamplesEvent event) {
    if (_sampleCtrl.isClosed) return;
    final ble.EegDataFrame frame = event.frame;
    if (!frame.isEegImu || frame.channels.isEmpty) return;

    final int points = frame.sampleCount;
    if (points <= 0) return;
    final int channelTotal = frame.channels.length;
    final int count = channelTotal < _channelCount ? channelTotal : _channelCount;
    final double baseSec = _sampleCursor / _sampleRate;
    final double stepSec = 1.0 / _sampleRate;

    for (int ch = 0; ch < count; ch++) {
      final List<int> source = frame.channels[ch];
      final int n = source.length < points ? source.length : points;
      for (int i = 0; i < n; i++) {
        final int lsb = source[i];
        // eegMicroVoltsFromLsb 与固件 eeg_16_data_compute() 逐位一致，
        // 波形图的滤波 / 去直流 / 量程都由插件侧接手。
        _sampleCtrl.add(
          EegSample(
            rawAdc: lsb,
            rawUv: ble.eegMicroVoltsFromLsb(lsb),
            filteredUv: 0,
            timeSec: baseSec + i * stepSec,
            channelIndex: ch,
          ),
        );
      }
      if (n > 0 && ch < _lastUv.length) {
        _lastUv[ch] = ble.eegMicroVoltsFromLsb(source[n - 1]);
      }
    }

    _sampleCursor += points;
    _frameCount++;
    _sampleCount += points * count;
    _battery = frame.eleQuantity;
    _throttleUi();
  }

  /// 2000Hz × 8 通道时每秒上万样本，统计信息没必要跟着逐帧刷新
  void _throttleUi() {
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUiUpdateMs < 250) return;
    _lastUiUpdateMs = now;
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('蓝牙实时脑波'),
        actions: <Widget>[
          if (_connected)
            TextButton(
              onPressed: _busy ? null : _disconnect,
              child: const Text('断开'),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildStatusBar(),
          _buildControls(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ),
          const Divider(height: 8),
          Expanded(child: _connected ? _buildWave() : _buildDeviceList()),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.blueGrey.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '蓝牙 ${_adapterLabel()} · $_status',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '${_sampleRate.round()}Hz · $_channelCount 通道 · ±${_uvRange.toInt()}µV · '
            '$_packetCount 包 / $_frameCount 帧 / $_sampleCount 样本'
            '${_battery == null ? '' : ' · 电量 $_battery%'}',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            runSpacing: 2,
            children: <Widget>[
              for (int ch = 0; ch < _channelCount; ch++)
                Text(
                  'CH${ch + 1} ${_lastUv[ch].toStringAsFixed(1)}µV',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _adapterLabel() => switch (_adapter) {
    ble.BlueAdapterState.on => '已开启',
    ble.BlueAdapterState.off => '已关闭',
    ble.BlueAdapterState.turningOn => '开启中',
    ble.BlueAdapterState.turningOff => '关闭中',
    ble.BlueAdapterState.unavailable => '不可用',
    ble.BlueAdapterState.unauthorized => '未授权',
    ble.BlueAdapterState.unknown => '未知',
  };

  Widget _buildControls() {
    final int? selectedRate = _sampleRateOptions.contains(_sampleRate.round())
        ? _sampleRate.round()
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _busy ? null : (_scanning ? _stopScan : _startScan),
                icon: Icon(_scanning ? Icons.stop : Icons.search),
                label: Text(_scanning ? '停止扫描' : '扫描设备'),
              ),
              if (_connected)
                OutlinedButton(
                  onPressed: _busy ? null : () => unawaited(_startAcquisition()),
                  child: const Text('启动采集'),
                ),
              if (_scanning)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const Text('仅 EEG 设备', style: TextStyle(fontSize: 12)),
              Switch(
                value: _onlyEegDevices,
                onChanged: (bool value) =>
                    setState(() => _onlyEegDevices = value),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                const Text('量程', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 6),
                for (final double range in _rangeOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text('±${range.toInt()}µV'),
                      selected: _uvRange == range,
                      onSelected: (_) => setState(() => _uvRange = range),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                const SizedBox(width: 8),
                const Text('采样率', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 6),
                DropdownButton<int>(
                  value: selectedRate,
                  hint: Text('${_sampleRate.round()}Hz'),
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: <DropdownMenuItem<int>>[
                    for (final int hz in _sampleRateOptions)
                      DropdownMenuItem<int>(value: hz, child: Text('$hz Hz')),
                  ],
                  onChanged: (int? hz) {
                    if (hz != null) unawaited(_changeSampleRate(hz));
                  },
                ),
                const SizedBox(width: 8),
                const Text('通道', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 6),
                DropdownButton<int>(
                  value: _channelCount,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: <DropdownMenuItem<int>>[
                    for (final int count in _channelOptions)
                      DropdownMenuItem<int>(
                        value: count,
                        child: Text('$count 路'),
                      ),
                  ],
                  onChanged: (int? count) {
                    if (count == null) return;
                    setState(() {
                      _channelCount = count;
                      _waveKey++;
                    });
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    final List<ble.BlueScanResult> results = _scanResults
        .where(
          (ble.BlueScanResult r) =>
              !_onlyEegDevices || ble.DeviceFilter.matches(r.name),
        )
        .toList(growable: true)
      ..sort(
        (ble.BlueScanResult a, ble.BlueScanResult b) =>
            b.rssi.compareTo(a.rssi),
      );

    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _scanning
                ? '正在扫描附近的蓝牙设备…\n只显示名称包含 16CH-ASI 的 EEG 设备，可关闭右上角开关查看全部设备'
                : '点击「扫描设备」开始搜索附近的 EEG 脑波设备',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final ble.BlueScanResult result = results[index];
        return ListTile(
          leading: const Icon(Icons.bluetooth),
          title: Text(result.name),
          subtitle: Text('${result.id} · RSSI ${result.rssi} dBm'),
          trailing: FilledButton(
            onPressed: _busy ? null : () => _connect(result),
            child: const Text('连接'),
          ),
        );
      },
    );
  }

  Widget _buildWave() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_frameCount == 0)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              '已连接，等待设备推送脑波数据…（若设备需要启动采集，请检查上方采样率配置）',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            child: EegWaveChartWidget(
              // 采样率 / 通道数 / 重连变化时重建，让滤波器回到零状态。
              key: ValueKey<int>(_waveKey),
              config: EegWaveConfig(
                sampleRate: _sampleRate,
                channelCount: _channelCount,
                windowDuration: 5.0,
                xAxisInterval: 1.0,
                xAxisDivisions: 5,
                displayUvRange: _uvRange,
                // 真实电极有几 mV 直流偏置，靠高通去掉；留 2s 预热避免启动瞬态。
                filterWarmupSec: 2.0,
                maxSpotsPerChannel: 600,
                channelNames: List<String>.generate(
                  _channelCount,
                  (int i) => 'CH${i + 1}',
                ),
                channelHeight: 56.0,
              ),
              sampleStream: _sampleStream,
            ),
          ),
        ),
      ],
    );
  }
}
