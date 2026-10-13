import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'eeg_wave_chart_platform_interface.dart';

/// An implementation of [EegWaveChartPlatform] that uses method channels.
class MethodChannelEegWaveChart extends EegWaveChartPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('eeg_wave_chart');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
