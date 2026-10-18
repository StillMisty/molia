/// 单曲本地数据门面：把「缓存」（易失）与「下载」（持久）两档收敛成
/// 「这首歌本机有什么、能清什么」，供歌曲信息页与「本地数据」页消费。
///
/// 为什么需要这层：四个缓存后端（音频目录 / 歌词 prefs / 封面 cache manager /
/// 内存取链）与下载记录（drift）的存储形态完全不同，「有 / 没有」的判据也各不
/// 相同（完整文件、TTL 未过期、封面索引命中）；页面不该知道这些细节，更不该
/// 各写一套「算不算有」——两套口径必然分叉（缓存面说命中、下载面说没有）。
///
/// 两档词表（唯一出处，见 [LocalPartState]）：
/// - **已下载**：持久副本（`downloads/` + 记录），可分享、清缓存不影响；
/// - **已缓存**：易失副本（LRU / TTL / 清理后即无），可离线播放，可「转存」
///   为下载；
/// - **无**：两档都没有。
library;

import 'dart:async';

import '../data/catalog/catalog_service.dart';
import '../domain/models/download.dart';
import '../domain/models/track.dart';
import '../managers/artwork_cache.dart';
import 'audio_cache_store.dart';
import 'cache_service.dart';
import 'download/download_service.dart';

/// 单项本地拥有状态（两档词表）：已下载（持久）> 已缓存（易失）> 无。
enum LocalPartState {
  /// 两档都没有。
  none,

  /// 命中缓存（易失副本，可离线播放 / 转存）。
  cached,

  /// 已有持久下载副本。
  downloaded,
}

/// 缓存分项（逐项清理的对象）：音频 / 歌词 / 封面 / 取链。
enum LocalCachePart { audio, lyrics, artwork, resolveUrl }

/// 单项清理结果。
class LocalCacheClearResult {
  const LocalCacheClearResult({
    required this.part,
    this.freed = CacheUsage.zero,
    this.skipped = 0,
  });

  final LocalCachePart part;

  /// 实际删除/失效的量（取链用条目数，字节为 0）。
  final CacheUsage freed;

  /// 因正在写入（边播边缓存）被跳过的文件数；只有音频分项可能 > 0。
  final int skipped;

  /// 是否确实清掉了东西。
  bool get cleared => freed.count > 0;

  @override
  String toString() =>
      'LocalCacheClearResult($part, freed: $freed, skipped: $skipped)';
}

/// 单曲本地数据快照（页面唯一消费对象）。
class TrackLocalData {
  const TrackLocalData({
    this.download,
    this.audioCache = CacheUsage.zero,
    this.audioWriting = CacheUsage.zero,
    this.lyricsCache = CacheUsage.zero,
    this.artworkCache = CacheUsage.zero,
    this.cachedQualities = const <String>[],
    this.resolveEntries = 0,
  });

  /// 下载记录（音频 / 歌词 / 封面共用一条；未下载为 null）。
  final DownloadedTrack? download;

  /// 完整音频缓存占用（所有音质变体）。
  final CacheUsage audioCache;

  /// 音频缓存写入中（半成品 / 边车）：占磁盘，但还不是可播放缓存。
  final CacheUsage audioWriting;

  final CacheUsage lyricsCache;
  final CacheUsage artworkCache;

  /// 命中完整缓存的音质（音质列表标记 / 预选 / 离线取链用）。
  final List<String> cachedQualities;

  final int resolveEntries;

  bool get hasAudioDownload => download?.hasAudio ?? false;
  bool get hasLyricsDownload => download?.hasLyrics ?? false;
  bool get hasCoverDownload => download?.hasCover ?? false;

  LocalPartState get audioState => hasAudioDownload
      ? LocalPartState.downloaded
      : (audioCache.count > 0 ? LocalPartState.cached : LocalPartState.none);

  LocalPartState get lyricsState => hasLyricsDownload
      ? LocalPartState.downloaded
      : (lyricsCache.count > 0 ? LocalPartState.cached : LocalPartState.none);

  LocalPartState get artworkState => hasCoverDownload
      ? LocalPartState.downloaded
      : (artworkCache.count > 0 ? LocalPartState.cached : LocalPartState.none);

  /// 是否任一有缓存（含写入中）：「清理」是否可用的判据。
  bool get hasAnyCache =>
      audioCache.count > 0 ||
      lyricsCache.count > 0 ||
      artworkCache.count > 0 ||
      resolveEntries > 0 ||
      audioWriting.count > 0;

  /// 是否有任一持久下载副本。
  bool get hasAnyDownload =>
      hasAudioDownload || hasLyricsDownload || hasCoverDownload;

  @override
  String toString() => 'TrackLocalData(audio: $audioState, lyrics: '
      '$lyricsState, artwork: $artworkState, '
      'download: ${download?.key}, audioWriting: $audioWriting)';
}

