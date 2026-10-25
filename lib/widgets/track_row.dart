import 'package:flutter/gestures.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../utils/duration_text.dart';
import '../utils/responsive.dart';
import 'card_list_surface.dart';
import 'current_track_cover.dart';
import 'playback_selectors.dart';
import 'track_artwork.dart';

/// 曲目行里的歌手链接（名字 + 点击回调；回调为空 = 纯文本）。
///
/// 搜索结果行传入逐名可点的歌手（内置平台曲目带平台内 id 时）；其它入口
/// 只传整串 [TrackRowModel.artist]，两者互斥（[TrackRowModel.artists] 非空
/// 即优先）。
class TrackRowArtist {
  final String name;
  final VoidCallback? onTap;

  const TrackRowArtist({required this.name, this.onTap});

  @override
  bool operator ==(Object other) =>
      other is TrackRowArtist && other.name == name && other.onTap == onTap;

  @override
  int get hashCode => Object.hash(name, onTap);
}

/// 宽屏表格的列宽规范（行与表头共用的唯一宽表）。
///
/// 为什么单独一层：列宽与「有没有播放时间列」必须行列两端同源——表头
/// （`track_table_header.dart`）只接收本对象，两处各写一套宽表迟早错位。
/// 列的有无是**整套表格**的决定（[timeWidth] = 0 即不显示），不是逐行的：
/// 单行的空文案只让该格留空，否则同一表内行与行、行与表头都会左右错位。
class TrackRowColumnSpec {
  const TrackRowColumnSpec({
    this.titleMaxWidth = 480,
    this.artistWidth = 200,
    this.albumWidth = 200,
    this.timeWidth = 0,
    this.durationWidth = 64,
    this.minContentWidth = minWidth,
  });

  /// 标题列宽度上限：超宽内容区里标题不再无限拉长，右侧固定列仍贴行右缘
  /// （表头列缘因此不用跟着重算）。
  final double titleMaxWidth;

  /// 艺术家列宽。
  final double artistWidth;

  /// 专辑列宽。
  final double albumWidth;

  /// 播放时间列宽；0 = 整套表格不显示该列（搜索结果 / 发现详情 / 收藏 /
  /// 本地歌曲都没有这列）。
  final double timeWidth;

  /// 时长列宽。
  final double durationWidth;

  /// 本套列不把行撑溢出所需的最小内容宽（内容宽 = 窗口宽 − 实际栏宽，判据见
  /// `DesktopLayout.tableColumnsFor`）：固定列 + 行内网格（封面位与各处列
  /// 间距）+ 行表面内边距 + 页面横向留白（桌面档 24×2）。
  /// 按当前页边距算：默认一档 44 + 5×12 + (200+200+64+56) + 32 + 48 = 704、
  /// 历史档 44 + 6×12 + (180+180+120+64+56) + 32 + 48 = 796；两处都有测试
  /// 钉住（改列宽或页边距必须同步核算，否则阈值处就横向溢出）。
  /// 阈值取**保守值** 720 / 812（按更大的页边距推得），页边距收窄后余量
  /// 只会更宽，不下调。
  final double minContentWidth;

  /// 整套表格是否显示播放时间列（仅播放历史为真）。
  bool get hasTimeColumn => timeWidth > 0;

  /// 默认一档（搜索结果 / 发现详情 / 收藏 / 本地歌曲）：歌手 / 专辑 200、
  /// 时长 64，无播放时间列（收藏的蓝图列宽与本档同值）。
  static const TrackRowColumnSpec standard = TrackRowColumnSpec();

  /// 播放历史：多一列「播放时间」，歌手 / 专辑相应收窄，标题上限同步下调
  /// （列宽总和按内容宽 1136 实测留得下）；固定列多一格，最小内容宽相应
  /// 抬高，否则 720–812 的内容区里表头 / 行会横向溢出。
  static const TrackRowColumnSpec history = TrackRowColumnSpec(
    titleMaxWidth: 400,
    artistWidth: 180,
    albumWidth: 180,
    timeWidth: 120,
    minContentWidth: 812,
  );

  /// 默认一档规范生效的最小内容宽（内容宽 = 窗口宽 − 实际栏宽；判据见
  /// `DesktopLayout.tableColumnsFor`）。
  static const double minWidth = 720;

  /// 表格模式行尾动作槽宽（⋮ 菜单 / 缓存标签 / 拖动把手都落在槽内）：
  /// 行与表头共用同一宽度，列左缘只由列宽决定，不随行尾内容漂移。
  /// 取值 56 = `TrackActionsMenu` 锚点（`M3EIconButton` md）的宽度。
  static const double trailingSlotWidth = 56;
}

