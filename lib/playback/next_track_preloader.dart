import 'dart:async';

import '../domain/ports/music_source.dart' show PlayableStream;
import '../sources/source_track.dart';
import 'audio_predownload.dart';
import 'audio_predownloader.dart';

/// 一次字节预取尝试（取链中 → 下载中 → 结束）。
///
/// [NextTrackPreloader._speculative] 是「下一首」的投机预取；
/// [NextTrackPreloader._playback] 是已经切到该曲、由预取继续负责缓存写入的
/// 任务。两者可以同时存在：当前曲目的缓存写入不应因为开始预取下一首而被
/// 取消，否则就是「切到正在预取的下一首 → 先取消 → 起播后再重下」。
class _PrefetchAttempt {
  _PrefetchAttempt({required this.trackId, required this.quality});

  final String trackId;
  final String? quality;

  /// 下载任务；取链 / 预下载器判定阶段为 null。
  AudioPredownloadTask? task;

  /// 已被取消或被新目标取代：在途结果一律作废。
  bool cancelled = false;

  /// 已结束或已跳过：不再拥有缓存写入。
  bool settled = false;

  bool get active => !cancelled && !settled;
}

/// 下一首预载：起播后预热下一首的播放直链（命中 CatalogService 取链缓存），
/// 并在平台/策略允许时把音频字节预取到本地缓存。
///
/// 顺序约束：只在「当前曲目真正起播后」调用 [preload]——若在取链前预载，
/// 会与当前曲目的取链在 LX 引擎里抢占，反而拖慢起播。
///
/// 直链预热与字节预取分开门控：移动端后台听歌时仍要拿到下一首地址（切换
/// 不额外等取链），但**不再**一边播一边下载整首下一曲——那会把网络 / 磁盘
/// 长期占在后台，是熄屏功耗最重的一块。
///
/// 失败静默：预载只是优化，真正播放时会走同一取链路径重试。
class NextTrackPreloader {
  NextTrackPreloader({
    required this._resolver,
    this._preferredQuality,
    this._predownloader,
    this._canPredownloadBytes,
  });

  /// 必须返回完整 [PlayableStream]：预取要带上与播放相同的请求头（B 站
  /// 直链离开 `Referer` 会 403），只留 URL 会让预取必然失败。
  final Future<PlayableStream> Function(SourceTrack track, {String? quality})
      _resolver;

  /// 与播放完全同源的音质选择（省流上限由组合根在闭包里套用）。
  final String Function()? _preferredQuality;

  final AudioPredownloader? _predownloader;

  /// 是否允许下载音频字节（null = 允许）。组合根接移动端前后台策略：
  /// 后台只预热直链，不预取字节。
  final bool Function()? _canPredownloadBytes;

  /// 投机预取（目标是下一首）。
  _PrefetchAttempt? _speculative;

  /// 已提升为「当前曲目缓存写入」的预取任务。
  _PrefetchAttempt? _playback;

  /// 最近一次 [preload] 的目标曲目 id（null = 无投机目标或已取消）。
  String? get targetTrackId => _speculative?.trackId;

  /// 是否有已启动、尚未完成的字节预取任务（含已保留为当前曲目的任务）。
  bool get hasPendingTask =>
      _speculative?.task != null || _playback?.task != null;

  /// [track]（同一音质）的缓存写入是否仍由预取负责（取链中或下载中）。
  ///
  /// 播放侧据此避免对同一缓存文件再起一个 `PlayingTrackCacheWriter`。
  bool isCacheWriteInFlight(SourceTrack track, {String? quality}) =>
      _matchingAttempt(track.id, quality) != null;

