import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'eeg_wave_chart_method_channel.dart';

abstract class EegWaveChartPlatform extends PlatformInterface {
  /// Constructs a EegWaveChartPlatform.
  EegWaveChartPlatform() : super(token: _token);

  static final Object _token = Object();

  static EegWaveChartPlatform _instance = MethodChannelEegWaveChart();

  /// The default instance of [EegWaveChartPlatform] to use.
  ///
  /// Defaults to [MethodChannelEegWaveChart].
  static EegWaveChartPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [EegWaveChartPlatform] when
  /// they register themselves.
  static set instance(EegWaveChartPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
