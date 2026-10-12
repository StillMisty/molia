import '../../l10n/app_localizations.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';

/// 通知·锁屏与蓝牙子页共用的选项构造。
///
/// 两组共用同一媒体元数据输出（通知与蓝牙 profile 合成后写入 MediaItem），
/// 选项文案集中一处，避免两页口径漂移。
List<(LyricsMetadataTarget, String)> lyricsMetadataTargetOptions(
  AppLocalizations l10n,
) =>
    [
      (LyricsMetadataTarget.subtitle, l10n.lyricsMetadataTargetSubtitle),
      (LyricsMetadataTarget.artist, l10n.lyricsMetadataTargetArtist),
      (LyricsMetadataTarget.title, l10n.lyricsMetadataTargetTitle),
      (LyricsMetadataTarget.album, l10n.lyricsMetadataTargetAlbum),
    ];

List<(LyricsMetadataFormat, String)> lyricsMetadataFormatOptions(
  AppLocalizations l10n,
) =>
    [
      (LyricsMetadataFormat.lyric, l10n.lyricsMetadataFormatLyric),
      (LyricsMetadataFormat.lyricTitle, l10n.lyricsMetadataFormatLyricTitle),
      (LyricsMetadataFormat.titleLyric, l10n.lyricsMetadataFormatTitleLyric),
    ];

List<(LyricsPauseBehavior, String)> lyricsPauseBehaviorOptions(
  AppLocalizations l10n,
) =>
    [
      (LyricsPauseBehavior.keep, l10n.lyricsBehaviorKeep),
      (LyricsPauseBehavior.title, l10n.lyricsBehaviorTitle),
      (LyricsPauseBehavior.clear, l10n.lyricsBehaviorClear),
    ];
