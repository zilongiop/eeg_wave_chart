class EegSample {
  /// 原始24bit ADC值
  final int rawAdc;

  /// 转换成微伏 uv
  final double rawUv;

  /// 滤波之后，仅绘图使用
  final double filteredUv;

  /// 采样点时间，单位秒
  final double timeSec;

  /// 通道索引 0‑15
  final int channelIndex;

  EegSample({
    required this.rawAdc,
    required this.rawUv,
    required this.filteredUv,
    required this.timeSec,
    required this.channelIndex,
  });
}

/// 插件配置参数
class EegWaveConfig {
  /// 采样率 Hz，支持250 /500 /1000
  final double sampleRate;

  /// 波形窗口总时长，固定25秒
  final double windowDuration;

  /// Y轴显示正负微伏
  final double displayUvRange;

  /// 波形增益
  final double gain;

  /// 通道数量
  final int channelCount;

  /// 陷波频率，国内50，海外60
  final double notchFreq;

  /// 滤波器阶数 2 /4；低端设备填2，高端填4
  final int filterOrder;

  /// UI最大渲染帧率
  final int uiFps;

  /// 各通道名称，显示在左侧坐标轴；为空时回退成 CH1、CH2…
  final List<String> channelNames;

  /// 单个通道的绘制高度（像素）。父级约束宽松时用它推算控件总高，
  /// 父级 Expanded 时以父级高度为准。
  final double channelHeight;

  /// 单通道绘图点数。每个点是该段时间内所有样本的平均值，因此这个值
  /// 就是屏幕上的点数：越大越贴近原始波形，越小越平滑、绘制也越省。
  /// 600 对应 10s 窗口下约 0.017s 一个点，10Hz 的 α 节律每周期约 6 个点。
  final int maxSpotsPerChannel;

  /// 是否显示坐标轴（左：通道名，下：时间）
  final bool showAxisTitles;

  /// X 轴每一格代表的时间（秒/格），即相邻两个时间刻度之间的间隔。
  ///
  /// 这才是通常说的「走纸速度 / 时基」。<= 0 时自动取
  /// [windowDuration] / [xAxisDivisions]。
  final double xAxisInterval;

  /// 窗口横跨多少格。
  ///
  /// 窗口总时长 = [xAxisInterval] × [xAxisDivisions]，这样切换「每格时间」
  /// 时屏幕上的刻度数量保持不变，只是每格代表的时间变长或变短。
  final int xAxisDivisions;

  /// 滤波器预热时长（秒）。
  ///
  /// 因果 IIR 滤波器从零状态启动时，最初若干秒的输出幅度会偏大——实测第 1
  /// 个 8 秒循环的峰峰值比稳态高约 8%，看上去就是「开头幅度大、后面被
  /// 压扁」。这段时间的数据仍然喂给滤波器，但**不产出绘制点、也不推进
  /// 窗口**，等滤波器进入稳态后才开始画，波形从第一帧起幅度就稳定。
  ///
  /// 默认 8 秒，正好覆盖一个完整的信号循环，可保证画出来的每一个循环
  /// 幅度都一致。代价是预热期内没有任何波形，左边界保持不动。设为 0
  /// 则关闭预热。
  final double filterWarmupSec;

  /// 每个 X 轴刻度格取几个坐标点。
  ///
  /// 每个点的 Y 值是该段时间内所有样本的**平均值**，相邻点之间用平滑曲线
  /// 过渡。
  ///
  /// 默认 0 = 不按刻度格聚合，改用 [maxSpotsPerChannel] 自适应分桶（一屏
  /// 数百个点），这样能保留 α 这类节律的形态。
  ///
  /// 设成 1 可以让每格只出一个平均值点，波形最平滑，但要注意：桶宽一旦
  /// 覆盖整数个振荡周期，正负样本就会互相抵消。实测 2s/格时聚合后峰峰值
  /// 从 59.8µV 掉到 1.0µV，波形退化成一条平线。要在平滑和保真之间取舍，
  /// 取 50~100。
  final int spotsPerDivision;

  const EegWaveConfig({
    required this.sampleRate,
    this.windowDuration = 25.0,
    this.displayUvRange = 100.0,
    this.gain = 1.0,
    required this.channelCount,
    this.notchFreq = 50.0,
    this.filterOrder = 4,
    this.uiFps = 25,
    this.channelNames = const <String>[],
    this.channelHeight = 80.0,
    this.maxSpotsPerChannel = 1200,
    this.showAxisTitles = true,
    this.xAxisInterval = 0.0,
    this.xAxisDivisions = 5,
    this.spotsPerDivision = 0,
    this.filterWarmupSec = 8.0,
  });
}
