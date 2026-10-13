import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:eeg_wave_chart/eeg_wave_chart.dart';

import 'demo_brain_page.dart';
import 'real_data_page.dart';

void main() {
  runApp(const MyApp());
}

/// Demo 用的仿真 EEG 信号源。
///
/// 所有正弦分量的频率都取 [DemoEegSignal.baseHz]（0.125Hz）的**整数倍**：
/// α=80×、β=144×、慢漂移=1×、工频=400×。只有这样波形才会严格每
/// [DemoEegSignal.cycleSec]（8 秒）重复一次，前后幅度完全一致。
///
/// 原来的慢漂移是 0.15Hz（周期 6.67 秒），跟 8 秒不同步，各分量相位互相
/// 错开，于是「开头几秒高、之后被压扁」——看起来像幅度变了，其实只是
/// 各个 8 秒窗口落在了慢漂移的不同相位上。
class DemoEegSignal {
  DemoEegSignal({this.noiseUv = 2.5, Random? rng}) : _rng = rng ?? Random();

  /// 循环周期（秒）。
  static const double cycleSec = 8.0;

  /// 基准频率 = 1 / [cycleSec]。
  static const double baseHz = 1.0 / cycleSec;

  /// 高斯白噪声幅度（µV）。设为 0 时信号严格周期，便于回归测试。
  final double noiseUv;

  final Random _rng;

  /// 生成 [t] 时刻、第 [channel] 通道的原始微伏值。
  ///
  /// 组成：α(10Hz)、β(18Hz)、慢漂移(0.125Hz)、50Hz 工频、高斯白噪声。
  double generate(double t, int channel) {
    final double phaseShift = channel * 0.4;

    // Alpha α节律（10Hz = 80 × 0.125Hz）
    final double alpha = 14.0 * sin(2 * pi * (80 * baseHz) * (t + phaseShift));
    // Beta β节律（18Hz = 144 × 0.125Hz）
    final double beta =
        6.0 * sin(2 * pi * (144 * baseHz) * (t + phaseShift * 0.6));
    // 慢基线漂移，模拟电极出汗漂移（0.125Hz，与循环同步）
    final double slowDrift = 10.0 * sin(2 * pi * baseHz * t);
    // 50Hz 市电干扰（= 400 × 0.125Hz）
    final double powerNoise = 4.0 * sin(2 * pi * (400 * baseHz) * t);
    // 高斯白噪声
    final double gaussNoise = (_rng.nextDouble() * 2.0 - 1.0) * noiseUv;

    return alpha + beta + slowDrift + powerNoise + gaussNoise;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EEG Wave Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const DemoHomePage(),
    );
  }
}

/// 首页：两个入口，分别跳到时序波形页和脑地形图页。
class DemoHomePage extends StatelessWidget {
  const DemoHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EEG Wave Demo')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _DemoEntryCard(
                  icon: Icons.show_chart,
                  title: 'EEG 时序波形',
                  subtitle: '10 分钟模拟数据 · 250Hz · 滤波降采样滚动显示',
                  onTap: () => _open(context, const DemoEegPage()),
                ),
                const SizedBox(height: 16),
                _DemoEntryCard(
                  icon: Icons.blur_on,
                  title: 'EEG 脑地形图',
                  subtitle: '时序波形 + Alpha 频段功率热力图',
                  onTap: () => _open(context, const DemoBrainPage()),
                ),
                const SizedBox(height: 16),
                _DemoEntryCard(
                  icon: Icons.insights,
                  title: '真实采集数据回放',
                  subtitle: '设备日志解析 · 500Hz · CH7/CH8 为 1mV 5Hz 正弦',
                  onTap: () => _open(context, const RealDataPage()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static void _open(BuildContext context, Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext context) => page),
    );
  }
}

