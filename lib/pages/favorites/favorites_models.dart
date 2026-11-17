/// 收藏页拆分后的页面内模型与无状态小工具。
///
/// 这里只放「页面自己定义、但不止一个拆分文件要用」的值：正文四态标识、
/// 智能列表展示名 / 图标、曲库摘要、头部尺寸口径和滚动簿记端口。依赖都是
/// 纯值或 Flutter 基础类型，不持有 provider，也不做业务判断。
library;

import 'package:material_ui/material_ui.dart';

import '../../domain/models/library_browse.dart';
import '../../domain/models/smart_lists.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/collection_session.dart';
import '../../widgets/collection_scroll_bookkeeping.dart';

/// 收藏页正文区的四态标识：只喂给 `CrossFadeSwap` 做「值变才过渡」判断。
///
/// 用 enum 而不是 `(bool, bool, bool)` record：四态互斥，多一个
/// `isLoading && hasFailed` 组合会让过渡的 key 可能落到不存在的分支上。
enum FavoritesCollectionSurface { loading, failed, libraryBrowse, body }

/// 曲库摘要：没有可浏览内容时不显示「0 张专辑 · 0 位歌手」。
String? libraryBrowseSummary(AppLocalizations l10n, LibraryBrowseIndex? index) {
  if (index == null || (index.albums.isEmpty && index.artists.isEmpty)) {
    return null;
  }
  return l10n.libraryBrowseSummary(index.albums.length, index.artists.length);
}

/// 智能列表展示名（弹层与合集标题共用）。
Map<String, String> smartListNames(AppLocalizations l10n) => {
  SmartListIds.recentlyAdded: l10n.smartRecentlyAdded,
  SmartListIds.recentlyPlayed: l10n.smartRecentlyPlayed,
  SmartListIds.mostPlayed: l10n.smartMostPlayed,
  SmartListIds.neverPlayed: l10n.smartNeverPlayed,
  SmartListIds.localOnly: l10n.smartLocalOnly,
  SmartListIds.downloaded: l10n.smartDownloaded,
  SmartListIds.missingFiles: l10n.smartMissingFiles,
};

IconData smartListIcon(String id) => switch (id) {
  SmartListIds.recentlyAdded => Icons.new_releases_rounded,
  SmartListIds.recentlyPlayed => Icons.history_rounded,
  SmartListIds.mostPlayed => Icons.trending_up_rounded,
  SmartListIds.neverPlayed => Icons.music_off_rounded,
  SmartListIds.localOnly => Icons.folder_special_rounded,
  SmartListIds.downloaded => Icons.download_done_rounded,
  _ => Icons.report_gmailerrorred_rounded,
};

/// 页头尺寸：标题行 / 多选栏同高，搜索行由 AppSearchBar 自己决定高度。
abstract final class FavoritesHeaderMetrics {
  /// 标题行 / 多选栏的内容高度（M3E 56）。
  ///
  /// 搜索行不套这个固定高度：展开搜索后由 AppSearchBar 按系统文字缩放
  /// 自行决定高度，大字体下才能容纳完整 hint 与输入行框。
  static const double rowHeight = 56;

  /// 头部（标题行 / 搜索行 / 多选栏）垂直留白：三者切换时留白一致。
  static const double paddingTop = 12;
  static const double paddingBottom = 8;

  /// 头部行高：随系统字号放大，避免标题 / 副标题在 200% 字号下被裁。
  static double heightOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(rowHeight);
}

/// 会话 → 页面滚动簿记的适配：控制器与防抖落盘都留在页面，会话只决定
/// 合集键和恢复时机（见 [CollectionScrollPort]）。
///
/// 用回调而不是页面引用：端口不反向依赖页面 State，拆分文件之间只通过
/// 显式参数连接。回调在真正被会话调用时才读页面的 late final 簿记。
class FavoritesPageScrollPort implements CollectionScrollPort {
  const FavoritesPageScrollPort({
    required this.restoreOffsetsCallback,
    required this.activateCallback,
    required this.restoreCallback,
    required this.flushCallback,
  });

  final void Function(Map<String, double> offsets) restoreOffsetsCallback;
  final void Function(String collectionKey) activateCallback;
  final VoidCallback restoreCallback;
  final VoidCallback flushCallback;

  @override
  void restoreOffsets(Map<String, double> offsets) =>
      restoreOffsetsCallback(offsets);

  @override
  void activate(String collectionKey) => activateCallback(collectionKey);

  @override
  void restore() => restoreCallback();

  @override
  void flush() => flushCallback();
}

/// 滚动簿记的类型别名出口：页面持有它，端口只负责转发。
typedef FavoritesScrollBookkeeping = CollectionScrollBookkeeping;
