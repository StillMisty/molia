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
/// 仅内置五平台有稳定的页面形态；LX 脚本 / any-listen / 本地曲目没有
/// 可推导的页面地址（脚本 payload 不保证包含平台 id），返回 null 由 UI
/// 隐藏对应动作。参数取 payload 原样字段（脚本依赖同一批字段）。
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
    default:
      return null;
  }
}
