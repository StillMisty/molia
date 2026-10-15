/// 单曲缓存文案：分区名 / 单项占用 / 汇总 / 清理结果。
///
/// 歌曲信息页（缓存行副标题）与单曲缓存子页（逐项占用与清理反馈）共用，
/// 保证两处口径一致（此前散在 `TrackInfoView` 私有方法里）。
library;

import '../l10n/app_localizations.dart';
import '../services/cache_types.dart';
import '../services/track_cache_service.dart';

/// 分区显示名（音频 / 歌词 / 封面 / 取链）。
String trackCachePartLabel(AppLocalizations l10n, TrackCachePart part) {
  return switch (part) {
    TrackCachePart.audio => l10n.cachePartitionAudio,
    TrackCachePart.lyrics => l10n.cachePartitionLyrics,
    TrackCachePart.artwork => l10n.cachePartitionArtwork,
    TrackCachePart.resolveUrl => l10n.trackInfoCacheResolve,
  };
}

/// 单项占用文案：未就绪「统计中」、命中「大小 · 条数」、未命中「无缓存」；
/// 音频分项额外区分「命中」与「写入中（半成品，还不能离线播放）」。
String trackCacheUsageLabel(
  AppLocalizations l10n,
  TrackCachePart part,
  TrackCacheUsage usage,
) {
  final (CacheUsage value, bool isCountOnly) = switch (part) {
    TrackCachePart.audio => (usage.audio, false),
    TrackCachePart.lyrics => (usage.lyrics, false),
    TrackCachePart.artwork => (usage.artwork, false),
    TrackCachePart.resolveUrl => (
        CacheUsage(bytes: 0, count: usage.resolveEntries),
        true,
      ),
  };
  final writing = part == TrackCachePart.audio && usage.audioWriting.count > 0
      ? l10n.trackCacheAudioWriting(
          formatCacheBytes(usage.audioWriting.bytes),
        )
      : null;
  if (value.count <= 0) return writing ?? l10n.trackInfoCacheNone;
  final label = isCountOnly
      ? l10n.trackInfoCacheEntries(value.count)
      : l10n.cacheUsage(formatCacheBytes(value.bytes), value.count);
  return writing == null ? label : '$label · $writing';
}

/// 四项汇总（歌曲信息页「缓存」行副标题）：命中项用 `名 大小` 拼接；
/// 只有音频半成品时说明「写入中」，不留空串。
String trackCacheSummaryLabel(AppLocalizations l10n, TrackCacheUsage usage) {
  if (!usage.hasAny) return l10n.trackInfoCacheNone;
  final parts = <String>[
    if (usage.audio.count > 0)
      '${l10n.cachePartitionAudio} ${formatCacheBytes(usage.audio.bytes)}',
    if (usage.audio.count <= 0 && usage.audioWriting.count > 0)
      l10n.trackCacheAudioWriting(formatCacheBytes(usage.audioWriting.bytes)),
    if (usage.lyrics.count > 0)
      '${l10n.cachePartitionLyrics} ${formatCacheBytes(usage.lyrics.bytes)}',
    if (usage.artwork.count > 0)
      '${l10n.cachePartitionArtwork} ${formatCacheBytes(usage.artwork.bytes)}',
    if (usage.resolveEntries > 0)
      '${l10n.trackInfoCacheResolve} '
          '${l10n.trackInfoCacheEntries(usage.resolveEntries)}',
  ];
  return parts.join(' · ');
}

/// 清理结果提示：清到东西 / 活动文件跳过 / 本来就没缓存，三种分开说。
String trackCacheClearResultLabel(
  AppLocalizations l10n,
  TrackCacheClearResult result,
) {
  if (result.cleared) {
    final size = result.part == TrackCachePart.resolveUrl
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
