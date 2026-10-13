class Electrode {
  final String name;
  final double dx;
  final double dy;
  double value;

  Electrode({
    required this.name,
    required this.dx,
    required this.dy,
    this.value = 0,
  });
}

class BandData {
  final String title;
  final List<Electrode> electrodes;
  double minVal;
  double maxVal;
  int revision;

  BandData({
    required this.title,
    required this.electrodes,
    this.minVal = -27,
    this.maxVal = 30,
    this.revision = 0,
  });

  void updatePowerList(List<double> powerList) {
    assert(powerList.length == electrodes.length);
    for (int i = 0; i < electrodes.length; i++) {
      electrodes[i].value = powerList[i];
    }
    revision++;
  }
}
