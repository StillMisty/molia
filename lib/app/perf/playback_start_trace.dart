/// 起播端到端埋点（opt-in）。
///
/// 只在 `--dart-define=MOLIA_PERF_TRACE=true` 的构建里生效：正常包不创建
/// Stopwatch、不挂 Timer、不写日志。与 `data_path_trace.dart` 共用
/// `molia.perf` 输出通道，消费方按 `op=play.start` 聚合。
///
/// 口径：`tap → 首声可感` 在桌面 / 移动端都拆成三段：
/// - `resolve_ms`：取链（含音源网络 / LX 脚本 / 本地缓存命中）；
/// - `source_ms`：`setAudioSource`（含播放器打开、缓冲、音频输出准备）；
/// - `play_ms`：`play()` 到位置首次前进（代理「真的有声音在走」）。
///
/// 为什么用「位置首次前进」而不是 `playing=true`：just_audio 的 playing 是
/// **请求态**，`play()` 一调用就可能翻真，此时还可能没完成缓冲；位置前进才
/// 说明解码时钟已经跑起来。代价是桌面 media_kit 的位置流约 200ms 采样一次，
/// 会把首声量多算最多一个采样周期（对 A/B 一致，不影响相对比较）。
library;

import 'dart:async';

import 'data_path_trace.dart';

/// 本次起播实际走的资源路径（轻量枚举，仅用于埋点分桶）。
enum PlaybackCachePath {
  /// 本地文件（下载副本 / 已完整的音频缓存），直接 `file://` 播放。
  file,

  /// 边播边缓存源（`LockCachingAudioSource`）。
  caching,

  /// 直接网络流播（桌面后端 / 缓存源回退）。
  direct;

  String get wireName => switch (this) {
    PlaybackCachePath.file => 'file',
    PlaybackCachePath.caching => 'caching',
    PlaybackCachePath.direct => 'direct',
  };
}

/// 一次起播的耗时记录器；同一时刻最多一个活跃实例。
class PlaybackStartTrace {
  PlaybackStartTrace._(this._trackId) : _watch = Stopwatch()..start() {
    // 兜底：长时间没等到位置前进（缓冲失败 / 用户立刻暂停）也要落一行，
    // 否则这条链路永远缺样本，看起来像「没起播」。
    _timeout = Timer(const Duration(seconds: 60), () => abort('timeout'));
  }

  static const bool enabled = bool.fromEnvironment('MOLIA_PERF_TRACE');

  static PlaybackStartTrace? _active;

  final String _trackId;
  final Stopwatch _watch;
  Timer? _timeout;
  int? _resolveUs;
  int? _sourceUs;
  PlaybackCachePath? _cachePath;
  bool? _prefetched;
  bool _playRequested = false;
  bool _finished = false;

  /// 开始一次起播记录；上一个未完成的记录按 `superseded` 落盘。
  ///
  /// 关闭埋点时返回 null，调用方用 `?.` 即可，不会产生额外分支。
  static PlaybackStartTrace? begin(String trackId) {
    if (!enabled) return null;
    _active?.abort('superseded');
    final trace = PlaybackStartTrace._(trackId);
    _active = trace;
    return trace;
  }

  /// 取链完成（拿到可播放 URL）。
  void markResolved() {
    if (!enabled || _finished) return;
    _resolveUs ??= _watch.elapsedMicroseconds;
  }

  /// `setAudioSource` 完成（播放器已接受资源）。
  ///
  /// [cachePath] / [prefetched] 是本次起播的分桶信息：走本地文件、边播边
  /// 缓存还是直接流播；起播时该曲目的字节预取是否仍在途。只在埋点开启时
  /// 有用，调用方不需要为计算它们额外统计。
  void markSourceSet({PlaybackCachePath? cachePath, bool? prefetched}) {
    if (!enabled || _finished) return;
    _sourceUs ??= _watch.elapsedMicroseconds;
    _cachePath ??= cachePath;
    _prefetched ??= prefetched;
  }

  /// 已把播放请求下发给播放器（`play()` 调用前）。
  ///
  /// 切歌时上一首的位置事件可能晚到；只有 play 之后的位置前进才算「首声」，
  /// 否则新一笔 trace 会被旧曲目的残留位置瞬间完成。
  void markPlayRequested() {
    if (!enabled || _finished) return;
    _playRequested = true;
  }

  /// 位置首次前进：视为「首声」。
  static void firstProgress() {
    if (!enabled) return;
    final active = _active;
    if (active == null || !active._playRequested || active._sourceUs == null) {
      return;
    }
    active.complete();
  }

  /// 当前这一笔失败（异常 / 被取消）。
  static void failCurrent() {
    if (!enabled) return;
    _active?.abort('error');
  }

  void complete() {
    if (!enabled || _finished) return;
    _emit(result: 'ok');
  }

  void abort(String result) {
    if (!enabled || _finished) return;
    _emit(result: result);
  }

  void _emit({required String result}) {
    _finished = true;
    _timeout?.cancel();
    _timeout = null;
    if (identical(_active, this)) _active = null;
    final totalUs = _watch.elapsedMicroseconds;
    final resolveUs = _resolveUs;
    final sourceUs = _sourceUs;
    DataPathTrace.record(
      'play.start',
      Duration(microseconds: totalUs),
      fields: () => {
        'track': _trackId,
        'result': result,
        if (resolveUs != null)
          'resolve_ms': _ms(resolveUs),
        if (sourceUs != null) ...{
          'source_ms': _ms(sourceUs - (resolveUs ?? 0)),
          'play_ms': _ms(totalUs - sourceUs),
        },
        // 路径分桶：file = 本地文件命中，caching = 边播边缓存，
        // direct = 直接网络流播；prefetched = 起播时字节预取仍在途。
        if (_cachePath != null) 'cache_path': _cachePath!.wireName,
        if (_prefetched != null) 'prefetched': _prefetched! ? 1 : 0,
      },
    );
  }

  static double _ms(int microseconds) =>
      (microseconds / 1000 * 100).round() / 100;
}
