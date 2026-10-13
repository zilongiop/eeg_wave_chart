
import 'eeg_wave_chart_platform_interface.dart';
// =====原有导出：时序波形相关 =====
export 'models/wave/eeg_types.dart';
export 'models/wave/ring_buffer.dart';
export 'src/eeg_filter.dart';
export 'src/eeg_downsampler.dart';
export 'src/eeg_bucket_aggregator.dart';
export 'src/eeg_coordinate.dart';
export 'src/eeg_wave_widget.dart';

// =====新增：导出脑地形图模块 =====
export 'models/brain/brain_data.dart';
export 'brain/brain_topo_painter.dart';
export 'brain/brain_topo_widget.dart';

class EegWaveChart {
  Future<String?> getPlatformVersion() {
    return EegWaveChartPlatform.instance.getPlatformVersion();
  }
}
