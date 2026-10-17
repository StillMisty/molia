import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/source_script.dart';
import '../l10n/app_localizations.dart';
import 'card_list_surface.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 启用渠道（顺序不变）；两个渠道切换组件共用同一过滤口径。
List<SourceEntry> _enabledOf(List<SourceEntry> channels) {
  return [for (final entry in channels) if (entry.enabled) entry];
}

/// 发现页统一渠道下拉框：搜索 / 热榜 / 歌单共用同一个渠道选择。
///
/// 只接收纯数据（[channels] + [selectedKey]）；渠道的顺序与启停由
/// 「音源管理」页维护（`SourcesProvider.reorderChannel / setChannelEnabled`）。
class LibraryChannelSelector extends StatelessWidget {
  const LibraryChannelSelector({
    super.key,
    required this.channels,
    required this.selectedKey,
    required this.onSelected,
  });

  /// 全部渠道（含停用项；本组件只展示启用项）。
  final List<SourceEntry> channels;

  /// 当前选中的渠道 key。
  final String selectedKey;

  /// 选择渠道（不会回调停用项）。
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final entries = _enabledOf(channels);
    if (entries.length < 2) return const SizedBox.shrink();
    return SizedBox(
      width: 132,
      child: M3EDropdownMenu<String>(
        items: [
          for (final entry in entries)
            M3EDropdownItem<String>(
              label: entry.name,
              value: entry.key,
              selected: entry.key == selectedKey,
            ),
        ],
        singleSelect: true,
        // 单选用纯文本展示（默认 chip 模式点击会取消选中）。
        showChipAnimation: false,
        // 渠道较多（多脚本 / any-listen）时提供搜索过滤。
        searchEnabled: entries.length > 8,
        fieldStyle: M3EDropdownFieldStyle(
          hintText: _l10n(context).libraryChannelSelect,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        onSelectionChanged: (items) {
          if (items.isEmpty) return;
          onSelected(items.first.value);
        },
      ),
    );
  }
}

/// 发现页的桌面宽屏渠道左栏（内容区左侧固定 200dp）。
///
/// 与 [LibraryChannelSelector] 是同一渠道状态的两种形态：宽屏竖栏多一个
/// 常驻的「当前在哪」上下文，窄窗口 / 移动端仍用顶部下拉框（页面二选一，
/// 不出现两套切换入口）。
///
/// 每项用共享的 [CardListSurface]（M3E 列表卡片行 + 弹簧 shape morph）：
/// 选中态与其余列表同源（`secondaryContainer` 底 + `onSecondaryContainer`
/// 文字，见 `TrackRow` 的 selected 语义），不另造一套选中观感。
class LibraryChannelRail extends StatelessWidget {
  const LibraryChannelRail({
    super.key,
    required this.channels,
    required this.selectedKey,
    required this.onSelected,
  });

  /// 栏宽（内容区左侧固定宽度，含行内边距）。
  static const double width = 200;

  /// 行高：M3E 单行列表项最小高度（渠道名单行省略）。
  static const double itemHeight = 56;

  /// 全部渠道（含停用项；本组件只展示启用项）。
  final List<SourceEntry> channels;

  /// 当前选中的渠道 key。
  final String selectedKey;

  /// 选择渠道（不会回调停用项）。
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final entries = _enabledOf(channels);
    final M3EThemeData m3e = M3ETheme.of(context);
    final M3EColorScheme scheme = m3e.colorScheme;
    final M3ETypeScale type = m3e.typeScale;
    final double gap = m3e.listTheme.cardList.gap;

    return SizedBox(
      width: width,
      child: ListView.builder(
        // 右侧留白比左侧小：卡片行自身已有 16dp 内边距，与内容区拉开即可。
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          final selected = entry.key == selectedKey;
          return Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: CardListSurface(
              position: calculateCardPosition(index, entries.length),
              selected: selected,
              onPressed: () => onSelected(entry.key),
              semanticLabel: entry.name,
              child: SizedBox(
                height: itemHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodyLarge.copyWith(
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
