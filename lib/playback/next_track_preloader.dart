import '../domain/ports/music_source.dart' show PlayableStream;
import '../sources/source_track.dart';
import 'audio_predownload.dart';
import 'audio_predownloader.dart';

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

  /// 请求代数：新请求/取消都会自增，令在途解析结果作废。
  int _generation = 0;

  /// 进行中的音频字节预取任务。
  AudioPredownloadTask? _pending;

  /// 预载 [next]（为 null 时仅作废上一次）。
  Future<void> preload(SourceTrack? next) async {
    final generation = ++_generation;
    _cancelPendingTask();
    if (next == null) return;

    final preferred = _preferredQuality?.call();
    final quality = preferred == null ? null : next.pickQuality(preferred);
    try {
      final stream = await _resolver(next, quality: quality);
      if (generation != _generation) return;
      // 只预热直链也不浪费：真正切到下一首时 CatalogService 已命中。
      if (_predownloader == null || _canPredownloadBytes?.call() == false) {
        return;
      }
      _pending = await _predownloader.predownload(
        track: next,
        stream: stream,
        quality: quality,
      );
      if (generation != _generation) _cancelPendingTask();
    } catch (_) {
      // 预载失败静默：真正播放时会正常取链。
    }
  }

  /// 取消未完成的预取。起播前调用：避免预取与边播边缓存双写同一缓存文件。
  void cancelPending() {
    _generation++;
    _cancelPendingTask();
  }

  void _cancelPendingTask() {
    _pending?.cancel();
    _pending = null;
  }
}
