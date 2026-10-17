import 'package:flutter/gestures.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/responsive.dart';
import 'card_list_surface.dart';
import 'library_cover.dart';

/// 曲目行里的歌手链接（名字 + 点击回调；回调为空 = 纯文本）。
///
/// 搜索结果行传入逐名可点的歌手（内置平台曲目带平台内 id 时）；其它入口
/// 只传整串 [TrackRow.artist]，两者互斥（[TrackRow.artists] 非空即优先）。
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

/// 宽屏表格列（仅桌面宽屏列表传入；null = 现有单列布局，逐像素不变）。
///
/// 三列文案的空串 = 该列留空（不显示占位符）；列宽是表头
/// （`track_table_header.dart`）与行内共用的常量，两侧必须同源。
class TrackRowColumns {
  const TrackRowColumns({
    this.artist = '',
    this.album = '',
    this.duration = '',
  });

  /// 艺术家列文案（空串 = 留空）。
  final String artist;

  /// 专辑列文案（空串 = 留空）。
  final String album;

  /// 时长列文案（空串 = 留空）。
  final String duration;

  /// 表格列生效的最小窗口宽（与 browse 桌面断点同值，见
  /// `showTrackTableColumns`）。
  static const double minWidth = 900;

  static const double artistWidth = 200;
  static const double albumWidth = 200;
  static const double durationWidth = 64;
}

