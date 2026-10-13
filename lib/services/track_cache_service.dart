import 'dart:async';

import '../data/catalog/catalog_service.dart';
import '../domain/models/track.dart';
import '../managers/artwork_cache.dart';
import 'cache_service.dart';

/// 单曲缓存分项：音频文件 / 歌词 / 封面 / 取链结果。
enum TrackCachePart { audio, lyrics, artwork, resolveUrl }

/// 单曲缓存占用（四项）。
///
/// 取链缓存是内存请求缓存（10min TTL），只有条目数没有字节意义。
class TrackCacheUsage {
  const TrackCacheUsage({
    this.audio = CacheUsage.zero,
    this.lyrics = CacheUsage.zero,
    this.artwork = CacheUsage.zero,
    this.resolveEntries = 0,
  });

  final CacheUsage audio;
  final CacheUsage lyrics;
  final CacheUsage artwork;
  final int resolveEntries;

  /// 是否任一有缓存（页面据此决定「全部清理」是否可用）。
  bool get hasAny =>
      audio.count > 0 ||
      lyrics.count > 0 ||
      artwork.count > 0 ||
      resolveEntries > 0;

  @override
  bool operator ==(Object other) =>
      other is TrackCacheUsage &&
      other.audio == audio &&
      other.lyrics == lyrics &&
      other.artwork == artwork &&
      other.resolveEntries == resolveEntries;

  @override
  int get hashCode => Object.hash(audio, lyrics, artwork, resolveEntries);

  @override
  String toString() => 'TrackCacheUsage(audio: $audio, lyrics: $lyrics, '
      'artwork: $artwork, resolve: $resolveEntries)';
}

/// 单项清理结果。
class TrackCacheClearResult {
  const TrackCacheClearResult({
    required this.part,
    this.freed = CacheUsage.zero,
    this.skipped = 0,
  });

  final TrackCachePart part;

  /// 实际删除/失效的量（取链用条目数，字节为 0）。
  final CacheUsage freed;

  /// 因正在写入（边播边缓存）被跳过的文件数；只有音频分项可能 > 0。
  final int skipped;

  /// 是否确实清掉了东西。
  bool get cleared => freed.count > 0;

  @override
  String toString() =>
      'TrackCacheClearResult($part, freed: $freed, skipped: $skipped)';
}

/// 单曲缓存门面：把音频 / 歌词 / 封面 / 取链四个后端收敛成
/// 「这首歌占了多少、清哪一项」两种动作，供歌曲信息页消费。
///
/// 为什么需要这层：四个后端的存储形态完全不同（目录文件名前缀 /
/// prefs 键 / flutter_cache_manager 键 / 内存请求缓存），页面不该知道
/// 这些细节，也不该自己拼缓存 key。
class TrackCacheService {
  TrackCacheService({
    required CacheService cacheService,
    required ArtworkCache artworkCache,
    required CatalogService catalogService,
  })  : _cacheService = cacheService,
        _artworkCache = artworkCache,
        _catalogService = catalogService;

  final CacheService _cacheService;
  final ArtworkCache _artworkCache;
  final CatalogService _catalogService;

  /// 四项占用（并行查询；单曲维度）。
  Future<TrackCacheUsage> usage(Track track) async {
    final results = await Future.wait([
      _cacheService.audioUsageForTrack(
        sourceKey: track.id.sourceKey,
        songId: track.id.id,
      ),
      _cacheService.lyricsUsageForTrack(track.id.uri),
      _artworkUsage(track),
    ]);
    return TrackCacheUsage(
      audio: results[0],
      lyrics: results[1],
      artwork: results[2],
      resolveEntries: _catalogService.resolveCacheCountForTrack(track),
    );
  }

  /// 清理单项（音频跳过正在写入的文件，见
  /// `CacheService.clearAudioForTrack`）。
  Future<TrackCacheClearResult> clear(
    Track track,
    TrackCachePart part,
  ) async {
    switch (part) {
      case TrackCachePart.audio:
        final result = await _cacheService.clearAudioForTrack(
          sourceKey: track.id.sourceKey,
          songId: track.id.id,
        );
        return TrackCacheClearResult(
          part: part,
          freed: result.deleted,
          skipped: result.skipped,
        );
      case TrackCachePart.lyrics:
        final before = await _cacheService.lyricsUsageForTrack(track.id.uri);
        await _cacheService.clearLyricsForTrack(track.id.uri);
        return TrackCacheClearResult(part: part, freed: before);
      case TrackCachePart.artwork:
        final before = await _artworkUsage(track);
        for (final url in _artworkUrls(track)) {
          await _artworkCache.remove(url);
        }
        return TrackCacheClearResult(part: part, freed: before);
      case TrackCachePart.resolveUrl:
        final removed = _catalogService.invalidateResolveForTrack(track);
        return TrackCacheClearResult(
          part: part,
          freed: CacheUsage(bytes: 0, count: removed),
        );
    }
  }

  /// 封面占用：主图 + 降级链（任一命中即计入）。
  Future<CacheUsage> _artworkUsage(Track track) async {
    var total = CacheUsage.zero;
    for (final url in _artworkUrls(track)) {
      total = total + await _artworkCache.usageOf(url);
    }
    return total;
  }

  static List<String> _artworkUrls(Track track) {
    final artwork = track.artwork;
    if (artwork == null) return const [];
    return <String>{
      artwork.uri.toString(),
      for (final fallback in artwork.fallbacks) fallback.toString(),
    }.toList(growable: false);
  }
}
