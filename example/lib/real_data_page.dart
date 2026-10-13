import 'dart:async';

import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'eeg_log_parser.dart';

/// 回放真实采集的 EEG 日志（assets/eeg_sample.log）。
///
/// 数据概况：500Hz、8 通道，但只有第 7、8 通道接了信号——标准是
/// 1mV(峰峰 2mV) 的 5Hz 正弦；其余通道饱和在 24 位上限附近，属于未连接
/// 状态，画出来只是一条直线，所以这里只回放有数据的两路。
class RealDataPage extends StatefulWidget {
  const RealDataPage({super.key});

  @override
  State<RealDataPage> createState() => _RealDataPageState();
}

/// 量程档位（µV）。信号滤波后约 ±1000µV，默认取 1200 留余量。
const List<double> _rangeOptions = <double>[100, 500, 1200];

class _RealDataPageState extends State<RealDataPage>
    with SingleTickerProviderStateMixin {
  late final StreamController<EegSample> _sampleController;
  Ticker? _ticker;
  final Stopwatch _clock = Stopwatch();

  EegLogData? _data;
  String? _error;
  bool _loading = true;
  bool _running = false;
  int _emitted = 0;

  double _uvRange = 1200.0;
  int _restartToken = 0;

  @override
  void initState() {
    super.initState();
    _sampleController = StreamController<EegSample>.broadcast();
    _loadAndPlay();
  }

  Future<void> _loadAndPlay() async {
    try {
      final String text = await rootBundle.loadString('assets/eeg_sample.log');
      final EegLogData data = EegLogParser.parse(text);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
      _start();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _start() {
    if (_data == null || _running) return;
    _clock.reset();
    _clock.start();
    _emitted = 0;
    setState(() => _running = true);
    _ticker ??= createTicker((_) => _emitDueSamples());
    _ticker!.start();
  }

  void _pause() {
    if (!_running) return;
    _clock.stop();
    _ticker?.stop();
    setState(() => _running = false);
  }

  void _restart() {
    _pause();
    _restartToken++;
    setState(() {});
    _start();
  }

  /// 用墙钟推算应发出的样本数，避免靠定时器计数导致数据忽多忽少。
  void _emitDueSamples() {
    final EegLogData? data = _data;
    if (!_running || data == null) return;

    final double elapsedSec = _clock.elapsedMicroseconds / 1000000.0;
    int due = (elapsedSec * data.sampleRate).floor() - _emitted;
    if (due <= 0) return;
    if (due > 600) {
      due = 600; // 落后太多时限制单帧补发量
    }

    int sent = 0;
    for (int i = 0; i < due; i++) {
      final int idx = _emitted + i;
      if (idx >= data.sampleCount) {
        _pause();
        return;
      }
      final double t = idx / data.sampleRate;
      for (int ch = 0; ch < data.channels.length; ch++) {
        _sampleController.add(
          EegSample(
            rawAdc: 0,
            rawUv: data.channels[ch][idx],
            filteredUv: 0,
            timeSec: t,
            channelIndex: ch,
          ),
        );
      }
      sent++;
    }
    _emitted += sent;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    _sampleController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('真实采集数据回放'),
        actions: <Widget>[
          IconButton(
            icon: Icon(_running ? Icons.pause : Icons.play_arrow),
            onPressed: _running ? _pause : _start,
          ),
          IconButton(icon: const Icon(Icons.replay), onPressed: _restart),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('加载失败：$_error'));
    }
    final EegLogData data = _data!;
    final bool clipped = _uvRange < 1000.0; // 信号峰峰约 2000µV

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '采样率 ${data.sampleRate.toInt()}Hz | '
            '时长 ${data.durationSec.toStringAsFixed(1)}s | '
            '样本 ${data.sampleCount} | '
            '跳过坏帧 ${data.skippedFrames}\n'
            '通道 7/8 为 1mV 5Hz 正弦；其余通道饱和未接入，不显示',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                const Text('量程'),
                const SizedBox(width: 8),
                for (final double r in _rangeOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('±${r.toInt()}µV'),
                      selected: _uvRange == r,
                      onSelected: (_) => setState(() {
                        _uvRange = r;
                        _restartToken++;
                      }),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (clipped)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4, right: 12),
            child: Text(
              '提示：当前量程 ±${_uvRange.toInt()}µV 小于信号幅度（约 ±1000µV），'
              '波形顶部会被削平，看起来像重叠。',
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        const SizedBox(height: 8),
        SizedBox(
          height: 200,
          child: EegWaveChartWidget(
            // 改量程/重播都要重建，让滤波器与聚合器从头开始。
            key: ValueKey<int>(_restartToken),
            config: EegWaveConfig(
              sampleRate: data.sampleRate,
              channelCount: 2,
              windowDuration: 5.0,
              xAxisInterval: 1.0,
              xAxisDivisions: 5,
              displayUvRange: _uvRange,
              // 真实数据带几 mV 直流偏移，靠高通去掉；使用默认预热避免启动瞬态。
              channelNames: const <String>['CH7', 'CH8'],
              channelHeight: 90.0,
            ),
            sampleStream: _sampleController.stream,
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            _running
                ? '正在回放 ${(_emitted / data.sampleRate).toStringAsFixed(1)}s'
                : '已暂停（共 ${data.durationSec.toStringAsFixed(1)}s）',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
      ],
    );
  }
}