/// 固定行高的曲目行（队列 / 收藏 / 历史 / 发现详情 / 搜索结果共用）。
///
/// 行高固定为 [extent]（标题/歌手都单行省略），列表可以传 `itemExtent`
/// 预取高度（分段列表再加 [gapOf] 行距），滚动条拇指尺寸与拖动定位精确。
///
/// 表面用共享的 [CardListSurface]（M3E 列表规范 + 弹簧 shape morph）；
/// 为什么不用 `M3EListItem` / `M3EListRowSurface` 见 docs/pitfalls.md #20。
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.title,
    this.artist = '',
    this.artists,
    this.coverUrl,
    this.coverSize = 44,
    this.columns,
    this.trailingText,
    this.trailing,
    this.selected = false,
    this.showCheckWhenSelected = true,
    this.position = M3ECardPosition.single,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
  });

  /// 固定行高：可直接作为 `itemExtent` / `SliverFixedExtentList` 的高度
  /// （分段列表需再加 [gapOf] 行距）。
  static const double extent = 72;

  final String title;
  final String artist;

  /// 逐名可点的歌手（搜索结果）：非空时副标题按链接渲染（[artist] 仍作为
  /// 无障碍文案与回退）。仅当歌手带平台内 id（可进歌手页）时才需要。
  final List<TrackRowArtist>? artists;

  final String? coverUrl;
  final double coverSize;

  /// 宽屏表格列：非空时行内改为「封面+标题 / 艺术家 / 专辑 / 时长 / 行尾」
  /// 的表格布局，标题格只显示标题（副标题与逐名歌手链接让位给独立列）；
  /// null = 单列布局（[artist] / [artists] / [trailingText] 的既有行为）。
  final TrackRowColumns? columns;

  /// 行尾元信息（时长/计数），未知时传 null 不占位。
  /// 表格模式下不渲染（时长由 [columns] 的时长列承担）。
  final String? trailingText;

  /// 行尾插槽（排序把手、菜单按钮等）。
  final Widget? trailing;

  final bool selected;

  /// 多选态下把封面翻转为勾选图标；播放队列的选中行不需要。
  final bool showCheckWhenSelected;

  /// 行在列表中的位置：决定静止形状（首/末行外侧 16dp、内行 4dp）。
  /// 由列表用 `calculateCardPosition(index, count)` 计算。
  final M3ECardPosition position;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 行表面右键回调（桌面平台生效）：打开行尾 ⋮ 的**同一份**菜单
  /// （锚点仍是那个按钮，见 `TrackActionsMenuController`）。
  /// 触摸平台 / null 时无手势，行为与不传时逐像素一致。
  final VoidCallback? onSecondaryTap;

  /// 分段列表的相邻行距（M3E 列表卡片 token）。
  /// 列表 itemExtent 用 `TrackRow.extent + TrackRow.gapOf(context)`。
  static double gapOf(BuildContext context) =>
      M3ETheme.of(context).listTheme.cardList.gap;

  @override
  Widget build(BuildContext context) {
    final M3EThemeData m3e = M3ETheme.of(context);
    final M3EColorScheme scheme = m3e.colorScheme;
    final M3ETypeScale type = m3e.typeScale;
    final Color contentColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final Color supportingColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    final artistLinks = artists;
    final tableColumns = columns;

    Widget surface = CardListSurface(
      position: position,
      selected: selected,
      onPressed: onTap,
      onLongPress: onLongPress,
      semanticLabel: artist.isEmpty ? title : '$title, $artist',
      child: SizedBox(
        height: extent,
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              _buildLeading(context, scheme),
              const SizedBox(width: 12),
              Expanded(
                child: tableColumns == null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: type.bodyLarge.copyWith(color: contentColor),
                          ),
                          if (artistLinks != null && artistLinks.isNotEmpty)
                            _ArtistLinks(
                              artists: artistLinks,
                              style: type.bodyMedium
                                  .copyWith(color: supportingColor),
                              linkStyle: type.bodyMedium.copyWith(
                                color: scheme.primary,
                              ),
                            )
                          else if (artist.isNotEmpty)
                            Text(
                              artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: type.bodyMedium
                                  .copyWith(color: supportingColor),
                            ),
                        ],
                      )
                    : Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.bodyLarge.copyWith(color: contentColor),
                      ),
              ),
              if (tableColumns != null) ...[
                const SizedBox(width: 12),
                _buildColumn(
                  tableColumns.artist,
                  TrackRowColumns.artistWidth,
                  type.bodyMedium.copyWith(color: supportingColor),
                ),
                const SizedBox(width: 12),
                _buildColumn(
                  tableColumns.album,
                  TrackRowColumns.albumWidth,
                  type.bodyMedium.copyWith(color: supportingColor),
                ),
                const SizedBox(width: 12),
                _buildColumn(
                  tableColumns.duration,
                  TrackRowColumns.durationWidth,
                  type.bodyMedium.copyWith(color: supportingColor),
                ),
              ],
              if (tableColumns == null && trailingText != null) ...[
                const SizedBox(width: 12),
                // 行尾元信息贴行右缘：普通 Text 取自身宽度（不用 Flexible：
                // loose Flexible 会与标题列平分剩余宽度，时长只有 28dp 却
                // 占走一半、右侧留白）。封顶半行宽 + 省略：窄屏/超长元信息
                // 收缩省略，而不是把行撑溢出。
                ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: constraints.maxWidth / 2),
                  child: Text(
                    trailingText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: type.labelSmall.copyWith(color: supportingColor),
                  ),
                ),
              ],
              if (trailing != null) ...[
                const SizedBox(width: 12),
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

    if (!isDesktopPlatform()) return surface;
    // 桌面：右键 = 行尾 ⋮ 的同一份菜单。外挂一个只声明 onSecondaryTap 的
    // GestureDetector：主键 / 长按仍归 CardListSurface（M3ECard 的 InkWell
    // 不声明次级手势），两边在竞技场里各认各的按钮，互不抢手势。
    if (onSecondaryTap != null) {
      surface = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTap: onSecondaryTap,
        child: surface,
      );
    }
    // 行级 hover / focus 广播给 HoverReveal：行内 ⋮ 随**整行**悬停显现，
    // 而不是要求指针先精确移到按钮所在的小角落。
    return _RowRevealScope(child: surface);
  }

  /// 表格列单元格：固定列宽 + 单行省略（列宽是行与表头共用的常量）。
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
  Widget _buildLeading(BuildContext context, M3EColorScheme scheme) {
    final Widget cover = LibraryCoverThumb(url: coverUrl, size: coverSize);
    if (!showCheckWhenSelected) return cover;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: selected
          ? Icon(
              Icons.check_circle_rounded,
              key: const ValueKey<String>('selected'),
              size: coverSize * 0.7,
              color: scheme.onSecondaryContainer,
            )
          : KeyedSubtree(
              key: const ValueKey<String>('cover'),
              child: cover,
            ),
    );
  }
}