/// 一行曲目的展示数据（不可变）。
///
/// 调用方只填自己有的字段，不再逐个参数拼行；表格 / 双行版式由
/// [TrackRowSurface.tableSpec] 决定（见 [TrackRow]）。
class TrackRowModel {
  const TrackRowModel({
    required this.title,
    this.artist = '',
    this.artists,
    this.artistNames = const [],
    this.coverUrl,
    this.durationMs,
    this.album = '',
    this.time = '',
    this.trailingText,
    this.trackId,
    this.coverKey,
    this.selected = false,
  });

  final String title;

  /// 双行副标题（纯文本）。歌词搜索时是命中片段；空串隐藏副标题。
  final String artist;

  /// 逐名可点的歌手（搜索结果）：非空时双行副标题按链接渲染。
  final List<TrackRowArtist>? artists;

  /// 表格歌手列的候选名（搜索行给全部歌手）；空则回退 [artist]。
  final List<String> artistNames;

  final String? coverUrl;

  /// 时长（毫秒）：双行档行尾 / 表格档时长列都由模块统一格式化。
  /// 未知传 null，行尾不占位。
  final int? durationMs;

  /// 专辑列文案（仅表格档渲染；空串 = 该格留空）。
  final String album;

  /// 播放时间列文案（仅 [TrackRowColumnSpec.hasTimeColumn] 的表格档渲染）。
  final String time;

  /// 行尾覆盖文案（播放次数等非时长信息）；null = 用 [durationMs] 格式化。
  /// 表格档不渲染（时长由列承担）。
  final String? trailingText;

  /// 行身份：传入后由 [TrackRow] 逐行订阅「是否当前曲目」。
  /// null = 不订阅（非曲目行，或不需要高亮当前曲目的场景；队列行也会传）。
  final TrackId? trackId;

  /// 自定义封面查询键（默认取 [trackId] 的 `sourceKey:songId`）。
  ///
  /// 不传 [trackId] 的曲目行（换源候选等）要显示自定义封面时显式给它；
  /// 普通非曲目行留 null，不会去查封面索引。
  final String? coverKey;

  /// 实际查询键：显式 [coverKey] 优先，否则回退 [trackId]。
  String? get effectiveCoverKey => coverKey ?? trackId?.uri;

  final bool selected;

  /// 表格歌手列：全部歌手名以「、」连接；没有候选名时回退 [artist]。
  String get tableArtist =>
      artistNames.isEmpty ? artist : artistNames.join('、');
}

/// 一个列表表面的行呈现口径（同一列表的所有行共用）。
///
/// 版式只由 [tableSpec] 决定：非空 = 宽屏表格（单行 + 独立列），null =
/// 双行（标题 + 副标题）。调用方不再自己判断「表格还是双行」以及哪些字段
/// 该让位（表格档自动忽略副标题 / 歌手链接 / 行尾覆盖文案）。
class TrackRowSurface {
  const TrackRowSurface({
    this.coverSize = TrackRow.defaultCoverSize,
    this.tableSpec,
    this.showCheckWhenSelected = true,
  });

  /// 行内封面边长（队列 / 换源等紧凑列表用 40）。
  final double coverSize;

  /// 表格列规范：非空 = 表格档；null = 双行档。
  final TrackRowColumnSpec? tableSpec;

  /// 多选态下把封面翻转为勾选图标；播放队列的选中行不需要。
  final bool showCheckWhenSelected;

  bool get isTable => tableSpec != null;
}

