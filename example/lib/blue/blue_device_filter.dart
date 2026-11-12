/// 扫描结果过滤规则
///
/// 附近蓝牙设备很多，业务页面只展示「名称包含 [DeviceFilter.nameKeyword]」的
/// 自家 EEG 设备，形如 `16CH-ASI-90C7F60819` 或 `16CH_ASI_8DBFA7`。
///
/// 匹配时忽略名称里的 `-` / `_` 等分隔符，且大小写不敏感。
/// 蓝牙页（调试）与添加设备搜索页共用同一套规则。
abstract class DeviceFilter {
  /// 设备广播名关键字（大小写不敏感；连字符等分隔符在匹配时被忽略）
  static const String nameKeyword = '16CH-ASI';

  /// 归一化：转大写并去掉 `-` / `_` / 空格，避免设备名分隔符不一致导致漏匹配
  static String _normalize(String s) =>
      s.toUpperCase().replaceAll(RegExp(r'[-_\s]'), '');

  /// 判断一个名称是否命中过滤规则
  static bool matches(String name) =>
      _normalize(name).contains(_normalize(nameKeyword));
}
