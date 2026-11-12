import 'dart:async';

/// 轻量全局事件总线
///
/// `lib/blue/` 从其它工程移植过来时依赖业务层的 `EventBusManager`，
/// 这里补一个最小实现，保持 `on<T>()` / `fire()` 两个原有 API 不变：
/// EEG 协议层解析出的帧（[EegSamplesEvent] 等）经它按事件类型分发，
/// 页面订阅自己关心的类型即可。
class EventBusManager {
  EventBusManager._();

  /// 单例
  static final EventBusManager i = EventBusManager._();

  final StreamController<Object> _controller =
      StreamController<Object>.broadcast();

  /// 订阅某一类事件；订阅 [EegEvent] 基类可以收到全部事件
  Stream<T> on<T extends Object>() =>
      _controller.stream.where((Object event) => event is T).cast<T>();

  /// 发布事件。没有监听者时直接丢弃，避免高频 EEG 帧白白排队。
  void fire(Object event) {
    if (_controller.hasListener) _controller.add(event);
  }
}
