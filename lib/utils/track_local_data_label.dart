/// 本地数据文案：两档状态名 / 分区名 / 单项占用 / 汇总 / 清理结果。
///
/// 歌曲信息页（「本地数据」行副标题）与「本地数据」页（状态与逐项占用）
/// 共用，保证三处口径一致（「已缓存」与「已下载」绝不混用）。
library;

import '../l10n/app_localizations.dart';
import '../services/cache_types.dart';
import '../services/track_local_data_service.dart';
import 'source_quality_label.dart';

/// 两档状态名（唯一出处）：已下载 / 已缓存 / 未下载。
String localPartStateLabel(AppLocalizations l10n, LocalPartState state) {
  return switch (state) {
    LocalPartState.downloaded => l10n.downloadStatusDownloaded,
    LocalPartState.cached => l10n.localDataStateCached,
    LocalPartState.none => l10n.downloadStatusNotDownloaded,
  };
}

/// 分区显示名（音频 / 歌词 / 封面 / 取链）。
String localDataPartLabel(AppLocalizations l10n, LocalCachePart part) {
  return switch (part) {
    LocalCachePart.audio => l10n.cachePartitionAudio,
    LocalCachePart.lyrics => l10n.cachePartitionLyrics,
    LocalCachePart.artwork => l10n.cachePartitionArtwork,
    LocalCachePart.resolveUrl => l10n.trackInfoCacheResolve,
  };
}

/// 单项占用文案：未就绪「统计中」、命中「大小 · 条数」、未命中「无缓存」；
/// 音频分项额外区分「命中」与「写入中（半成品，还不能离线播放）」。
String trackCacheUsageLabel(
  AppLocalizations l10n,
  LocalCachePart part,
  TrackLocalData data,
) {
  final (CacheUsage value, bool isCountOnly) = switch (part) {
    LocalCachePart.audio => (data.audioCache, false),
    LocalCachePart.lyrics => (data.lyricsCache, false),
    LocalCachePart.artwork => (data.artworkCache, false),
    LocalCachePart.resolveUrl => (
        CacheUsage(bytes: 0, count: data.resolveEntries),
        true,
      ),
  };
  final writing = part == LocalCachePart.audio && data.audioWriting.count > 0
      ? l10n.trackCacheAudioWriting(formatCacheBytes(data.audioWriting.bytes))
      : null;
  if (value.count <= 0) return writing ?? l10n.trackInfoCacheNone;
  final label = isCountOnly
      ? l10n.trackInfoCacheEntries(value.count)
      : l10n.cacheUsage(formatCacheBytes(value.bytes), value.count);
  return writing == null ? label : '$label · $writing';
}

/// 「本地数据」行副标题（歌曲信息页）：音频两档状态 + 体积 / 音质；
/// 音频两档都没有时列出歌词 / 封面里已拥有的分项。
///
/// [localSource] 为本地导入曲目：文件是就地引用，缺失时给出对应文案
/// （与页内音频状态同一说法）。
String trackLocalDataSummaryLabel(
  AppLocalizations l10n,
  TrackLocalData data, {
  bool localSource = false,
}) {
  final quality = data.download?.quality ?? '';
  final cachedQuality =
      data.cachedQualities.isEmpty ? '' : data.cachedQualities.first;
  switch (data.audioState) {
    case LocalPartState.downloaded:
      final record = data.download!;
      final qualityLabel =
          quality.isEmpty ? '' : sourceQualityLabel(l10n, quality);
      return [
        l10n.downloadStatusDownloaded,
        if (qualityLabel.isNotEmpty) qualityLabel,
        record.sizeLabel,
      ].join(' · ');
    case LocalPartState.cached:
      final qualityLabel = cachedQuality.isEmpty || cachedQuality == 'auto'
          ? ''
          : sourceQualityLabel(l10n, cachedQuality);
      return [
        l10n.localDataStateCached,
        if (qualityLabel.isNotEmpty) qualityLabel,
        formatCacheBytes(data.audioCache.bytes),
        l10n.localDataOfflineAvailable,
      ].join(' · ');
    case LocalPartState.none:
      final parts = <String>[
        if (data.lyricsState != LocalPartState.none)
          '${l10n.lyricsTitle} ${localPartStateLabel(l10n, data.lyricsState)}',
        if (data.artworkState != LocalPartState.none)
          '${l10n.downloadCoverPart} '
              '${localPartStateLabel(l10n, data.artworkState)}',
      ];
      if (parts.isNotEmpty) return parts.join(' · ');
      return localSource
          ? l10n.downloadFileMissing
          : l10n.downloadStatusNotDownloaded;
  }
}

/// 清理结果提示：清到东西 / 活动文件跳过 / 本来就没缓存，三种分开说。
String trackCacheClearResultLabel(
  AppLocalizations l10n,
  LocalCacheClearResult result,
) {
  if (result.cleared) {
    final size = result.part == LocalCachePart.resolveUrl
        ? l10n.trackInfoCacheEntries(result.freed.count)
        : formatCacheBytes(result.freed.bytes);
    return l10n.trackInfoCacheCleared(size);
  }
  if (result.skipped > 0) return l10n.trackInfoCachePlaying;
  return l10n.trackInfoCacheNone;
}

/// 字节展示（1 位小数 MB / 整数 KB / B）。
String formatCacheBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}
