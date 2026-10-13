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
  static const int channelCount = 4;
  static const double totalSimSeconds = 10 * 60; //10分钟模拟
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

    final electrodes = [
      Electrode(name: "Fp1", dx: 0.20, dy: 0.15),
      Electrode(name: "Fp2", dx: 0.80, dy: 0.15),
      Electrode(name: "C3", dx: 0.25, dy: 0.55),
      Electrode(name: "C4", dx: 0.75, dy: 0.55),
    ];
    _bandData = BandData(
      title: "Alpha 8‑13Hz",
      electrodes: electrodes,
      minVal: 0,
      maxVal: 40,
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

      //直接更新notifier的值，组件内部自动监听
      List<double> simPower = List.generate(4, (i) {
        return 10 + 20 * sin(0.2 * t + i) + _rng.nextDouble() * 3;
      });
      _powerNotifier.value = simPower;
    });
  }

  double _genSimEeg(double t, int channel) {
    final double phaseOff = channel * 0.35;
    final double alpha = 18 * sin(2 * pi * 10 * (t + phaseOff));
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
        children: [
          const SizedBox(height: 12),
          Expanded(
            flex: 2,
            child: EegWaveChartWidget(
              config: EegWaveConfig(
                sampleRate: sampleRate,
                channelCount: channelCount,
                notchFreq: 50,
                filterOrder: 4,
              ),
              sampleStream: _sampleController.stream,
            ),
          ),
          const Divider(),
          Expanded(
            flex: 2,
            child: ClipRRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX:5,sigmaY:5),child:  BrainHeatMapWidget(
              initData: _bandData,
              rawPowerNotifier: _powerNotifier, //✅传入通知器
              emaAlpha: 0.2,
              throttleMs: 250,
              gridStep: 2.0,
              showElectrodeText: false,
            ),),),
          )
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