class _DemoEntryCard extends StatelessWidget {
  const _DemoEntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                child: Icon(icon),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class DemoEegPage extends StatefulWidget {
  const DemoEegPage({super.key});

  @override
  State<DemoEegPage> createState() => _DemoEegPageState();
}

class _DemoEegPageState extends State<DemoEegPage>
    with SingleTickerProviderStateMixin {
  late final StreamController<EegSample> _sampleController;
  Ticker? _simTicker;
  bool _running = true;

  /// 模拟参数
  static const double sampleRate = 250.0;
  static const int channelCount = 4;

  /// 模拟总时长：10分钟 = 600秒
  static const double totalSimDurationSec = 600.0;

  /// 总帧数：600s × 250Hz（用整数字面量相乘，const 表达式不支持 toInt()）
  static const int totalFrames = 600 * 250;

  /// 单帧最多补发的样本数，避免长时间挂后台后一次性刷爆 UI。
  static const int _maxCatchUpPerFrame = 1000;

  /// 可切换的 X 轴每格时间（秒/格）：0.5 / 1 / 2。
  ///
  /// 这是「X 轴时间间隔」，控制一屏看多长时间，不改动数据播放速率
  /// （始终是 250Hz，切换只改变显示的时间尺度）。
  static const List<double> windowOptions = <double>[0.5, 1, 2];

  /// 屏幕横向格数：窗口总时长 = 每格时间 × 格数。
  ///
  /// 固定格数才能保证切换每格时间时刻度数量不变，只是每格代表的时间变长。
  static const int xAxisDivisions = 5;

  /// 当前 X 轴每格时间（秒）。
  double _secondsPerDivision = 2.0;

  /// 当前窗口总时长（秒）= 每格时间 × 格数。
  double get _windowDuration => _secondsPerDivision * xAxisDivisions;

  /// 切换窗口时自增，作为波形控件的 key 强制重建。
  ///
  /// 缓冲区容量、滤波器状态、降采样桶宽都跟窗口时长绑定，只有整体重建
  /// 才能把它们全部复位，实现「切换后数据从头展示」。
  int _restartToken = 0;

  /// 已发出的采样序号。
  int _emitted = 0;

  /// 用墙钟时间推算应当发出多少样本，而不是靠 4ms 定时器数个数：
  /// 定时器在模拟器上会成簇触发，数据忽多忽少，波形就会一跳一跳。
  final Stopwatch _clock = Stopwatch();

  /// 仿真信号源。
  final DemoEegSignal _signal = DemoEegSignal();

  @override
  void initState() {
    super.initState();
    _sampleController = StreamController<EegSample>.broadcast();
    _clock.start();
    // 每帧跟随屏幕刷新补发当前时刻之前应该产生的样本。
    _simTicker = createTicker((_) => _emitDueSamples())..start();
  }

  void _emitDueSamples() {
    if (!_running) {
      return;
    }
    final double elapsedSec = _clock.elapsedMicroseconds / 1000000.0;
    int due = (elapsedSec * sampleRate).floor() - _emitted;
    if (due <= 0) {
      return;
    }
    // 落后太多时限制单帧补发量，剩下的下一帧继续补。
    if (due > _maxCatchUpPerFrame) {
      due = _maxCatchUpPerFrame;
    }

    for (int i = 0; i < due && _emitted < totalFrames; i++) {
      final double nowTimeSec = _emitted / sampleRate;
      _emitFrame(nowTimeSec);
      _emitted++;
    }

    if (_emitted >= totalFrames) {
      _stopSimulation();
    }
  }

  /// 档位文案：整数档显示 "1s"，小数档显示 "0.5s"（避免 toInt() 变成 "0s"）。
  static String _formatDivision(double seconds) =>
      seconds == seconds.round() ? '${seconds.toInt()}s' : '${seconds}s';

  /// 切换 X 轴每格时间，并把数据拨回起点重新播放。
  void _switchWindow(double seconds) {
    if (_secondsPerDivision == seconds) {
      return;
    }
    setState(() {
      _secondsPerDivision = seconds;
      // 数据从头播放：已发序号归零、墙钟重新计时。
      _emitted = 0;
      _running = true;
      _clock.reset();
      _clock.start();
      // 只有之前播完 10 分钟停过才需要重新拉起；对已在运行的 ticker
      // 再调 start() 会抛「A ticker was started twice」。
      if (!(_simTicker?.isActive ?? false)) {
        _simTicker?.start();
      }
      _restartToken++;
    });
  }

  void _emitFrame(double nowTimeSec) {
    for (int ch = 0; ch < channelCount; ch++) {
      final double uv = _signal.generate(nowTimeSec, ch);

      _sampleController.add(
        EegSample(
          rawAdc: (uv * 1000).toInt(),
          rawUv: uv,
          filteredUv: 0,
          timeSec: nowTimeSec,
          channelIndex: ch,
        ),
      );
    }
  }

  void _stopSimulation() {
    if (!_running) {
      return;
    }
    _running = false;
    _simTicker?.stop();
    debugPrint("✅ 10分钟EEG模拟数据流已结束");
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("EEG波形｜10分钟模拟数据")),
      body: Column(
        children: [
          const SizedBox(height: 12),
          // 窗口时长切换：切换后数据从头播放。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                const Text(
                  'X轴/格',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    children: windowOptions
                        .map(
                          (double seconds) => ChoiceChip(
                            label: Text(_formatDivision(seconds)),
                            selected: _secondsPerDivision == seconds,
                            onSelected: (_) => _switchWindow(seconds),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Expanded 必须是 Column/Row 的直接子节点，包一层 Container
          // 会导致 ParentDataWidget 断言失败、整页构建不出来。
          Expanded(
            child: EegWaveChartWidget(
              // 换 key 让控件整体重建：清空环形缓冲、复位滤波器，
              // 否则切换窗口后画面上还残留着上一档的旧波形。
              key: ValueKey<int>(_restartToken),
              config: EegWaveConfig(
                sampleRate: sampleRate,
                channelCount: channelCount,
                notchFreq: 50.0,
                filterOrder: 4,
                windowDuration: _windowDuration,
                // X 轴每格时间 = 按钮选的值；窗口跨度 = 每格 × 格数。
                xAxisInterval: _secondsPerDivision,
                xAxisDivisions: xAxisDivisions,
                // 标准 EEG 量程：每个通道 ±100µV。样本一到达就被夹紧到
                // [基线-100, 基线+100]，所以采集到的数据绝不会画到带外；
                // 单通道（channelCount=1）时 Y 轴就是标准的 -100 ~ +100。
                displayUvRange: 100.0,
                channelNames: const <String>['Fp1', 'Fp2', 'C3', 'C4'],
                channelHeight: 90.0,
              ),
              sampleStream: _sampleController.stream,
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Text(
              _running
                  ? "🟢正在模拟 ${(totalSimDurationSec / 60).toStringAsFixed(0)}"
                        " 分钟 EEG 数据流 | ${sampleRate.toStringAsFixed(0)}Hz"
                        " | X轴 ${_formatDivision(_secondsPerDivision)}/格"
                        "（一屏 ${_windowDuration.toStringAsFixed(1)}s）"
                  : "🔴模拟已经结束",
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _simTicker?.dispose();
    _simTicker = null;
    _sampleController.close();
    super.dispose();
  }
}
