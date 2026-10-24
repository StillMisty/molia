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
Future<void> openTrackComments(
  BuildContext context, {
  required Track track,
}) {
  return showSongCommentsPage(context, track: track);
}

/// 曲目在原生平台上的专辑 id（payload 原样字段）；无法提取时返回 null。
///
/// 仅内置五平台有稳定专辑 id：wy/kg/kw/mg 读 `albumId`，tx 读 `albumMid`
/// （缺省回退 `albumId`）。与 [platformTrackPageUrl] 同一口径：只读 payload
/// 的稳定平台字段，不做猜测。
String? platformAlbumId(Track track) {
  String payloadString(String key) => track.payload[key]?.toString() ?? '';
  switch (track.id.sourceKey) {
    case 'wy':
    case 'kg':
    case 'kw':
    case 'mg':
      final id = payloadString('albumId');
      return id.isEmpty ? null : id;
    case 'tx':
      final mid = payloadString('albumMid');
      final id = mid.isEmpty ? payloadString('albumId') : mid;
      return id.isEmpty ? null : id;
    default:
      return null;
  }
}

/// 曲目上可点进歌手页的歌手（带平台内 id 的首位）；不可点时返回 null。
///
/// id 来自内置平台解析注入的 raw `_artists` 字段（经 `track_mapper` 填进
/// [Track.artists]）；脚本扩展源 / 旧数据没有 id → 歌手行保持只读。
Artist? platformArtistOf(Track track) {
  for (final artist in track.artists) {
    if ((artist.id ?? '').isNotEmpty && artist.name.isNotEmpty) return artist;
  }
  return null;
}

/// 无平台歌手 id 时的回退名：首个歌手名的首段。
///
/// 历史数据（歌手入口上线之前收藏 / 导入的曲目）raw 里没有 `_artists`，
/// 多歌手被拼成一串（分隔符可能是 `、` / `, ` / `&`）；取首段按名字解析歌手。
String? fallbackArtistNameOf(Track track) {
  for (final artist in track.artists) {
    final first = _firstArtistSegment(artist.name);
    if (first.isNotEmpty) return first;
  }
  return null;
}

/// 曲目能否进入歌手页：带平台歌手 id，或至少有一个可回退的名字。
bool trackHasArtistEntry(Track track) =>
    platformArtistOf(track) != null || fallbackArtistNameOf(track) != null;

/// 打开歌手页（能力位由调用方先行判定，这里只做守卫与打开）。
///
/// [artist] 为多歌手行中被点击的那一位。有平台歌手 id 直接进；没有 id
/// （历史收藏 / 导入列表）时按名字回退解析（见 [showArtistPageByName]）。
Future<void> openTrackArtist(
  BuildContext context, {
  required Track track,
  Artist? artist,
}) {
  final sourceKey = track.id.sourceKey;
  final id = (artist?.id ?? '').isNotEmpty ? artist!.id! : platformArtistOf(track)?.id;
  if (id != null && id.isNotEmpty) {
    final name = (artist?.name ?? '').isNotEmpty
        ? artist!.name
        : platformArtistOf(track)?.name;
    return showArtistPage(context, sourceKey, id, fallbackName: name);
  }

  final clicked = _firstArtistSegment(artist?.name ?? '');
  final name = clicked.isNotEmpty ? clicked : fallbackArtistNameOf(track);
  if (name == null || name.isEmpty) return Future.value();
  return showArtistPageByName(context, sourceKey, name);
}

/// 歌手名首段（多歌手拼接串 → 首个名字）。
String _firstArtistSegment(String name) =>
    name.split(RegExp(r'、|, |&')).first.trim();

/// 打开专辑页（能力位由调用方先行判定，这里只做守卫与打开）。
///
/// [fallbackName] 默认取曲目自带的专辑名：加载完成前 / 平台未返回名称时
/// 作为标题回退。
Future<void> openTrackAlbum(
  BuildContext context, {
  required Track track,
  String? fallbackName,
}) {
  final albumId = platformAlbumId(track);
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

/// 曲目在原生平台上的网页地址（分享 / 打开用）；无法构造时返回 null。
///
/// 仅内置平台（五个音乐平台 + B 站）有稳定的页面形态；LX 脚本 / any-listen /
/// 本地曲目没有可推导的页面地址（脚本 payload 不保证包含平台 id），返回 null
/// 由 UI 隐藏对应动作。参数取 payload 原样字段（脚本依赖同一批字段）。
String? platformTrackPageUrl(Track track) {
  String payloadString(String key) => track.payload[key]?.toString() ?? '';
  switch (track.id.sourceKey) {
    case 'wy':
      final id = track.id.id;
      return id.isEmpty ? null : 'https://music.163.com/#/song?id=$id';
    case 'tx':
      final mid = payloadString('songmid');
      return mid.isEmpty ? null : 'https://y.qq.com/n/ryqq/songDetail/$mid';
    case 'kg':
      final hash = payloadString('hash');
      return hash.isEmpty ? null : 'https://www.kugou.com/song/#hash=$hash';
    case 'kw':
      final rid =
          payloadString('songmid').isEmpty ? track.id.id : payloadString('songmid');
      return rid.isEmpty ? null : 'https://www.kuwo.cn/play_detail/$rid';
    case 'mg':
      final copyrightId = payloadString('copyrightId');
      return copyrightId.isEmpty
          ? null
          : 'https://music.migu.cn/v3/music/song/$copyrightId';
    case 'bili':
      final bvid = payloadString('bvid');
      if (bvid.isNotEmpty) return 'https://www.bilibili.com/video/$bvid';
      final aid = payloadString('aid');
      return aid.isEmpty ? null : 'https://www.bilibili.com/video/av$aid';
    default:
      return null;
  }
}
