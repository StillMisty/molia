/// 曲目级操作的统一打开编排（歌曲信息页 / 歌词页共用）。
///
/// 收敛两件事，避免入口复制：
/// - **能力位判定**：评论支持与否只问 [CommentsProvider.supports]
///   （渠道能力位的唯一 UI 侧实现）；
/// - **打开前的守卫与提示**：无曲目 / 信息不全时给用户提示而不是静默失败。
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../pages/album_page.dart';
import '../pages/artist_page.dart';
import '../pages/song_comments_page.dart';
import '../pages/source_swap_page.dart';
import '../providers/comments_provider.dart';
import '../providers/lyrics_provider.dart';
import '../services/notification_service.dart';
import 'lyrics_source_search_view.dart';

/// 当前曲目渠道是否支持评论（能力位唯一判定；无 provider 时按不支持）。
bool trackSupportsComments(BuildContext context, Track track) =>
    context.read<CommentsProvider?>()?.supports(track) ?? false;

/// 打开评论页（能力位由调用方先行判定，这里只做守卫与打开）。
Future<void> openTrackComments(BuildContext context, {required Track track}) {
  return showSongCommentsPage(context, track: track);
}

/// 曲目上可点进歌手页的歌手（带平台内 id 的首位）；不可点时返回 null。
///
/// id 来自内置平台解析注入的 raw `_artists` 字段（经 `track_mapper` 填进
/// [Track.artists]）；脚本扩展源没有 id → 歌手行保持只读。
Artist? platformArtistOf(Track track) {
  for (final artist in track.artists) {
    if ((artist.id ?? '').isNotEmpty && artist.name.isNotEmpty) return artist;
  }
  return null;
}

/// 打开歌手页（能力位由调用方先行判定，这里只做守卫与打开）。
///
/// [artist] 为多歌手行中被点击的那一位。只有带平台歌手 id 才能进入歌手页；
/// 没有 id（脚本扩展源 / 本地导入）时什么都不做——歌手行在 UI 上是只读的。
Future<void> openTrackArtist(
  BuildContext context, {
  required Track track,
  Artist? artist,
}) {
  final sourceKey = track.id.sourceKey;
  final platform = platformArtistOf(track);
  final id = (artist?.id ?? '').isNotEmpty ? artist!.id! : platform?.id;
  if (id == null || id.isEmpty) return Future.value();
  final name = (artist?.name ?? '').isNotEmpty ? artist!.name : platform?.name;
  return showArtistPage(context, sourceKey, id, fallbackName: name);
}

/// 打开专辑页（能力位由调用方先行判定，这里只做守卫与打开）。
///
/// [fallbackName] 默认取曲目自带的专辑名：加载完成前 / 平台未返回名称时
/// 作为标题回退。
Future<void> openTrackAlbum(
  BuildContext context, {
  required Track track,
  String? fallbackName,
}) {
  final albumId = track.platformAlbumId;
  if (albumId == null) return Future.value();
  return showAlbumPage(
    context,
    track.id.sourceKey,
    albumId,
    fallbackName: fallbackName ?? track.album,
  );
}

/// 打开换源页（音频 / 歌词两个 tab 同一页面）。
///
/// [initialTab] 由入口按域选择：歌曲信息页 → 音频（曲目域），歌词页 → 歌词。
/// 歌词 tab 的选中结果经本函数原样返回（调用方落地渲染侧簿记；
/// 会话真相由 `LyricsProvider.saveManual` 更新）。
Future<LyricsSearchSelection?> openTrackSourceSwap(
  BuildContext context, {
  required Track track,
  required SourceSwapTab initialTab,
}) {
  final notifications = context.read<NotificationService?>();
  final l10n = AppLocalizations.of(context);
  if (track.id.uri.isEmpty || track.title.isEmpty) {
    if (notifications != null && l10n != null) {
      notifications.showSnackBar(l10n.cannotGetTrackInfo);
    }
    return Future.value(null);
  }
  return showSourceSwapPage(
    context,
    seed: track,
    lyricsProvider: context.read<LyricsProvider>(),
    initialTab: initialTab,
  );
}
