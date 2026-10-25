/// 真实（just_audio）播放链路：把「取链」收成一条解析函数，
/// `LocalPlaybackService`（解析直链）与 `LocalPlaybackBackend`（领域解析）
/// 都只是它的消费者——服务与后端因此不再互相引用实例。
///
/// 为什么单独成文件：这段是**平台绑定的装配**（just_audio 插件），
/// 与 provider/观察者的接线分开，便于单测只覆盖可注入部分
/// （见 `test/app/bootstrap_smoke_test.dart`）。
library;

import 'package:flutter/foundation.dart' show ValueListenable;

import '../../data/mapping/track_mapper.dart';
import '../../data/playback/local_playback_backend.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart' show PlayableStream;
import '../../playback/local_playback_service.dart';
import '../../playback/next_track_preloader.dart';
import '../../playback/playback_power_policy.dart';
import '../../playback/playing_track_cache_writer.dart';
import '../../sources/source_track.dart';
import 'catalog_stack.dart';
import 'local_data_stack.dart';

/// 取链装饰 + 服务 / 后端组装（原组合根的 `late final playbackBackend` 绕行
/// 在这里变成「一个解析函数两个消费者」）。
class LocalPlaybackChain {
  LocalPlaybackChain({
    required this.catalog,
    required this.local,
    required this.powerPolicy,
  });

  final CatalogStack catalog;
  final LocalDataStack local;

  /// 组合根共享的播放功耗策略（位置采样节拍、下一首字节预取门控；
  /// 封面预取 / 取色由观察者与歌词显示栈消费同一实例）。
  final PlaybackPowerPolicy powerPolicy;

  /// 取链外层装饰：优先命中本地下载副本 / 完整音频缓存（直接 file://），
  /// 未命中回落既有 CatalogService（single-flight + LRU + TTL 不变）。
  Future<PlayableStream> resolveStream(
    Track track,
    AudioQuality? quality,
  ) async {
    final uri =
        await local.downloadService.localUriFor(track, quality: quality?.type);
    if (uri != null) return PlayableStream(uri);
    return catalog.catalogService.resolve(track, quality: quality);
  }

  /// `SourceTrack` 取链适配：服务解析回调 / 下一首预载共用
  /// （取链的唯一实现）。
  ///
  /// 返回完整 [PlayableStream]（含 headers）而不是 URL 字符串：B 站等平台
  /// 的直链离开 `Referer` / `UA` 会 403，播放、边播边缓存与字节预取必须
  /// 拿到同一份请求头；只传 URL 会在这一层静默丢掉鉴权信息。
  Future<PlayableStream> resolveSourceStream(
    SourceTrack track, {
    String? quality,
  }) {
    return resolveStream(
      trackFromSourceTrack(track),
      (quality == null || quality.isEmpty) ? null : AudioQuality(type: quality),
    );
  }

  /// 服务按实际选择的音质调用解析器（同一音质也用于音频缓存键）。
  /// 省流上限只在 preferredQuality 一处压低：resolve 缓存键包含真实音质
  /// 维度，切换网络后自然重解析。
  String preferredQuality() =>
      local.dataSaver.effectiveQuality(catalog.sourceManager.preferredQuality);

  LocalPlaybackService buildService({
    required ValueListenable<bool> playWithOtherApps,
  }) =>
      LocalPlaybackService(
        preferredQuality: preferredQuality,
        resolver: resolveSourceStream,
        powerPolicy: powerPolicy,
        playWithOtherApps: playWithOtherApps,
        // 下一首预载：起播后预热直链（命中取链缓存）+ 音频字节预取到缓存。
        nextTrackPreloader: NextTrackPreloader(
          resolver: resolveSourceStream,
          preferredQuality: preferredQuality,
          predownloader: local.audioCacheWriter,
          // 移动端后台只预热直链：字节预取把整首下一曲提前拉到本地，是
          // 熄屏听歌时最重的网络 / 磁盘开销。
          canPredownloadBytes: () => powerPolicy.canPredownloadNextTrackBytes,
        ),
        audioCacheWriter: PlayingTrackCacheWriter(
          predownloader: local.audioCacheWriter,
        ),
      );

  LocalPlaybackBackend buildBackend({required LocalPlaybackService service}) =>
      LocalPlaybackBackend(service: service, resolver: resolveStream);
}