/// 固定行高的曲目行（队列 / 收藏 / 历史 / 发现详情 / 搜索结果共用）。
///
/// 行高只有两档，取 M3E 列表 token（见 [extentOf]）：表格档单行 56（标题 +
/// 独立列）、非表格档双行 72（标题 + 副标题），标题 / 列文案都单行省略；
/// 列表据此传 `itemExtent` 预取高度（分段列表再加 [gapOf] 行距），滚动条
/// 拇指尺寸与拖动定位精确。
///
/// 表面用共享的 [CardListSurface]（M3E 列表规范 + 弹簧 shape morph）；
/// 为什么不用 `M3EListItem` / `M3EListRowSurface` 见 docs/pitfalls.md #20。
///
/// 调用方只给 [TrackRowModel] + [TrackRowSurface] + 行内回调：当前曲目订阅
/// （[selectCurrentTrackState]）、时长格式化（[durationText]）、表格 / 双行
/// 版式与选中 / 当前优先级都在本模块内。
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.model,
    this.position = M3ECardPosition.single,
    this.surface = const TrackRowSurface(),
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
  });

  /// 非表格（双行：标题 + 副标题）行高；等于 M3E 列表 token
  /// `M3EListItemTheme.twoLineHeight` 的默认值（测试钉住两者同值）。
  ///
  /// 为什么保留常量：队列 / 专辑 / 歌手等**没有表格档**的列表直接拿它当
  /// `itemExtent`（它们恒为双行，没有两档可取）；带表格档的列表一律走
  /// [extentOf]（token 同源 + 按档取高）。
  static const double extent = 72;

  /// 固定行高（M3E 列表 token）：表格档是单行（标题 + 独立列）取
  /// `minHeight`（56），非表格档是双行（标题 + 副标题）取 `twoLineHeight`
  /// （72）。列表 `itemExtent` 用 `extentOf(context, ...) + gapOf(context)`。
  static double extentOf(BuildContext context, {required bool tableColumns}) {
    final M3EListItemTheme item = M3ETheme.of(context).listTheme.item;
    return tableColumns ? item.minHeight : item.twoLineHeight;
  }

  /// 行内封面默认边长（行内封面位 = 本值 + 列表 token 的槽间距）：
  /// 表头（`track_table_header.dart`）按同一常量复刻留白结构。
  static const double defaultCoverSize = 44;

  /// 行数据：标题 / 歌手 / 封面 / 时长 / 身份 / 选中态。
  final TrackRowModel model;

  /// 行在列表中的位置：决定静止形状（首/末行外侧 16dp、内行 4dp）。
  /// 由列表用 `calculateCardPosition(index, count)` 计算。
  final M3ECardPosition position;

  /// 列表表面的呈现口径（封面尺寸 / 表格规范 / 勾选策略）。
  final TrackRowSurface surface;

  /// 行尾插槽（排序把手、菜单按钮等）。
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 行表面右键回调（桌面平台生效）：参数 = 右键落点的全局坐标，供操作菜单
  /// 在落点弹出（`showTrackActionsMenuAtPointer`）。触摸平台 / null 时无手势，
  /// 行为与不传时逐像素一致。
  final void Function(Offset globalPosition)? onSecondaryTap;

  /// 分段列表的相邻行距（M3E 列表卡片 token）。
  /// 列表 itemExtent 用 `TrackRow.extentOf(context, ...) + TrackRow.gapOf(context)`。
  static double gapOf(BuildContext context) =>
      M3ETheme.of(context).listTheme.cardList.gap;

  @override
  Widget build(BuildContext context) {
    final M3EThemeData m3e = M3ETheme.of(context);
    final M3EColorScheme scheme = m3e.colorScheme;
    final M3ETypeScale type = m3e.typeScale;
    // 行内网格与表头同源：槽间距与表面内边距都取 M3E 列表 token（默认
    // 12 / 16），`track_table_header.dart` 用同一批值复刻留白结构。
    final M3EListItemTheme itemTheme = m3e.listTheme.item;
    final double gap = itemTheme.gap;
    final bool selected = model.selected;
    final TrackId? trackId = model.trackId;
    // 当前曲目订阅只有这一份实现：行自己的 build 里逐行 select，只重建本行。
    final CurrentTrackState current = trackId == null
        ? (isCurrent: false, isPlaying: false)
        : selectCurrentTrackState(context, trackId);
    final bool isCurrent = current.isCurrent;
    final bool isPlaying = current.isPlaying;
    final Color contentColor = selected
        ? scheme.onSecondaryContainer
        : isCurrent
            ? scheme.primary
            : scheme.onSurface;
    final Color supportingColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    // 当前曲目的状态进整行语义：角标图形本身被排除语义，读屏仍能听到
    // 「正在播放 / 已暂停」。没有 l10n delegate 的组件测试省略状态词。
    final l10n = AppLocalizations.of(context);
    final stateLabel = isCurrent
        ? (isPlaying ? l10n?.nowPlayingSection : l10n?.nowPlayingPaused)
        : null;
    final artistLinks = model.artists;
    final TrackRowColumnSpec? tableSpec = surface.tableSpec;
    final semanticArtist = tableSpec == null ? model.artist : model.tableArtist;
    final semanticLabel = [
      semanticArtist.isEmpty ? model.title : '${model.title}, $semanticArtist',
      ?stateLabel,
    ].join(', ');
    final String? durationLabel = durationText(model.durationMs);
    final String? trailingText = model.trailingText ?? durationLabel;

    Widget row = CardListSurface(
      position: position,
      selected: selected,
      onPressed: onTap,
      onLongPress: onLongPress,
      semanticLabel: semanticLabel,
      padding: EdgeInsets.symmetric(horizontal: itemTheme.horizontalPadding),
      child: SizedBox(
        height: TrackRow.extentOf(context, tableColumns: tableSpec != null),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              _buildLeading(
                context,
                scheme,
                isCurrent: isCurrent,
                isPlaying: isPlaying,
              ),
              SizedBox(width: gap),
              Expanded(
                child: tableSpec == null
                    ? _buildTwoLineText(
                        type: type,
                        contentColor: contentColor,
                        supportingColor: supportingColor,
                        scheme: scheme,
                        artistLinks: artistLinks,
                      )
                    // 标题列上限（[TrackRowColumnSpec.titleMaxWidth]）：
                    // Align 先把 Expanded 的紧约束放松，ConstrainedBox 的上限
                    // 才真正生效（直接套在 Expanded 里会被紧约束顶回满宽）。
                    // 标题格仍占满剩余宽度，右侧固定列（含表头）列缘不动。
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: tableSpec.titleMaxWidth,
                          ),
                          child: Text(
                            model.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: type.bodyLarge.copyWith(color: contentColor),
                          ),
                        ),
                      ),
              ),
              if (tableSpec != null) ...[
                SizedBox(width: gap),
                _buildColumn(
                  model.tableArtist,
                  tableSpec.artistWidth,
                  type.bodyMedium.copyWith(color: supportingColor),
                ),
                SizedBox(width: gap),
                _buildColumn(
                  model.album,
                  tableSpec.albumWidth,
                  type.bodyMedium.copyWith(color: supportingColor),
                ),
                if (tableSpec.hasTimeColumn) ...[
                  SizedBox(width: gap),
                  _buildColumn(
                    model.time,
                    tableSpec.timeWidth,
                    type.bodyMedium.copyWith(color: supportingColor),
                  ),
                ],
                SizedBox(width: gap),
                _buildColumn(
                  durationLabel ?? '',
                  tableSpec.durationWidth,
                  type.bodyMedium.copyWith(color: supportingColor),
                ),
                SizedBox(width: gap),
                // 行尾固定槽：行尾内容（⋮ 菜单 / 缓存标签 / 拖动把手）按
                // 槽宽布局，列左缘不因内容有无、宽窄而左右移动；表头按同一
                // 槽宽预留，两侧列缘恒对齐。
                SizedBox(
                  width: TrackRowColumnSpec.trailingSlotWidth,
                  child: trailing == null
                      ? null
                      : Align(
                          alignment: Alignment.centerRight,
                          child: IconTheme.merge(
                            data: IconThemeData(
                              color: supportingColor,
                              size: 20,
                            ),
                            child: trailing!,
                          ),
                        ),
                ),
              ],
              if (tableSpec == null && trailingText != null) ...[
                SizedBox(width: gap),
                // 行尾元信息贴行右缘：普通 Text 取自身宽度（不用 Flexible：
                // loose Flexible 会与标题列平分剩余宽度，时长只有 28dp 却
                // 占走一半、右侧留白）。封顶半行宽 + 省略：窄屏/超长元信息
                // 收缩省略，而不是把行撑溢出。
                ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: constraints.maxWidth / 2),
                  child: Text(
                    trailingText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: type.labelSmall.copyWith(color: supportingColor),
                  ),
                ),
              ],
              if (tableSpec == null && trailing != null) ...[
                SizedBox(width: gap),
                IconTheme.merge(
                  data: IconThemeData(color: supportingColor, size: 20),
                  child: trailing!,
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (!isDesktopPlatform()) return row;
    if (onSecondaryTap != null) {
      // 桌面：右键 = 行操作菜单（在落点弹出，行尾不再有 ⋮ 锚点）。外挂一个
      // 只声明次级手势的 GestureDetector：主键 / 长按仍归 CardListSurface
      // （M3ECard 的 InkWell 不声明次级手势），两边在竞技场里各认各的按钮，
      // 互不抢手势。
      row = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (details) => onSecondaryTap!(details.globalPosition),
        child: row,
      );
    }
    return row;
  }

  /// 双行档副标题：逐名可点歌手优先，否则整串纯文本（空串隐藏副标题）。
  Widget _buildTwoLineText({
    required M3ETypeScale type,
    required Color contentColor,
    required Color supportingColor,
    required M3EColorScheme scheme,
    required List<TrackRowArtist>? artistLinks,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          model.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: type.bodyLarge.copyWith(color: contentColor),
        ),
        if (artistLinks != null && artistLinks.isNotEmpty)
          _ArtistLinks(
            artists: artistLinks,
            style: type.bodyMedium.copyWith(color: supportingColor),
            linkStyle: type.bodyMedium.copyWith(color: scheme.primary),
          )
        else if (model.artist.isNotEmpty)
          Text(
            model.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.bodyMedium.copyWith(color: supportingColor),
          ),
      ],
    );
  }

  /// 表格列单元格：固定列宽 + 单行省略（列宽来自 [TrackRowColumnSpec]，
  /// 与表头同源）。
  ///
  /// 空串照常渲染空 [Text]：列位置由列宽占住，不因缺值左右移动。
  Widget _buildColumn(String text, double width, TextStyle style) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: style,
      ),
    );
  }

  /// 缩略图 / 多选勾选翻转（M3E 列表的 selectedIcon 语义）。
  ///
  /// 当前曲目角标只在封面可见时叠加：多选勾选占住前导槽时让位给勾选图标，
  /// 标题主色仍表达当前曲目。
  ///
  /// 自定义封面 / 默认封面订阅收在 [TrackArtwork] 内：行内不再自己听
  /// revision，选择 / 恢复封面后不换行也会立即换图。
  Widget _buildLeading(
    BuildContext context,
    M3EColorScheme scheme, {
    required bool isCurrent,
    required bool isPlaying,
  }) {
    final bool showsCheck = model.selected && surface.showCheckWhenSelected;
    final Widget artwork = TrackArtwork(
      coverKey: model.effectiveCoverKey,
      originalUrl: model.coverUrl,
      size: surface.coverSize,
      borderRadius: BorderRadius.circular(10),
      memCacheWidth:
          (surface.coverSize * MediaQuery.of(context).devicePixelRatio).round(),
      fallbackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
    final Widget cover = isCurrent && !showsCheck
        ? CurrentTrackCover(
            cover: artwork,
            size: surface.coverSize,
            isPlaying: isPlaying,
          )
        : artwork;
    if (!surface.showCheckWhenSelected) return cover;
    // 前导槽按封面尺寸固定：AnimatedSwitcher 默认以 Stack 的最大子项定宽，
    // 勾选图标只有 coverSize * 0.7，淡出结束后单独留下时槽会收窄，标题与
    // 表格列随之左移（表头仍按封面尺寸预留）。固定槽宽让切换不影响行内网格。
    return SizedBox.square(
      dimension: surface.coverSize,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: model.selected
            ? Icon(
                Icons.check_circle_rounded,
                key: const ValueKey<String>('selected'),
                size: surface.coverSize * 0.7,
                color: scheme.onSecondaryContainer,
              )
            : KeyedSubtree(
                key: const ValueKey<String>('cover'),
                child: cover,
              ),
      ),
    );
  }
}

