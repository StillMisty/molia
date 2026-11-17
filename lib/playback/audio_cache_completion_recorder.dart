/// 独立缓存完成记录器：把「缓存写完 → 写本地索引」从播放服务的当前曲目
/// 生命周期里拿出来。
///
/// 移动端边播边缓存（`LockCachingAudioSource`）的下载在切歌后仍可能继续；
/// 若完成监听随旧源取消，文件已完整落位却不会写索引。本 recorder 由 app
/// 生命周期持有，切歌不取消订阅；只在完成 / 失败 / 超时 / dispose 时清理。
///
/// 有界：每个 handle 有超时（默认 10 分钟），并限制同时 pending 的数量；
/// 超时或超限时主动 `cancel()`，避免下载卡死时长期持有订阅。
library;

import 'dart:async';
import 'dart:collection';

import '../sources/source_track.dart';
import 'audio_cache_completion.dart';

class AudioCacheCompletionRecorder {
  AudioCacheCompletionRecorder({
    required this._onCompleted,
    this.timeout = const Duration(minutes: 10),
    this.maxPending = 8,
  }) : assert(maxPending > 0),
       assert(timeout > Duration.zero);

  /// 缓存最终文件确认写完后的上报口（组合根接 `LocalCacheIndexStore`）。
  final void Function(SourceTrack track) _onCompleted;

  /// 单个 handle 的最长等待时间；超时取消并丢弃。
  final Duration timeout;

  /// 同时保留的 pending handle 上限；超过时取消最旧的一个。
  final int maxPending;

  /// pending handle → 超时计时器（插入顺序 = 记录顺序，便于淘汰最旧）。
  final LinkedHashMap<CachingAudioSourceHandle, Timer> _pending =
      LinkedHashMap<CachingAudioSourceHandle, Timer>();

  bool _disposed = false;

  /// 当前仍在等待完成的 handle 数（测试 / 诊断用）。
  int get pendingCount => _pending.length;

  /// 记录一次缓存源完成。切歌 / 卸载源不需要、也不应该取消它。
  void record(SourceTrack track, CachingAudioSourceHandle handle) {
    if (_disposed) {
      handle.cancel();
      return;
    }
    if (_pending.containsKey(handle)) return;

    // 有界：超出上限先取消最旧的 pending（它通常已经被用户跳过）。
    while (_pending.length >= maxPending) {
      final oldest = _pending.keys.first;
      _settle(oldest);
      oldest.cancel();
    }

    late final Timer timer;
    timer = Timer(timeout, () {
      if (!_pending.containsKey(handle)) return;
      _settle(handle);
      handle.cancel();
    });
    _pending[handle] = timer;

    unawaited(
      handle.completed.then((completed) {
        // 已被超时 / dispose / 上限淘汰：迟到的完成不再上报。
        if (!_pending.containsKey(handle)) return;
        _settle(handle);
        if (completed && !_disposed) _onCompleted(track);
      }),
    );
  }

  void _settle(CachingAudioSourceHandle handle) {
    _pending.remove(handle)?.cancel();
  }

  /// 取消全部 pending；app 退出 / 服务销毁时调用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final handles = _pending.keys.toList(growable: false);
    for (final timer in _pending.values) {
      timer.cancel();
    }
    _pending.clear();
    for (final handle in handles) {
      handle.cancel();
    }
  }
}
