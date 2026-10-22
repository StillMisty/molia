/// AI 电台的队列参与视图：从**当前播放快照**派生，不持有任何计数器。
///
/// 所有入队路径（起播 / 全部加入 / 历史加入 / 手动补批 / 静默补歌）都从这里
/// 拿「是否已在队」「只追加缺失项」，低水位也读同一个 `upcoming`。派生值随
/// 队列与播放位置自动前进，避免另存一份会漂移的计数。
library;

import '../../domain/models/playback.dart';

/// 一次快照对应的队列参与视图。
class AiRadioQueue {
  AiRadioQueue({
    required List<String> queueUris,
    required this.currentIndex,
  })  : queueUris = List.unmodifiable(queueUris),
        _queueUriSet = Set.unmodifiable(queueUris);

  /// 从 live 快照构造；调用方每次要用最新快照新建，不要长期缓存。
  factory AiRadioQueue.of(PlaybackSnapshot snapshot) => AiRadioQueue(
        queueUris: [for (final track in snapshot.queue) track.id.uri],
        currentIndex: snapshot.currentIndex,
      );

  /// 队列顺序（下标与播放快照一致）。
  final List<String> queueUris;
  final int currentIndex;
  final Set<String> _queueUriSet;

  int get queueLength => queueUris.length;

  /// 当前曲目之后还剩多少首（低水位判定口径，不含当前）。
  int get upcoming {
    if (currentIndex < 0) return queueLength;
    final remaining = queueLength - currentIndex - 1;
    return remaining < 0 ? 0 : remaining;
  }

  /// [uris] 中还在队列「当前及之后」的数量。
  ///
  /// 页面展示「队列中还有 N 首推荐」：已经播过的 AI 曲目不再算作排队中，
  /// 队列被替换 / 曲目被移除时也会自然减少——这正是旧计数器漂移的地方。
  int queuedAmong(Iterable<String> uris) {
    final members = uris is Set<String> ? uris : uris.toSet();
    if (members.isEmpty) return 0;
    final start = currentIndex < 0 ? 0 : currentIndex;
    var count = 0;
    for (var i = start; i < queueUris.length; i++) {
      if (members.contains(queueUris[i])) count++;
    }
    return count;
  }

  /// 是否已在队（起播时决定「跳过去」还是「接管队列」）。
  bool contains(String uri) => _queueUriSet.contains(uri);

  /// 只保留还不在队列里的项（不改变入参顺序）。
  List<T> missing<T>(Iterable<T> items, String Function(T) uriOf) => [
        for (final item in items)
          if (!contains(uriOf(item))) item,
      ];
}
