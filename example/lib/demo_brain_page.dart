import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:eeg_wave_chart/eeg_wave_chart.dart';

class DemoBrainPage extends StatefulWidget {
  const DemoBrainPage({super.key});

  @override
  State<DemoBrainPage> createState() => _DemoBrainPageState();
}

class _DemoBrainPageState extends State<DemoBrainPage> {
  late final StreamController<EegSample> _sampleController;
  Timer? _simTimer;

  static const double sampleRate = 250.0;
  static const int channelCount = 8;
  static const double totalSimSeconds = 10 * 60; //10分钟模拟

  /// 8 通道按 10-20 系统近似布点，顺序与电极列表 / 波形通道一致。
  static const List<String> channelNames = <String>[
    'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'O1', 'O2',
  ];

  /// 各通道 alpha 相对强度：枕区（O1/O2）最强、额区（Fp1/Fp2）最弱，
  /// 让地形图呈现符合生理的枕区优势。
  static const List<double> alphaWeights = <double>[
    0.30, 0.32, 0.48, 0.50, 0.68, 0.70, 1.00, 0.96,
  ];

  int _sampleSeq = 0;
  final Random _rng = Random();

  late BandData _bandData;
  //✅使用ValueNotifier传递功率，不需要访问插件私有state
  late final ValueNotifier<List<double>> _powerNotifier;

  @override
  void initState() {
    super.initState();
    _sampleController = StreamController<EegSample>.broadcast();
    _powerNotifier = ValueNotifier<List<double>>([]);

    // dx/dy 是头部包围盒内的归一化坐标；painter 以 dy 小的一侧为前额，
    // 因此自上前额向后枕部依次排布 8 个电极。
    final electrodes = <Electrode>[
      Electrode(name: channelNames[0], dx: 0.30, dy: 0.14), // Fp1
      Electrode(name: channelNames[1], dx: 0.70, dy: 0.14), // Fp2
      Electrode(name: channelNames[2], dx: 0.26, dy: 0.32), // F3
      Electrode(name: channelNames[3], dx: 0.74, dy: 0.32), // F4
      Electrode(name: channelNames[4], dx: 0.24, dy: 0.52), // C3
      Electrode(name: channelNames[5], dx: 0.76, dy: 0.52), // C4
      Electrode(name: channelNames[6], dx: 0.32, dy: 0.78), // O1
      Electrode(name: channelNames[7], dx: 0.68, dy: 0.78), // O2
    ];
    _bandData = BandData(
      title: "Alpha 8‑13Hz",
      electrodes: electrodes,
      minVal: 0,
      maxVal: 45,
    );

    final periodMs = (1000 / sampleRate).round();
    _simTimer = Timer.periodic(Duration(milliseconds: periodMs), (_) {
      final t = _sampleSeq / sampleRate;
      if(t >= totalSimSeconds){
        _simTimer?.cancel();
        _simTimer = null;
        debugPrint("✅10分钟模拟结束");
        return;
      }

      for (int ch = 0; ch < channelCount; ch++) {
        final uv = _genSimEeg(t, ch);
        _sampleController.add(EegSample(
          rawAdc: (uv * 1000).toInt(),
          rawUv: uv,
          filteredUv: 0,
          timeSec: t,
          channelIndex: ch,
        ));
      }
      _sampleSeq++;

      // 8 路功率：基础值按电极位置给枕区加权，再叠加缓慢的左右起伏与
      // 随机扰动。热力图上会看到枕区偏暖、热区随时间左右迁移。
      // 直接更新 notifier 的值，组件内部自动监听并做 EMA 平滑。
      final List<double> simPower = List<double>.generate(channelCount, (int ch) {
        final double weight = alphaWeights[ch];
        final double slow = sin(2 * pi * 0.08 * t + ch * 0.35);
        final double focus = sin(
          2 * pi * 0.05 * t + (ch.isEven ? 0.0 : 0.8),
        );
        return 6 + 22 * weight + 6 * slow + 4 * focus + _rng.nextDouble() * 2;
      });
      _powerNotifier.value = simPower;
    });
  }

  double _genSimEeg(double t, int channel) {
    final double phaseOff = channel * 0.15;
    // alpha 幅度与地形图用的位置权重一致：枕区通道波形里 10Hz 成分更强。
    final double alphaAmp = 10 + 12 * alphaWeights[channel];
    final double alpha = alphaAmp * sin(2 * pi * 10 * (t + phaseOff));
    final double beta = 7 * sin(2 * pi * 18 * (t + phaseOff * 0.7));
    final double drift = 12 * sin(2 * pi * 0.15 * t);
    final double powerNoise = 4.0 * sin(2 * pi * 50.0 * t);
    final double gaussNoise = (_rng.nextDouble() * 2.0 - 1.0) * 2.5;
    return alpha + beta + drift + powerNoise + gaussNoise;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("EEG 时序波形 + 脑地形图 Demo")),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '8 通道 · ${sampleRate.toInt()}Hz · ${_bandData.title}\n'
              '波形通道与地形图电极一一对应：${channelNames.join(' / ')}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          Expanded(
            flex: 2,
            child: EegWaveChartWidget(
              config: EegWaveConfig(
                sampleRate: sampleRate,
                channelCount: channelCount,
                channelNames: channelNames,
                channelHeight: 36.0,
                displayUvRange: 100,
                notchFreq: 50,
                filterOrder: 4,
                filterWarmupSec: 2.0,
              ),
              sampleStream: _sampleController.stream,
            ),
          ),
          const Divider(),
          Expanded(
            flex: 2,
            child: ClipRRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: BrainHeatMapWidget(
                  initData: _bandData,
                  rawPowerNotifier: _powerNotifier,
                  emaAlpha: 0.2,
                  throttleMs: 250,
                  // painter 已做椭圆裁剪，格子越小内部越细腻；插值计算已优化，
                  // 8 电极下 2px 网格每 250ms 刷新一次仍然流畅。
                  gridStep: 2.0,
                  // 标出 8 个电极名称与实时功率，便于对照上方波形通道。
                  showElectrodeText: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    _sampleController.close();
    _powerNotifier.dispose();
    super.dispose();
  }
}
