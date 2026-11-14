import 'package:material_ui/material_ui.dart';

import '../domain/models/source.dart' show SourceDescriptor;
import 'channel_picker.dart';

/// 启用渠道（顺序不变）。
List<SourceDescriptor> _enabledOf(List<SourceDescriptor> channels) {
  return [
    for (final entry in channels)
      if (entry.enabled) entry,
  ];
}

/// 发现页统一渠道选择器：搜索 / 热榜 / 歌单共用同一个渠道选择。
///
/// 只接收纯数据（[channels] + [selectedKey]）；渠道的顺序与启停由
/// 「音源管理」页维护（`SourcesProvider.reorderChannel / setChannelEnabled`）。
/// 触发框宽度由 [ChannelPicker] 按当前渠道名实测，[maxWidth] 由顶部工具行
/// 扣掉可见 tab 槽位后传入。
class LibraryChannelSelector extends StatelessWidget {
  const LibraryChannelSelector({
    super.key,
    required this.channels,
    required this.selectedKey,
    required this.onSelected,
    required this.maxWidth,
  });

  /// 触发框稳定 Key（测试定位用）。
  static const Key triggerKey = Key('libraryChannelSelectorTrigger');

  /// 全部渠道（含停用项；本组件只展示启用项）。
  final List<SourceDescriptor> channels;

  /// 当前选中的渠道 key。
  final String selectedKey;

  /// 选择渠道（不会回调停用项）。
  final ValueChanged<String> onSelected;

  /// 触发框宽度上限（顶部工具行剩余空间）。
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final entries = _enabledOf(channels);
    if (entries.length < 2) return const SizedBox.shrink();
    return ChannelPicker(
      triggerKey: triggerKey,
      channels: entries,
      selectedKey: selectedKey,
      onSelected: onSelected,
      maxWidth: maxWidth,
    );
  }
}
