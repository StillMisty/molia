import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/source_script.dart';
import '../l10n/app_localizations.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 发现页统一渠道下拉框：搜索 / 热榜 / 歌单共用同一个渠道选择。
///
/// 只接收纯数据（[channels] + [selectedKey]）；渠道的顺序与启停由
/// 「音源管理」页维护（`SourcesProvider.moveChannel / setChannelEnabled`）。
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
    final entries = [for (final entry in channels) if (entry.enabled) entry];
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
