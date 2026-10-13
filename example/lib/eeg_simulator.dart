import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 模拟器产生的一帧数据：某一时刻全部导联的原始幅值。
///
/// 刻意与插件的 [EegSample] 解耦，模拟器只负责「信号长什么样」。
@immutable
class EegSimFrame {
  const EegSimFrame({
    required this.timeMs,
    required this.rawSamplesUv,
  });

  /// 相对起点的时间（毫秒）。
  final double timeMs;

  /// 各导联的原始幅值（微伏）。
  final List<double> rawSamplesUv;
}

/// 单个神经电节律分量（正弦合成）。
@immutable
class EegRhythm {
  const EegRhythm({
    required this.name,
    required this.freqHz,
    required this.amplitudeUV,
    this.phase = 0,
  });

  /// 节律名称，仅用于说明该分量的含义。
  final String name;

  /// 中心频率（Hz）。
  final double freqHz;

  /// 幅值（微伏）。
  final double amplitudeUV;

  /// 初相位（弧度）。
  final double phase;
}

/// 一个导联的合成配方。
@immutable
class EegChannelProfile {
  const EegChannelProfile({
    required this.name,
    required this.color,
    required this.rhythms,
    this.noiseUV = 4,
    this.mainsUV = 8,
    this.eyeBlinkUV = 0,
    this.spikeUV = 0,
  });

  /// 导联名称（10-20 系统）。
  final String name;

  /// 绘制颜色。
  final Color color;

  /// 参与合成的节律分量。
  final List<EegRhythm> rhythms;

  /// 白噪声强度（微伏）。
  final double noiseUV;

  /// 50Hz 工频干扰强度（微伏），会被插件的陷波器抑制。
  final double mainsUV;

  /// 眨眼伪迹峰值（微伏），0 表示该导联不产生伪迹。
  final double eyeBlinkUV;

  /// 棘波放电峰值（微伏），0 表示该导联不产生伪迹。
  final double spikeUV;
}

/// 伪迹类型。
enum _ArtifactKind { eyeBlink, spike }

/// 一次伪迹事件。
class _Artifact {
  const _Artifact({
    required this.channelIndex,
    required this.startMs,
    required this.durationMs,
    required this.amplitudeUV,
    required this.kind,
  });

  final int channelIndex;
  final double startMs;
  final double durationMs;
  final double amplitudeUV;
  final _ArtifactKind kind;

  bool get isBlink => kind == _ArtifactKind.eyeBlink;

  int get pulseCount => (durationMs / 110).round().clamp(3, 12);

  /// 归一化位置 u ∈ [0, 1] 处的伪迹幅值。
  double amplitudeAt(double u) {
    if (isBlink) {
      // 眨眼是一次单向的大幅慢偏转。
      return amplitudeUV * math.sin(math.pi * u);
    }
    // 棘波：一串窄脉冲。
    final double local = (u * pulseCount) % 1.0;
    if (local >= 0.18) {
      return 0;
    }
    return amplitudeUV * math.sin(math.pi * local / 0.18);
  }
}

/// 多导联 EEG 信号模拟器。
///
/// 采用「按采样序号即时求值」的方式（而非一次性生成全部样本），
/// 因此即使总时长长达 10 分钟也不会额外占用内存。
class EegSimulator {
  EegSimulator({
    required this.profiles,
    this.sampleRate = 250,
    this.totalDuration = const Duration(minutes: 10),
    this.seed = 20261008,
  }) : _random = math.Random(seed) {
    _stepMs = 1000.0 / sampleRate;
    _totalMs = totalDuration.inMilliseconds.toDouble();
    _buildPhaseNoise();
    _artifacts = _buildArtifacts();
  }

  /// 参与合成的导联配方。
  final List<EegChannelProfile> profiles;

  /// 采样率（Hz）。
  final int sampleRate;

  /// 总时长。
  final Duration totalDuration;

  /// 随机种子，保证每次运行波形一致。
  final int seed;

  final math.Random _random;

  late final double _stepMs;
  late final double _totalMs;
  late final List<List<double>> _phaseNoise;
  late final List<double> _modulationHz;
  late final List<_Artifact> _artifacts;

  int _nextIndex = 0;

  /// 已播放到的数据时间（毫秒）。
  double get currentTimeMs => _nextIndex * _stepMs;

  /// 总时长（毫秒）。
  double get totalTimeMs => _totalMs;

  /// 播放进度，取值 [0, 1]。
  double get progress =>
      _totalMs <= 0 ? 0 : (currentTimeMs / _totalMs).clamp(0.0, 1.0);

  /// 是否播放到末尾。
  bool get isFinished => currentTimeMs >= _totalMs;

