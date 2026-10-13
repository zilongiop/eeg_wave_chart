import 'eeg_types.dart';

class EegRingBuffer {
  final int capacity;
  final List<EegSample?> _buffer;
  int _writePos = 0;

  EegRingBuffer(this.capacity) : _buffer = List.filled(capacity, null);

  void push(EegSample sample) {
    _buffer[_writePos] = sample;
    _writePos = (_writePos + 1) % capacity;
  }

  /// 按时间升序遍历全部有效样本。
  ///
  /// 长窗口下（如 30s/格 × 5 格 = 150 秒 × 250Hz × 多导联）缓冲区可达十几万
  /// 条，若每帧 getAll() 新建这么大的 List，GC 压力会直接表现为掉帧卡顿。
  /// 热路径应改用本方法配合复用的容器，避免每帧重建大列表。
  void forEach(void Function(EegSample sample) visit) {
    for (int i = 0; i < capacity; i++) {
      final EegSample? s = _buffer[(_writePos + i) % capacity];
      if (s != null) {
        visit(s);
      }
    }
  }

  /// 获取全部有效样本，按时间升序
  List<EegSample> getAll() {
    final List<EegSample> res = [];
    for (int i = 0; i < capacity; i++) {
      final idx = (_writePos + i) % capacity;
      final s = _buffer[idx];
      if (s != null) res.add(s);
    }
    return res;
  }

  void clear() {
    _buffer.fillRange(0, capacity, null);
    _writePos = 0;
  }
}
