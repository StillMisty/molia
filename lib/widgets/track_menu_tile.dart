import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import 'track_actions_menu.dart';
import 'track_row.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 曲目行（发现详情 / 搜索结果共用）：点击播放 + 行尾 ⋮ 菜单。
///
/// 菜单固定「收藏 / 加入列表」两条动作——两个入口的语义本来就相同，
/// 差异只在领域对象上，因此收藏态与写入流程都由调用方注入：
/// - 收藏态用 `select` 订阅后传入（组件不认具体 provider，避免把
///   DiscoverProvider / LibraryProvider 焊进共享件，也避免整表重建）；
/// - 行尾元信息（时长）由调用方按数据可得性传入，未知传 null 不占位。
class TrackMenuTile extends StatelessWidget {
  const TrackMenuTile({
    super.key,
    required this.title,
    required this.artist,
    this.coverUrl,
    this.trailingText,
    required this.position,
    required this.onTap,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String title;
  final String artist;
  final String? coverUrl;

  /// 行尾元信息（时长）；未知传 null 不占位。
  final String? trailingText;

  /// 列表内位置（首末行外侧圆角）。
  final M3ECardPosition position;

  /// 点击整行；null 为不可点（如缺少可播放曲目的结果项）。
  final VoidCallback? onTap;

  /// 是否已收藏（决定菜单文案与图标）。
  final bool favorite;

  /// 收藏 / 取消收藏。
  final VoidCallback onToggleFavorite;

  /// 加入列表（收藏 / 历史 / 自建列表，流程由调用方注入）。
  final VoidCallback onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return TrackRow(
      title: title,
      artist: artist,
      coverUrl: coverUrl,
      trailingText: trailingText,
      position: position,
      onTap: onTap,
      trailing: TrackActionsMenu(
        tooltip: l10n.trackActionsTooltip,
        entries: [
          M3EMenuEntry(
            label: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
            leading: Icon(
              favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            ),
            value: 'favorite',
          ),
          M3EMenuEntry(
            label: l10n.addToPlaylist,
            leading: const Icon(Icons.playlist_add_rounded),
            value: 'add',
          ),
        ],
        onSelected: (value) {
          switch (value) {
            case 'favorite':
              onToggleFavorite();
            case 'add':
              onAddToPlaylist();
          }
        },
      ),
    );
  }
}