class TrackLocalDataService {
  TrackLocalDataService({
    required CacheService cacheService,
    required ArtworkCache artworkCache,
    required CatalogService catalogService,
    DownloadService? downloadService,
  })  : _cacheService = cacheService,
        _artworkCache = artworkCache,
        _catalogService = catalogService,
        _downloadService = downloadService;

  final CacheService _cacheService;
  final ArtworkCache _artworkCache;
  final CatalogService _catalogService;
  final DownloadService? _downloadService;

  /// 下载档的同步种子（缓存占用异步补全）。
  ///
  /// 下载记录在内存里（drift 已加载），同步读可以避免首帧把「已下载」闪成
  /// 「未下载」；缓存占用必须走文件系统 / prefs，只能异步补。
  TrackLocalData downloadState(Track track) => TrackLocalData(
        download: _downloadService?.recordForTrack(track),
      );

  /// 完整读取（下载记录 + 四项缓存占用 + 命中音质）。
  Future<TrackLocalData> load(Track track) async =>
      (await loadMany([track]))[track.id.uri]!;

  /// 批量读取：一次目录列举 + 并发封面统计服务多首曲目（本地歌曲合集等
  /// 列表消费面用），与 [load] 同一判据、同一返回形状；key 为 `TrackId.uri`。
  ///
  /// 存储失败向上抛，由调用方决定失败呈现（列表页按无结果处理）。
  Future<Map<String, TrackLocalData>> loadMany(List<Track> tracks) async {
    if (tracks.isEmpty) return const {};
    final store = _cacheService.audioStore;
    final (index, partials) = await store.splitIndex();
    final artworkUsages = await Future.wait([
      for (final track in tracks) _artworkUsage(track),
    ]);
    final result = <String, TrackLocalData>{};
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      result[track.id.uri] = TrackLocalData(
        download: _downloadService?.recordForTrack(track),
        audioCache: AudioCacheStore.usageForTrackInFiles(
          index,
          sourceKey: track.id.sourceKey,
          songId: track.id.id,
        ),
        audioWriting: AudioCacheStore.usageForTrackInFiles(
          partials,
          sourceKey: track.id.sourceKey,
          songId: track.id.id,
        ),
        lyricsCache: await _cacheService.lyricsUsageForTrack(track.id.uri),
        artworkCache: artworkUsages[i],
        cachedQualities: AudioCacheStore.cachedQualitiesForTrack(track, index),
        resolveEntries: _catalogService.resolveCacheCountForTrack(track),
      );
    }
    return result;
  }

  /// 命中「已缓存」档（易失）的曲目集合：完整音频缓存 且 没有音频下载
  /// （下载优先）——与 [TrackLocalData.audioState] 同一判据，只是不走
  /// [loadMany] 的四分项统计。
  ///
  /// 为什么单独开一条：本地歌曲合集只需要音频这一档（歌词 / 封面 / 取链的
  /// 占用算出来也没人看），而 [loadMany] 会为每首曲目读 prefs、探封面文件；
  /// 合集列表与合集计数（弹层）都要等这份结果，代价必须与列表长度同阶。
  /// 目录不可用 / 列举失败按无缓存呈现（空集合）。
  Future<Set<TrackId>> cachedAudioTrackIds(Iterable<Track> tracks) async {
    if (tracks.isEmpty) return const <TrackId>{};
    final index = await _cacheService.audioStore.index();
    if (index.isEmpty) return const <TrackId>{};
    final result = <TrackId>{};
    for (final track in tracks) {
      // 下载优先：有音频下载的曲目归下载档，不出现在缓存行。
      if (_downloadService?.recordForTrack(track)?.hasAudio ?? false) continue;
      final usage = AudioCacheStore.usageForTrackInFiles(
        index,
        sourceKey: track.id.sourceKey,
        songId: track.id.id,
      );
      if (usage.count > 0) result.add(track.id);
    }
    return result;
  }

  /// 清理单项缓存（音频跳过正在写入的文件，见
  /// `CacheService.clearAudioForTrack`）。
  Future<LocalCacheClearResult> clear(
    Track track,
    LocalCachePart part,
  ) async {
    switch (part) {
      case LocalCachePart.audio:
        final result = await _cacheService.clearAudioForTrack(
          sourceKey: track.id.sourceKey,
          songId: track.id.id,
        );
        return LocalCacheClearResult(
          part: part,
          freed: result.deleted,
          skipped: result.skipped,
        );
      case LocalCachePart.lyrics:
        final before = await _cacheService.lyricsUsageForTrack(track.id.uri);
        await _cacheService.clearLyricsForTrack(track.id.uri);
        return LocalCacheClearResult(part: part, freed: before);
      case LocalCachePart.artwork:
        final before = await _artworkUsage(track);
        for (final url in _artworkUrls(track)) {
          await _artworkCache.remove(url);
        }
        return LocalCacheClearResult(part: part, freed: before);
      case LocalCachePart.resolveUrl:
        final removed = _catalogService.invalidateResolveForTrack(track);
        return LocalCacheClearResult(
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