/// 行内操作（⋮ 菜单等）的 hover / 键盘 focus 显现包装。
///
/// 触摸端没有 hover 概念，隐藏入口等于把功能藏没：非桌面平台直接返回
/// [child]，与未包装逐像素一致。桌面平台默认透明并忽略指针，指针进入 /
/// 键盘焦点落入时淡入（150ms `M3EMotion.short3` + emphasized 曲线——
/// 透明度是 effects 档，走时长 + 曲线，不参与 spatial 弹簧；系统减弱动效
/// 时跳变）。[alwaysVisibleWhen] 供调用方在选中 / 多选态下常显。
///
/// 悬停判定以**行**为单位：放在 [TrackRow] 里时读行广播的整行 hover /
/// focus 状态（`_RowRevealScope`），⋮ 随整行悬停显现，不要求指针先精确
/// 移到按钮所在的小角落；不在行内使用时退化为包装自身的悬停 / 焦点。
class HoverReveal extends StatefulWidget {
  const HoverReveal({
    super.key,
    required this.child,
    this.alwaysVisibleWhen = false,
  });

  /// 被显现的内容（行内操作按钮等）；显隐不改变布局占位。
  final Widget child;

  /// 常显开关（桌面下也始终显示）：选中 / 多选态由调用方决定。
  final bool alwaysVisibleWhen;

  @override
  State<HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<HoverReveal> {
  bool _hovered = false;
  bool _focused = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() => _focused = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform()) return widget.child;
    final bool visible = widget.alwaysVisibleWhen ||
        _RowReveal.of(context) ||
        _hovered ||
        _focused;
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      // canRequestFocus: false 只用来观察子树焦点（FocusNode.hasFocus 对
      // 后代焦点同样为真），本身不占键盘 Tab 顺序。
      child: Focus(
        canRequestFocus: false,
        onFocusChange: _setFocused,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: reduceMotion ? Duration.zero : M3EMotion.short3,
          curve: M3EMotion.emphasizedDecelerate,
          // 透明（不可见）的内容不应截走指针：隐藏时点击穿透到行表面
          // （播放 / 右键），显现后才轮到按钮自己。
          child: IgnorePointer(ignoring: !visible, child: widget.child),
        ),
      ),
    );
  }
}

/// 行级 hover / 焦点广播（[TrackRow] 在桌面平台注入）：[HoverReveal] 据此
/// 跟随整行显现。用 InheritedWidget 而不是把状态透传参数层层下传——⋮ 在
/// 行的 `trailing` 槽里，中间隔着通用行布局，参数化会把两者焊死。
class _RowRevealScope extends StatefulWidget {
  const _RowRevealScope({required this.child});

  final Widget child;

  @override
  State<_RowRevealScope> createState() => _RowRevealScopeState();
}

class _RowRevealScopeState extends State<_RowRevealScope> {
  bool _revealed = false;

  void _setRevealed(bool value) {
    if (_revealed == value) return;
    setState(() => _revealed = value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _setRevealed(true),
      onExit: (_) => _setRevealed(false),
      // 键盘焦点同样显现行内操作：Tab 到行（或行内按钮）时 ⋮ 应可见。
      child: Focus(
        canRequestFocus: false,
        onFocusChange: _setRevealed,
        child: _RowReveal(revealed: _revealed, child: widget.child),
      ),
    );
  }
}

class _RowReveal extends InheritedWidget {
  const _RowReveal({required this.revealed, required super.child});

  final bool revealed;

  /// 读取最近的整行显现状态；不在 [TrackRow] 内时返回 false。
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_RowReveal>()
          ?.revealed ??
      false;

  @override
  bool updateShouldNotify(_RowReveal oldWidget) =>
      oldWidget.revealed != revealed;
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