  /// `mm:ss / mm:ss` 形式的进度文本。
  String get progressText => '${_format(currentTimeMs)} / ${_format(_totalMs)}';

  static String _format(double ms) {
    final int totalSec = (ms / 1000).floor();
    final String mm = (totalSec ~/ 60).toString().padLeft(2, '0');
    final String ss = (totalSec % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  void _buildPhaseNoise() {
    _phaseNoise = List<List<double>>.generate(
      profiles.length,
      (int ci) => List<double>.generate(
        profiles[ci].rhythms.length,
        (_) => _random.nextDouble() * 2 * math.pi,
        growable: false,
      ),
      growable: false,
    );
    // 慢速幅度调制，让波形呈现出自然的强弱起伏。
    _modulationHz = List<double>.generate(
      profiles.length,
      (_) => 0.03 + _random.nextDouble() * 0.07,
      growable: false,
    );
  }

  List<_Artifact> _buildArtifacts() {
    final List<_Artifact> artifacts = <_Artifact>[];
    for (int ci = 0; ci < profiles.length; ci++) {
      final EegChannelProfile p = profiles[ci];

      if (p.eyeBlinkUV > 0) {
        double t = 5000 + _random.nextDouble() * 6000;
        while (t < _totalMs) {
          artifacts.add(
            _Artifact(
              channelIndex: ci,
              startMs: t,
              durationMs: 220 + _random.nextDouble() * 200,
              amplitudeUV: p.eyeBlinkUV * (0.7 + _random.nextDouble() * 0.5),
              kind: _ArtifactKind.eyeBlink,
            ),
          );
          t += 9000 + _random.nextDouble() * 19000;
        }
      }

      if (p.spikeUV > 0) {
        double t = 20000 + _random.nextDouble() * 40000;
        while (t < _totalMs) {
          artifacts.add(
            _Artifact(
              channelIndex: ci,
              startMs: t,
              durationMs: 900 + _random.nextDouble() * 900,
              amplitudeUV: p.spikeUV * (0.8 + _random.nextDouble() * 0.4),
              kind: _ArtifactKind.spike,
            ),
          );
          t += 45000 + _random.nextDouble() * 45000;
        }
      }
    }
    return artifacts;
  }

  /// 取第 [index] 个采样点（不限 whose），不推进内部游标。
  EegSimFrame _frameAt(int index) {
    final double tMs = index * _stepMs;
    final double tSec = index / sampleRate;
    final List<double> values =
        List<double>.filled(profiles.length, 0, growable: false);

    for (int ci = 0; ci < profiles.length; ci++) {
      final EegChannelProfile p = profiles[ci];
      final List<EegRhythm> rhythms = p.rhythms;
      double value = 0;

      for (int ri = 0; ri < rhythms.length; ri++) {
        final EegRhythm r = rhythms[ri];
        final double modulation = 0.65 +
            0.35 *
                math.sin(
                  2 * math.pi * _modulationHz[ci] * tSec + ri * 1.7,
                );
        value += r.amplitudeUV *
            modulation *
            math.sin(
              2 * math.pi * r.freqHz * tSec + r.phase + _phaseNoise[ci][ri],
            );
      }

      // 50Hz 工频干扰及其 100Hz 谐波。
      value +=
          p.mainsUV * math.sin(2 * math.pi * 50 * tSec + _phaseNoise[ci].last);
      value += p.mainsUV * 0.3 * math.sin(2 * math.pi * 100 * tSec);

      // 白噪声。
      value += (_random.nextDouble() * 2 - 1) * p.noiseUV;

      // 伪迹叠加。
      for (final _Artifact a in _artifacts) {
        if (a.channelIndex != ci) {
          continue;
        }
        final double u = (tMs - a.startMs) / a.durationMs;
        if (u < 0 || u > 1) {
          continue;
        }
        value += a.amplitudeAt(u);
      }

      values[ci] = value;
    }

    return EegSimFrame(timeMs: tMs, rawSamplesUv: values);
  }

  /// 推进到 [targetMs] 时刻，返回期间产生的全部采样帧。
  ///
  /// 单次最多返回 [maxFramesPerBatch] 帧，避免长时间挂后台再回到前台时
  /// 一次性补齐大量样本造成卡顿。
  List<EegSimFrame> takeFramesUpTo(
    double targetMs, {
    int maxFramesPerBatch = 400,
  }) {
    final List<EegSimFrame> frames = <EegSimFrame>[];
    while (_nextIndex * _stepMs < targetMs &&
        _nextIndex * _stepMs < _totalMs &&
        frames.length < maxFramesPerBatch) {
      frames.add(_frameAt(_nextIndex));
      _nextIndex++;
    }
    return frames;
  }

  /// 回到起点，可重复播放同一段波形。
  void reset() {
    _nextIndex = 0;
  }

  /// 默认 6 导联：额区(Fp)、中央区(C)、枕区(O)。
  static List<EegChannelProfile> defaultProfiles() =>
      const <EegChannelProfile>[
        EegChannelProfile(
          name: 'Fp1',
          color: Color(0xFF64B5F6),
          rhythms: <EegRhythm>[
            EegRhythm(name: 'delta', freqHz: 1.8, amplitudeUV: 26),
            EegRhythm(name: 'theta', freqHz: 6.2, amplitudeUV: 12, phase: 0.7),
            EegRhythm(name: 'beta', freqHz: 18, amplitudeUV: 5, phase: 1.4),
          ],
          noiseUV: 5,
          mainsUV: 10,
          eyeBlinkUV: 95,
          spikeUV: 45,
        ),
        EegChannelProfile(
          name: 'Fp2',
          color: Color(0xFF4DD0E1),
          rhythms: <EegRhythm>[
            EegRhythm(
              name: 'delta',
              freqHz: 2.1,
              amplitudeUV: 24,
              phase: 0.3,
            ),
            EegRhythm(
              name: 'theta',
              freqHz: 5.8,
              amplitudeUV: 13,
              phase: 1.1,
            ),
            EegRhythm(name: 'beta', freqHz: 20, amplitudeUV: 5, phase: 0.2),
          ],
          noiseUV: 5,
          mainsUV: 10,
          eyeBlinkUV: 90,
          spikeUV: 40,
        ),
        EegChannelProfile(
          name: 'C3',
          color: Color(0xFF81C784),
          rhythms: <EegRhythm>[
            EegRhythm(
              name: 'delta',
              freqHz: 2.4,
              amplitudeUV: 18,
              phase: 0.9,
            ),
            EegRhythm(
              name: 'theta',
              freqHz: 7.1,
              amplitudeUV: 10,
              phase: 1.6,
            ),
            EegRhythm(
              name: 'alpha',
              freqHz: 10.5,
              amplitudeUV: 8,
              phase: 0.4,
            ),
            EegRhythm(name: 'beta', freqHz: 22, amplitudeUV: 7, phase: 2.1),
          ],
          noiseUV: 4,
          mainsUV: 8,
          spikeUV: 70,
        ),
        EegChannelProfile(
          name: 'C4',
          color: Color(0xFFFFD54F),
          rhythms: <EegRhythm>[
            EegRhythm(
              name: 'delta',
              freqHz: 2.2,
              amplitudeUV: 17,
              phase: 1.8,
            ),
            EegRhythm(
              name: 'theta',
              freqHz: 6.8,
              amplitudeUV: 11,
              phase: 0.5,
            ),
            EegRhythm(
              name: 'alpha',
              freqHz: 11.2,
              amplitudeUV: 8,
              phase: 1.3,
            ),
            EegRhythm(name: 'beta', freqHz: 21, amplitudeUV: 7, phase: 0.6),
          ],
          noiseUV: 4,
          mainsUV: 8,
          spikeUV: 65,
        ),
        EegChannelProfile(
          name: 'O1',
          color: Color(0xFFBA68C8),
          rhythms: <EegRhythm>[
            EegRhythm(
              name: 'delta',
              freqHz: 1.5,
              amplitudeUV: 16,
              phase: 2.2,
            ),
            EegRhythm(name: 'theta', freqHz: 5.4, amplitudeUV: 8, phase: 0.9),
            EegRhythm(
              name: 'alpha',
              freqHz: 10.2,
              amplitudeUV: 24,
              phase: 1.7,
            ),
            EegRhythm(name: 'beta', freqHz: 17, amplitudeUV: 4, phase: 2.6),
          ],
          noiseUV: 4,
          mainsUV: 8,
        ),
        EegChannelProfile(
          name: 'O2',
          color: Color(0xFFF06292),
          rhythms: <EegRhythm>[
            EegRhythm(name: 'delta', freqHz: 1.6, amplitudeUV: 15, phase: 0.1),
            EegRhythm(name: 'theta', freqHz: 5.6, amplitudeUV: 9, phase: 1.9),
            EegRhythm(
              name: 'alpha',
              freqHz: 9.8,
              amplitudeUV: 26,
              phase: 0.8,
            ),
            EegRhythm(name: 'beta', freqHz: 16, amplitudeUV: 4, phase: 1.2),
          ],
          noiseUV: 4,
          mainsUV: 8,
        ),
      ];
}
