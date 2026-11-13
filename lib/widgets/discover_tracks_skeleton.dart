import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import 'detail_page/detail_cover_header.dart';
import 'detail_page/detail_page_chrome.dart';
import 'row_extent.dart';
import 'skeleton.dart';
import 'track_row.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 发现详情页（榜单 / 歌单共用）的首屏骨架。
///
/// 为什么不用居中转圈：详情页头部有 96dp 封面，路由切换时它是共享元素的
/// 目标端；转圈态既不承担 Hero，又会让整个页面首屏从零高度跳到完整头部。
/// 这里先按加载完成后的头部 / 曲目行结构铺出骨架，封面用真实数据（含 Hero
/// 与封面 future），未知的副标题 / 简介 / 按钮与曲目行用呼吸块占位。
class DiscoverTracksSkeleton extends StatelessWidget {
  const DiscoverTracksSkeleton({
    super.key,
    required this.title,
    required this.tableColumns,
    this.coverUrl,
    this.coverFuture,
    this.coverHeroTag,
  });

  /// 入口已知的标题（= 页面标题；详情加载完成前也不会变成空白）。
  final String title;

  /// 与加载完成后的列表同一判据：表格档行高 / 行距不同。
  final bool tableColumns;

  /// 入口已知 / 列表缓存的封面。
  final String? coverUrl;

  /// 榜单磁贴的按需封面：不阻塞曲目首屏，解析完成后骨架头部即时更新。
  final Future<String?>? coverFuture;

  /// 与来源卡片相同的 Hero 标签；为空（链接打开）时不参与共享元素。
  final Object? coverHeroTag;

  /// 骨架行数：足够铺满常见手机 / 桌面视口，避免底部露出空白页面。
  static const int _rowCount = 8;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final cardList = M3ETheme.of(context).listTheme.cardList;
    final rowExtent =
        TrackRow.extentOf(context, tableColumns: tableColumns) + cardList.gap;
    final horizontal = context.horizontalPadding;

    return Semantics(
      container: true,
      label: l10n.loading,
      // 骨架块没有文字内容：读屏只播报「正在加载」，不逐个读占位盒。
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: CustomScrollView(
            key: const Key('discoverTracksSkeleton'),
            // 加载态不需要回弹 / 下拉；大字号下仍可滚动，不会溢出。
            physics: const ClampingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _header(context, theme)),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontal),
                sliver: SliverFixedExtentList.builder(
                  itemExtent: rowExtent,
                  itemCount: _rowCount,
                  itemBuilder: (context, index) =>
                      _row(context, theme, gap: cardList.gap),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ThemeData theme) {
    final type = context.typeScale;
    final horizontal = detailPageHorizontalPadding(context);
    final subtitleLine = scaledLineHeightOf(context, type.bodySmall);
    final descriptionLine = scaledLineHeightOf(context, type.bodySmall);
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(context),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: type.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    _bar(theme, widthFactor: 0.62, height: subtitleLine),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _bar(theme, widthFactor: 0.96, height: descriptionLine),
          const SizedBox(height: 6),
          _bar(theme, widthFactor: 0.72, height: descriptionLine),
          const SizedBox(height: 12),
          // 「播放全部」分裂按钮的占位：高度按 M3E 按钮常见行高，加载完成
          // 后按钮在同一位置出现，列表不会整体上移。
          _bar(theme, width: 132, height: 40, radius: 20),
        ],
      ),
    );
  }

  Widget _cover(BuildContext context) {
    Widget artwork(String? url) => DetailCoverArtwork(
      coverUrl: url,
      shape: DetailCoverShape.square,
      fallbackIcon: Icons.queue_music_rounded,
      heroTag: coverHeroTag,
    );
    final future = coverFuture;
    if (future == null) return artwork(coverUrl);
    return FutureBuilder<String?>(
      future: future,
      initialData: coverUrl,
      builder: (context, snapshot) => artwork(snapshot.data ?? coverUrl),
    );
  }

  Widget _row(BuildContext context, ThemeData theme, {required double gap}) {
    final type = context.typeScale;
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: Row(
        children: [
          Container(
            width: TrackRow.defaultCoverSize,
            height: TrackRow.defaultCoverSize,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bar(
                  theme,
                  widthFactor: 0.55,
                  height: scaledLineHeightOf(context, type.bodyLarge),
                ),
                const SizedBox(height: 4),
                _bar(
                  theme,
                  widthFactor: 0.35,
                  height: scaledLineHeightOf(context, type.bodyMedium),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 骨架块：宽度缺省铺满可用宽；[widthFactor] 用于不等长文字行。
  Widget _bar(
    ThemeData theme, {
    required double height,
    double? width,
    double? widthFactor,
    double radius = 8,
  }) {
    final block = Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    if (widthFactor == null) return block;
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: block,
    );
  }
}
