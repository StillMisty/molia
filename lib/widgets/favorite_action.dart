/// 收藏动作与反馈的唯一实现。
///
/// 为什么单独一层：收藏写路径早就只有一个（`LibraryProvider.toggleFavoriteTrack`），
/// 但「切换 + 提示什么」散在专辑页、歌手页、曲目菜单、播放页、AI 推荐和发现页
/// 六处——专辑页与歌手页的方法逐字节相同，其余各处各自重写「成功才提示 /
/// 失败才提示」与 l10n 映射。这里收口两件事：
/// - 意图：把领域曲目交给资料库切换收藏；
/// - 反馈：结果 → 文案（成功确认 / 失败提示）的两种固定强度。
///
/// 写路径、乐观更新与回滚仍由 provider 负责；本模块不碰仓库，也不改收藏缓存。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_outcome.dart';
import '../providers/library_provider.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 收藏反馈强度。
///
/// 两种都必须在结果里保留「失败」这一档；差别只在成功时是否再确认一次：
/// - [confirmation]：菜单行用。动作藏在弹层里，点完弹层关闭，成功也要
///   一句确认，否则看起来像没点到；
/// - [failureOnly]：图标态按钮用（播放页心形、AI 推荐行、发现行）。
///   图标本身随 provider 缓存翻转就是成功反馈，失败才需要明说。
enum FavoriteFeedback { confirmation, failureOnly }

/// 收藏心形契约：图标 / 语义标签 / 颜色三处的唯一映射。
///
/// 播放页心形按钮、曲目菜单与 AI 推荐菜单此前各写一遍
/// `favorite ? favorite_rounded : favorite_border_rounded`；图标或配色改一次
/// 就得追所有调用点。这里让「已收藏」只有一个定义（实心 + primary），
/// 未收藏只有一个定义（空心 + onSurfaceVariant）。
@immutable
class FavoriteHeart {
  const FavoriteHeart({required this.favorite});

  /// 当前是否已收藏。
  final bool favorite;

  /// 实心 / 空心字形。
  IconData get icon =>
      favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded;

  /// 菜单项 / 按钮语义标签（与动作文案同源：已收藏时给「取消收藏」）。
  String label(AppLocalizations l10n) =>
      favorite ? l10n.favoriteRemove : l10n.favoriteAdd;

  /// 图标色：已收藏走强调色，未收藏走次级前景色。
  Color color(ColorScheme scheme) =>
      favorite ? scheme.primary : scheme.onSurfaceVariant;
}

/// 切换领域曲目的收藏，并按 [feedback] 提示。
///
/// 返回切换结果（成功带切换后状态、失败带切换前状态）；没有资料库时返回
/// null 且不提示——入口本身应当已经隐藏，这里只兜底。
///
/// 触感不在这里：各宿主的触感属于交互版式（菜单行本来就没有），调用方
/// 需要在点击时先触发。
Future<FavoriteToggleOutcome?> toggleLibraryFavorite(
  BuildContext context,
  Track track, {
  FavoriteFeedback feedback = FavoriteFeedback.confirmation,
}) async {
  final library = context.read<LibraryProvider?>();
  if (library == null) return null;
  final outcome = await library.toggleFavoriteTrack(track);
  if (!context.mounted) return outcome;
  showFavoriteFeedback(context, outcome, feedback: feedback);
  return outcome;
}

/// 收藏结果 → 提示文案（发现域经 `DiscoverProvider` 写入后同样走这里）。
///
/// 失败永远提示 `operationFailed`：写失败时图标保持原样，不说一句会让人以为
/// 「点了没反应」。成功在 [FavoriteFeedback.failureOnly] 下不提示，图标态即反馈。
void showFavoriteFeedback(
  BuildContext context,
  FavoriteToggleOutcome outcome, {
  FavoriteFeedback feedback = FavoriteFeedback.confirmation,
}) {
  if (feedback == FavoriteFeedback.failureOnly && !outcome.isFailure) return;
  final l10n = _l10n(context);
  M3ESnackbar.show(
    context,
    message: outcome.isFailure
        ? l10n.operationFailed
        : outcome.isFavorite
            ? l10n.favoriteAdd
            : l10n.favoriteRemove,
  );
}