/// 逐名可点的歌手副标题：单行 `Text.rich` + 每个可点名字一个
/// [TapGestureRecognizer]（点击不触发行本身的播放手势）。
///
/// 为什么是 StatefulWidget：识别器必须持有并释放（`dispose`），
/// stateless 的 `Text.rich` 每次 build 新建识别器会泄漏。重建时先释放上一批
/// 识别器——手势只在帧间事件循环里派发，build 期释放是安全的。
class _ArtistLinks extends StatefulWidget {
  const _ArtistLinks({
    required this.artists,
    required this.style,
    required this.linkStyle,
  });

  final List<TrackRowArtist> artists;
  final TextStyle style;
  final TextStyle linkStyle;

  @override
  State<_ArtistLinks> createState() => _ArtistLinksState();
}

class _ArtistLinksState extends State<_ArtistLinks> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _releaseRecognizers();
    super.dispose();
  }

  void _releaseRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _releaseRecognizers();
    final spans = <TextSpan>[];
    for (var index = 0; index < widget.artists.length; index++) {
      final artist = widget.artists[index];
      if (index > 0) spans.add(TextSpan(text: '、', style: widget.style));
      final onTap = artist.onTap;
      if (onTap == null) {
        spans.add(TextSpan(text: artist.name, style: widget.style));
        continue;
      }
      final recognizer = TapGestureRecognizer()..onTap = onTap;
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: artist.name,
        style: widget.linkStyle,
        recognizer: recognizer,
      ));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }
}
