import '../sources/source_track.dart';

/// 播放顺序（played order）栈：记录实际播放过的队列下标。
///
/// 与队列本身解耦：只持有下标，[tracksOf] 按需还原曲目。语义由
/// `LocalPlaybackService` 消费：
/// - [record]：切换到不同曲目时压入「离开的」下标；栈深上限 [maxEntries]；
/// - [peekPrevious] / [popPrevious]：快照展示读最近一首（不弹出）；执行切歌
///   弹出消费；空栈返回 null（调用方回退到队列前一位）；
/// - [clear]：新队列 / 停止播放时清空。
class PlaybackOrder {
  PlaybackOrder({this.maxEntries = 100});

  final int maxEntries;

  final List<int> _indices = [];

  bool get isEmpty => _indices.isEmpty;

  void record(int index) {
    _indices.add(index);
    if (_indices.length > maxEntries) {
      _indices.removeAt(0);
    }
  }

  /// 已播放顺序的最近一首（不弹出）；空栈返回 null（调用方回退到队列前一位）。
  int? peekPrevious() => _indices.isEmpty ? null : _indices.last;

  int? popPrevious() => _indices.isEmpty ? null : _indices.removeLast();

  void clear() => _indices.clear();

  /// 按队列还原播放顺序（最近在后）；越界下标（队列已被替换）被忽略。
  List<SourceTrack> tracksOf(List<SourceTrack> queue) => List.unmodifiable([
        for (final index in _indices)
          if (index >= 0 && index < queue.length) queue[index],
      ]);
}
