/// 真实（just_audio）播放链路：把「取链」收成一条解析函数，
/// `LocalPlaybackService`（解析直链）与 `LocalPlaybackBackend`（领域解析）
/// 都只是它的消费者——服务与后端因此不再互相引用实例。
///
/// 为什么单独成文件：这段是**平台绑定的装配**（just_audio 插件），
/// 与 provider/观察者的接线分开，便于单测只覆盖可注入部分
/// （见 `test/app/bootstrap_smoke_test.dart`）。
library;

import '../../data/mapping/track_mapper.dart';
import '../../data/playback/local_playback_backend.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart' show PlayableStream;
import '../../playback/local_playback_service.dart';
import '../../playback/next_track_preloader.dart';
import '../../playback/playing_track_cache_writer.dart';
import '../../sources/source_track.dart';
import 'catalog_stack.dart';
import 'local_data_stack.dart';

/// 取链装饰 + 服务 / 后端组装（原组合根的 `late final playbackBackend` 绕行
/// 在这里变成「一个解析函数两个消费者」）。
class LocalPlaybackChain {
  LocalPlaybackChain({required this.catalog, required this.local});

  final CatalogStack catalog;
  final LocalDataStack local;

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

  /// `SourceTrack` 直链适配：服务解析回调 / 下一首预载共用
  /// （等价于原 `backend.resolveLegacyUrl` 的唯一实现）。
  Future<String> resolveUrl(SourceTrack track, {String? quality}) async {
    final stream = await resolveStream(
      trackFromSourceTrack(track),
      (quality == null || quality.isEmpty) ? null : AudioQuality(type: quality),
    );
    return stream.uri.toString();
  }

  /// 服务按实际选择的音质调用解析器（同一音质也用于音频缓存键）。
  /// 省流上限只在 preferredQuality 一处压低：resolve 缓存键包含真实音质
  /// 维度，切换网络后自然重解析。
  String preferredQuality() =>
      local.dataSaver.effectiveQuality(catalog.sourceManager.preferredQuality);

  LocalPlaybackService buildService() => LocalPlaybackService(
        preferredQuality: preferredQuality,
        resolver: resolveUrl,
        // 下一首预载：起播后预热直链（命中取链缓存）+ 音频字节预取到缓存。
        nextTrackPreloader: NextTrackPreloader(
          resolver: resolveUrl,
          preferredQuality: preferredQuality,
          predownloader: local.audioCacheWriter,
        ),
        audioCacheWriter: PlayingTrackCacheWriter(
          predownloader: local.audioCacheWriter,
        ),
      );

  LocalPlaybackBackend buildBackend({required LocalPlaybackService service}) =>
      LocalPlaybackBackend(service: service, resolver: resolveStream);
}
