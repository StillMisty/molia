import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'card_list_surface.dart';

/// 合集条目：收藏 / 播放历史 / 本地歌曲伪合集（哨兵 id）或一个自建列表。
///
/// 收藏页的合集弹层与桌面宽屏的左侧合集栏共用同一份条目：顺序、图标、
/// 数量与选中态都由收藏页统一解析（持久化顺序 + 自然顺序），两处不再各自
/// 拼装一套合集列表。
class CollectionEntry {
  const CollectionEntry({
    required this.key,
    required this.id,
    required this.name,
    required this.icon,
    required this.trackCount,
    required this.selected,
    this.playlistId,
  });

  /// 顺序持久化键：`favorites` / `history` / `downloads` / `playlist:<id>`。
  final String key;

  /// 选择结果：哨兵值或列表 id。
  final int id;

  final String name;
  final IconData icon;
  final int trackCount;

  /// 当前正在浏览的合集（列表选中态）。
  final bool selected;

  /// 非空表示自建列表（可重命名 / 删除）。
  final int? playlistId;

  CollectionEntry copyWithName(String name) => CollectionEntry(
        key: key,
        id: id,
        name: name,
        icon: icon,
        trackCount: trackCount,
        selected: selected,
        playlistId: playlistId,
      );
}

/// 收藏页桌面宽屏版式的左侧合集栏（master-detail 的 master）。
///
/// 桌面平台 + 宽窗口时收藏页改用「左合集栏 + 右曲目列表」：条目与合集弹层
/// 同源，点击即切换合集（走页面同一套切换逻辑，含滚动位置簿记与搜索复位）；
/// 栏内可滚动，自建列表再多也不挤压右侧列表。窄窗口与移动 / 平板平台不挂载
/// 本组件（保持标题行弹层切换）。
class CollectionRail extends StatefulWidget {
  const CollectionRail({
    super.key,
    required this.entries,
    required this.onSelected,
  });

  /// 栏宽（含内边距）：与桌面壳层侧栏展开档同值（240dp），
  /// 主要宽度留给右侧曲目列表。
  static const double width = 240;

  /// 行高：单行「图标 + 合集名」，比曲目行矮一档（这里只是导航，不是内容）。
  static const double rowHeight = 48;

  /// 合集条目（顺序与合集弹层一致）。
  final List<CollectionEntry> entries;

  /// 点击条目：回传条目的选择 id（哨兵值或列表 id），由页面完成切换。
  final ValueChanged<int> onSelected;

  @override
  State<CollectionRail> createState() => _CollectionRailState();
}

class _CollectionRailState extends State<CollectionRail> {
  /// 自带滚动控制器：栏内滚动与右侧曲目列表的滚动位置互不影响
  /// （常显滚动条也需要固定控制器）。
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final type = m3e.typeScale;
    final gap = m3e.listTheme.cardList.gap;
    final count = widget.entries.length;
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      interactive: true,
      child: ListView.builder(
        controller: _controller,
        // 左内边距对齐页面标题行的水平留白，右内边距留出与列表分栏的间隔；
        // 顶部留白与标题行的顶部留白一致，两栏首行视觉齐平。
        padding: const EdgeInsets.fromLTRB(32, 12, 16, 12),
        itemExtent: CollectionRail.rowHeight + gap,
        itemCount: count,
        itemBuilder: (context, index) {
          final entry = widget.entries[index];
          final contentColor =
              entry.selected ? scheme.onSecondaryContainer : scheme.onSurface;
          return Padding(
            padding: EdgeInsets.only(bottom: gap),
            // 行表面走共享的 CardListSurface：选中 = M3E 列表选中容器
            // （secondaryContainer），形状 / 弹簧与右侧曲目行同源。
            child: CardListSurface(
              position: calculateCardPosition(index, count),
              selected: entry.selected,
              semanticLabel: entry.name,
              onPressed: () => widget.onSelected(entry.id),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                height: CollectionRail.rowHeight,
                child: Row(
                  children: [
                    Icon(
                      entry.icon,
                      size: 20,
                      color: entry.selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.bodyMedium.copyWith(color: contentColor),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
