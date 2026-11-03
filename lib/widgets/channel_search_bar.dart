import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/source.dart';
import '../l10n/app_localizations.dart';
import 'app_search_bar.dart';
import 'discover_layout.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 桌面全局搜索的组合搜索条：左侧渠道下拉 + 细分割线 + 右侧搜索输入。
///
/// 渠道下拉不能塞进 [AppSearchBar] 的 leading 槽（固定 48dp），因此外层做
/// 一个与 M3E 搜索栏同色的 Stadium 胶囊，内部再嵌入 `margin: 0` 的
/// [AppSearchBar]；两层同色，视觉上仍是一颗胶囊。
///
/// 只有 1 个启用渠道时不渲染下拉，输入框占满整条（没有可切换的目标）。
class ChannelSearchBar extends StatelessWidget {
  const ChannelSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.channels,
    required this.selectedKey,
    required this.onChannelSelected,
    this.onChanged,
    this.onSubmitted,
    this.onEscape,
    this.autofocus = false,
    this.enabled = true,
  });

  /// 渠道下拉的稳定 Key（测试定位用）。
  static const Key channelDropdownKey = Key('channelSearchChannelDropdown');

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// 全部启用渠道（含当前渠道可能不在列表里的恢复场景）。
  final List<SourceDescriptor> channels;

  final String selectedKey;
  final ValueChanged<String> onChannelSelected;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEscape;
  final bool autofocus;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final barTheme = m3e.searchBarTheme;
    final scheme = Theme.of(context).colorScheme;
    final bar = AppSearchBar(
      controller: controller,
      focusNode: focusNode,
      hintText: hintText,
      autofocus: autofocus,
      enabled: enabled,
      margin: 0,
      expandOnFocus: false,
      // M3E 默认 minWidth 360 会在窄窗 / 组合条里溢出：组合条由外层分配
      // 宽度，内层只保留高度下限。
      constraints: BoxConstraints(
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: barTheme.minHeight,
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onEscape: onEscape,
    );

    // 单渠道：没有可切换目标，输入占满整条。
    if (channels.length < 2) return bar;

    final selectorWidth = math.min(
      148.0,
      math.max(120.0, discoverChannelSelectorWidth(context)),
    );
    final l10n = _l10n(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: barTheme.backgroundColor(m3e.colorScheme),
        shape: const StadiumBorder(),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Row(
          children: [
            SizedBox(
              width: selectorWidth,
              child: Semantics(
                container: true,
                label: l10n.searchSourcesLabel,
                child: M3EDropdownMenu<String>(
                  key: channelDropdownKey,
                  items: [
                    for (final channel in channels)
                      M3EDropdownItem<String>(
                        label: channel.displayName,
                        value: channel.key,
                        selected: channel.key == selectedKey,
                      ),
                  ],
                  singleSelect: true,
                  // 单选用纯文本展示（默认 chip 模式点击会取消选中）。
                  showChipAnimation: false,
                  searchEnabled: channels.length > 8,
                  fieldStyle: M3EDropdownFieldStyle(
                    // 透明 + 无边框：让外层胶囊成为唯一可见底色。
                    backgroundColor: Colors.transparent,
                    foregroundColor: scheme.onSurface,
                    border: BorderSide.none,
                    focusedBorder: BorderSide.none,
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    hintText: l10n.searchSourcesLabel,
                  ),
                  dropdownStyle: M3EDropdownPanelStyle(
                    noItemsFoundText: l10n.noItemsFound,
                  ),
                  onSelectionChanged: (items) {
                    if (items.isEmpty) return;
                    onChannelSelected(items.first.value);
                  },
                ),
              ),
            ),
            // 细分割线区分渠道与输入；高度取胶囊内文字行高附近。
            Container(width: 1, height: 24, color: scheme.outlineVariant),
            Expanded(child: bar),
          ],
        ),
      ),
    );
  }
}