  /// 预载 [next]（为 null 时仅作废上一次投机目标）。
  Future<void> preload(SourceTrack? next) async {
    _cancelSpeculative();
    if (next == null) return;

    final preferred = _preferredQuality?.call();
    final quality = preferred == null ? null : next.pickQuality(preferred);

    // 当前曲目提升出来的任务，或重复的同目标请求：同一缓存文件不能有
    // 两个 writer，直接跳过，等现有任务落位。
    if (_matchingAttempt(next.id, quality) != null) return;

    final attempt = _PrefetchAttempt(trackId: next.id, quality: quality);
    _speculative = attempt;
    try {
      final stream = await _resolver(next, quality: quality);
      // 已被取消（active=false）才作废；若期间被 [retainForPlayback] 提升为
      // 当前曲目的写入，则继续走完预下载，不能把所有权留下却不下载。
      if (!attempt.active) return;
      // 只预热直链也不浪费：真正切到下一首时 CatalogService 已命中。
      if (_predownloader == null || _canPredownloadBytes?.call() == false) {
        _settle(attempt);
        return;
      }
      final task = await _predownloader.predownload(
        track: next,
        stream: stream,
        quality: quality,
      );
      if (!attempt.active) {
        // 取消 / 被新目标取代发生在预下载器的异步判定里：迟到的任务必须
        // 自己收掉，否则会留下第二个 writer。
        task?.cancel();
        return;
      }
      if (task == null) {
        _settle(attempt);
        return;
      }
      attempt.task = task;
      unawaited(
        task.done.whenComplete(() {
          if (!identical(attempt.task, task)) return;
          attempt.task = null;
          _settle(attempt);
        }).catchError((Object _) {
          // 任务失败只需要释放所有权，不在预载链路里抛异步错误。
        }),
      );
    } catch (_) {
      // 预载失败静默：真正播放时会正常取链。
      _settle(attempt);
    }
  }

  /// 起播 [track] 前处理预取所有权。
  ///
  /// [reuseInFlight] 只在桌面 / 后退到直接流播的会话传 true：目标正是
  /// [track] 时把在途任务保留为「当前曲目缓存写入」，返回 true，调用方
  /// **不得**再启动 `PlayingTrackCacheWriter`。任务落位后缓存文件可供本次
  /// 播放之后的 `localUriFor` 命中。
  ///
  /// 移动端边播边缓存（`LockCachingAudioSource`）自己写同一文件，必须传
  /// false：起播前取消预取，避免双写互相破坏。
  bool retainForPlayback(
    SourceTrack track, {
    required bool reuseInFlight,
    String? quality,
  }) {
    final matching = _matchingAttempt(track.id, quality);
    if (reuseInFlight && matching != null) {
      // 上一首提升出来的写入随切歌作废；保留这一份继续写当前曲目。
      final playback = _playback;
      if (playback != null && !identical(playback, matching)) {
        _cancelAttempt(playback);
      }
      final speculative = _speculative;
      if (speculative != null && !identical(speculative, matching)) {
        _cancelAttempt(speculative);
      }
      if (identical(_speculative, matching)) {
        _speculative = null;
        _playback = matching;
      }
      return true;
    }
    // 移动端 / 目标不匹配：起播前取消，避免与播放侧双写。
    _cancelSpeculative();
    _cancelPlayback();
    return false;
  }

  /// 取消未完成的投机预取（下一首）。
  void cancelPending() {
    _cancelSpeculative();
  }

  /// 取消全部预取（含已保留为当前曲目缓存写入的任务）。
  void cancelAll() {
    _cancelSpeculative();
    _cancelPlayback();
  }

  _PrefetchAttempt? _matchingAttempt(String trackId, String? quality) {
    for (final attempt in [_speculative, _playback]) {
      if (attempt == null) continue;
      if (attempt.trackId == trackId && attempt.quality == quality) {
        return attempt;
      }
    }
    return null;
  }

  void _settle(_PrefetchAttempt attempt) {
    if (!attempt.active) return;
    attempt.settled = true;
    if (identical(_speculative, attempt)) _speculative = null;
    if (identical(_playback, attempt)) _playback = null;
  }

  void _cancelSpeculative() {
    final attempt = _speculative;
    if (attempt != null) _cancelAttempt(attempt);
  }

  void _cancelPlayback() {
    final attempt = _playback;
    if (attempt != null) _cancelAttempt(attempt);
  }

  void _cancelAttempt(_PrefetchAttempt attempt) {
    attempt.cancelled = true;
    attempt.task?.cancel();
    attempt.task = null;
    if (identical(_speculative, attempt)) _speculative = null;
    if (identical(_playback, attempt)) _playback = null;
  }
}
