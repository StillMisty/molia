/// 收藏页拆分后的页面内模型与无状态小工具。
///
/// 这里只放「页面自己定义、但不止一个拆分文件要用」的值：正文四态标识、
/// 曲库摘要与头部尺寸口径。智能列表展示名 / 图标和弹层条目由
/// `FavoritesViewModel` 持有（providers 层），避免页面与 ViewModel 各存一份。
library;

import 'package:material_ui/material_ui.dart';

import '../../domain/models/library_browse.dart';
import '../../l10n/app_localizations.dart';

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
