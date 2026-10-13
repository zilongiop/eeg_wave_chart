import 'package:flutter_test/flutter_test.dart';
import 'package:eeg_wave_chart/eeg_wave_chart.dart';
import 'package:eeg_wave_chart/eeg_wave_chart_platform_interface.dart';
import 'package:eeg_wave_chart/eeg_wave_chart_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockEegWaveChartPlatform
    with MockPlatformInterfaceMixin
    implements EegWaveChartPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final EegWaveChartPlatform initialPlatform = EegWaveChartPlatform.instance;

  test('$MethodChannelEegWaveChart is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelEegWaveChart>());
  });

  test('getPlatformVersion', () async {
    EegWaveChart eegWaveChartPlugin = EegWaveChart();
    MockEegWaveChartPlatform fakePlatform = MockEegWaveChartPlatform();
    EegWaveChartPlatform.instance = fakePlatform;

    expect(await eegWaveChartPlugin.getPlatformVersion(), '42');
  });
}
