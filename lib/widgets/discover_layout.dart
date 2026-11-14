/// 发现页布局断点：gutter、内容宽度与歌单 / 榜单网格列数与卡片高度。
///
/// 搜索 / 热榜 / 歌单三个 tab 必须共用同一套页边距与列数公式：断点数字只在
/// 本文件维护，tab 内不要再写 16 / 600 / 200 之类的布局常量。
///
/// 内容栏**不再设最大宽度**：全宽自适应，列数随实际可用宽度增长（最多 6 列）。
library;

import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/responsive.dart';
import 'row_extent.dart';

/// 发现页宽屏判定（内容宽度）：歌单切网格、热榜加列都用这一档。
const double discoverWideBreakpoint = 600;

/// 歌单网格单列的最小宽度（决定列数）。
const double discoverPlaylistTileMinWidth = 200;

/// 热榜磁贴单列的最小宽度（决定宽屏列数）。
const double discoverLeaderboardTileMinWidth = 240;

/// 网格列距 / 行距。
const double discoverGridGap = 12;

/// 网格列数上下限。
///
/// 6 是全宽自适应下的保护上限：超宽窗口也不会无限增加列数。
const int discoverGridMinColumns = 2;
const int discoverGridMaxColumns = 6;

/// 页面顶部 / 底部的纵向节奏。
const double discoverPageTopPadding = 12;
const double discoverPageBottomPadding = 32;

/// 搜索栏与标签 / 内容之间的间距。
const double discoverSectionGap = 8;

/// 发现页统一页边距（compact 12 / 手机 16 / 平板桌面 24）。
double discoverGutterOf(BuildContext context) =>
    context.layoutType(ResponsivePageType.browse).horizontalPadding;

/// 顶部工具行里每个可见 tab 至少预留的宽度（含触摸目标）。
///
/// 渠道触发框按当前名字自适应，宽度上限 = 行宽 − 可见 tab 数 × 本值 − 间距；
/// 数字只在本文件维护，页面不要另写 48。
const double discoverTabSlotMinWidth = 48;

/// 内容宽度 = 页面可用宽 − 两侧 gutter。
double discoverContentWidthOf(BuildContext context, double availableWidth) {
  final gutter = discoverGutterOf(context);
  return math.max(0, availableWidth - gutter * 2);
}

/// 内容宽度是否达到宽屏档。
bool discoverIsWide(double contentWidth) =>
    contentWidth >= discoverWideBreakpoint;

/// 歌单内容宽度达到宽屏档后使用封面网格。
bool discoverUsesPlaylistGrid(double contentWidth) =>
    discoverIsWide(contentWidth);

/// 列数公式必须把 (列数 − 1) 个 gap 算进去，否则实际列宽会低于声明的最小值：
/// 可用列宽 = (内容宽 − gap × (列数 − 1)) / 列数 ≥ 最小列宽。
int _gridColumnsFor(double contentWidth, double minTileWidth) {
  final columns =
      ((contentWidth + discoverGridGap) / (minTileWidth + discoverGridGap))
          .floor();
  return columns.clamp(discoverGridMinColumns, discoverGridMaxColumns);
}

/// 歌单网格列数：每列至少 200，最少 2 列；全宽后最多 6 列。
int discoverPlaylistColumns(double contentWidth) =>
    _gridColumnsFor(contentWidth, discoverPlaylistTileMinWidth);

/// 热榜磁贴列数：手机固定 2 列；宽屏每列至少 240，全宽后最多 6 列。
int discoverLeaderboardColumns(double contentWidth) {
  if (!discoverIsWide(contentWidth)) {
    return discoverGridMinColumns;
  }
  return _gridColumnsFor(contentWidth, discoverLeaderboardTileMinWidth);
}

/// 歌单网格卡片高度（含 4px 字体回退安全余量）。
///
/// 卡片内边距 8+8、封面与文字间距 8；标题最多 2 行、副标题 1 行，
/// 行高全部按当前文字缩放测量，1.3× / 1.5× 下不会被固定高度裁掉。
double discoverPlaylistTileExtentOf(BuildContext context, double tileWidth) {
  final m3e = M3ETheme.of(context);
  final cover = math.max(0.0, tileWidth - 16);
  final text = scaledRowExtentOf(
    context,
    minExtent: 0,
    styles: [
      m3e.typeScale.titleSmall,
      m3e.typeScale.titleSmall,
      m3e.typeScale.bodySmall,
    ],
    stacked: true,
    extra: 2,
    allowance: 4,
  );
  // 上 8 + 封面 + 封面与文字间距 8 + 文字块 + 下 8。
  return 24 + cover + text;
}

/// 热榜磁贴高度：56dp 封面 + 上下内边距 8+8，标题两行时随文字缩放增长。
double discoverLeaderboardTileExtentOf(BuildContext context) {
  final m3e = M3ETheme.of(context);
  return scaledRowExtentOf(
    context,
    minExtent: 56,
    styles: [m3e.typeScale.titleSmall, m3e.typeScale.titleSmall],
    stacked: true,
    allowance: 4,
    padding: 16,
  );
}

/// 搜索栏约束：取消 M3E 默认 720 上限，让搜索栏铺满可用内容宽。
BoxConstraints discoverSearchBarConstraints(BuildContext context) {
  final barTheme = M3ETheme.of(context).searchBarTheme;
  return BoxConstraints(
    minWidth: 0,
    maxWidth: double.infinity,
    minHeight: barTheme.minHeight,
  );
}
