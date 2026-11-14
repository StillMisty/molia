import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/source.dart';
import '../l10n/app_localizations.dart';
import 'app_search_bar.dart';
import 'channel_dropdown.dart';
import 'discover_layout.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 桌面全局搜索的组合搜索条：单层胶囊，渠道下拉占据原搜索图标位置。
///
/// 多渠道时整条是一个 M3E 风格胶囊：左侧透明背景 + outline 描边的渠道 chip
/// → 输入 → 清除键；不再嵌套第二层 [AppSearchBar]，也不显示搜索图标。
/// 单渠道时没有可切换目标，回退到 [AppSearchBar]（左侧搜索图标 + 输入占满）。
///
/// [showChannelChip] 为 false 时是同一条胶囊的「无 chip」变体：不渲染渠道
/// 下拉（资料库搜索 tab 顶部已有唯一渠道控件），高度 / 清除键 / 焦点环与
/// Ctrl+F 完全同源，避免同一页出现两个渠道入口或两套搜索框观感。
class ChannelSearchBar extends StatelessWidget {
  const ChannelSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    this.channels = const <SourceDescriptor>[],
    this.selectedKey = '',
    this.onChannelSelected,
    this.onChanged,
    this.onSubmitted,
    this.onEscape,
    this.autofocus = false,
    this.enabled = true,
    this.showChannelChip = true,
    this.channelFocusNode,
  });

  /// 渠道下拉的稳定 Key（测试定位用）。
  static const Key channelDropdownKey = Key('channelSearchChannelDropdown');

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// 全部启用渠道（含当前渠道可能不在列表里的恢复场景）。
  ///
  /// 无 chip 变体不需要传：渠道控件在宿主页面顶部。
  final List<SourceDescriptor> channels;

  final String selectedKey;
  final ValueChanged<String>? onChannelSelected;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEscape;
  final bool autofocus;
  final bool enabled;

  /// 是否在胶囊左侧渲染渠道 chip（≥2 个启用渠道时才真正出现）。
  ///
  /// 资料库搜索 tab 传 false：渠道下拉常驻页面顶部，条内不再重复。
  final bool showChannelChip;

  /// 渠道下拉的焦点节点（宿主可在选择后主动失焦，避免关闭时抢回焦点）。
  final FocusNode? channelFocusNode;

  @override
  Widget build(BuildContext context) {
    // 无 chip 变体：仍是同一条胶囊，只是左侧不占渠道选择区。
    if (!showChannelChip) return _buildCapsule(context, showChip: false);

    // 单渠道：没有可切换目标，保留标准搜索栏（左侧搜索图标）。
    if (channels.length < 2) {
      return AppSearchBar(
        controller: controller,
        focusNode: focusNode,
        hintText: hintText,
        autofocus: autofocus,
        enabled: enabled,
        margin: 0,
        expandOnFocus: false,
        constraints: BoxConstraints(
          minWidth: 0,
          maxWidth: double.infinity,
          minHeight: M3ETheme.of(context).searchBarTheme.minHeight,
        ),
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onEscape: onEscape,
      );
    }

    return _buildCapsule(context, showChip: true);
  }

  /// 单层搜索胶囊：可选左侧渠道 chip + 裸输入 + 清除键。
  ///
  /// chip 与无 chip 两个变体共用同一份高度 / 焦点环 / 清除键实现，避免
  /// 「资料库里的搜索框」和「Ctrl+F 的搜索框」各长一套。
  Widget _buildCapsule(BuildContext context, {required bool showChip}) {
    final m3e = M3ETheme.of(context);
    final barTheme = m3e.searchBarTheme;
    final chipScheme = m3e.colorScheme;
    final cursorColor = barTheme.cursorColor(chipScheme);
    final selectionColor = barTheme.selectionColor(chipScheme);
    final layout = appSearchBarLayoutFor(context, null);
    final selectorWidth = math.min(
      148.0,
      math.max(120.0, discoverChannelSelectorWidth(context)),
    );
    final l10n = _l10n(context);

    return ListenableBuilder(
      listenable: Listenable.merge([controller, focusNode]),
      builder: (context, _) {
        final hasText = controller.text.isNotEmpty;
        return M3EFocusRing(
          focused: M3EFocusRing.shouldShow(focusNode, context),
          radius: BorderRadius.circular(999),
          child: M3ECard(
            variant: M3ECardVariant.filled,
            color: barTheme.backgroundColor(m3e.colorScheme),
            elevation: 0,
            borderRadius: BorderRadius.circular(999),
            padding: EdgeInsets.zero,
            focusable: false,
            showFocusRing: false,
            showFocusFill: false,
            child: SizedBox(
              height: layout.constraints.minHeight,
              child: Row(
                children: [
                  if (showChip)
                    SizedBox(
                      width: selectorWidth,
                      child: Padding(
                        // 左/上/下 6、右 4：chip 不贴搜索条边缘；右侧与输入区
                        // 再隔 4（输入区自身左 padding 4）= 约 8dp 间距。
                        padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
                        // 下拉内部是 mainAxisSize.min 的 Column，给死高度也不会
                        // 撑满；改用 Align 在剩余高度里居中，chip 高度随字体缩放
                        // 自然增长，1.5× 时仍保持上下对称内缩。
                        child: Align(
                          alignment: Alignment.center,
                          child: Semantics(
                            container: true,
                            label: l10n.searchSourcesLabel,
                            child: M3EDropdownMenu<String>(
                              key: channelDropdownKey,
                              focusNode: channelFocusNode,
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
                              itemBuilder: channelDropdownItemBuilder(context),
                              fieldStyle: M3EDropdownFieldStyle(
                                // 透明背景：露出外层搜索胶囊底色，只用描边区分
                                // chip；聚焦 / 展开时描边略强。
                                backgroundColor: Colors.transparent,
                                foregroundColor: chipScheme.onSurface,
                                border: BorderSide(
                                  color: chipScheme.outlineVariant,
                                ),
                                focusedBorder: BorderSide(
                                  color: chipScheme.outline,
                                ),
                                borderRadius: BorderRadius.circular(999),
                                margin: EdgeInsets.zero,
                                // 10 + 10：1× 下 chip 自然高度约 44，正好填满
                                // 56dp 搜索条减掉上下 6dp 的剩余高度。
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                hintText: l10n.searchSourcesLabel,
                                hintStyle: m3e.typeScale.bodyMedium.copyWith(
                                  color: chipScheme.onSurface,
                                ),
                                selectedTextStyle: m3e.typeScale.bodyMedium
                                    .copyWith(color: chipScheme.onSurface),
                              ),
                              dropdownStyle: M3EDropdownPanelStyle(
                                noItemsFoundText: l10n.noItemsFound,
                              ),
                              onSelectionChanged: (items) {
                                if (items.isEmpty) return;
                                onChannelSelected?.call(items.first.value);
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!showChip)
                    SizedBox(
                      width: 48,
                      child: Icon(
                        Icons.search_rounded,
                        color: chipScheme.onSurface,
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      // 有 chip 时与 chip 隔 4；无 chip 时左侧是搜索图标，
                      // 图标槽自身已留出内缩，这里只补 4dp 文字间距。
                      padding: const EdgeInsets.only(left: 4, right: 4),
                      child: _ChannelSearchField(
                        controller: controller,
                        focusNode: focusNode,
                        hintText: hintText,
                        autofocus: autofocus,
                        enabled: enabled,
                        inputStyle: layout.inputStyle,
                        hintStyle: layout.hintStyle,
                        cursorColor: cursorColor,
                        selectionColor: selectionColor,
                        onChanged: onChanged,
                        onSubmitted: onSubmitted,
                        onEscape: onEscape,
                      ),
                    ),
                  ),
                  if (enabled && hasText)
                    SizedBox(
                      width: 48,
                      child: M3EIconButton(
                        variant: M3EIconButtonVariant.standard,
                        icon: const Icon(Icons.close_rounded),
                        semanticLabel: l10n.clearSearch,
                        onPressed: () {
                          controller.clear();
                          onChanged?.call('');
                          focusNode.requestFocus();
                        },
                      ),
                    )
                  else
                    const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 组合条内部的裸输入：复用 M3E 搜索栏自己的输入组件。
///
/// 为什么不再用裸 [TextField]：`InputDecoration.collapsed` 会把 hint 交给
/// `InputDecorator` 的默认排版（默认字号 / 行高与传入的 `hintStyle` 不一致），
/// 胶囊高度固定后 hint 会偏离垂直中心；[M3ESearchBarInput] 用 Stack +
/// `Align(centerStart)` 直接排 hint / EditableText，和 Ctrl+F、歌单搜索条
/// 保持同一套垂直居中口径。
class _ChannelSearchField extends StatelessWidget {
  const _ChannelSearchField({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.inputStyle,
    required this.hintStyle,
    required this.cursorColor,
    required this.selectionColor,
    required this.autofocus,
    required this.enabled,
    this.onChanged,
    this.onSubmitted,
    this.onEscape,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final TextStyle inputStyle;
  final TextStyle hintStyle;
  final Color cursorColor;
  final Color selectionColor;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEscape;

  @override
  Widget build(BuildContext context) {
    return M3ESearchBarInput(
      controller: controller,
      focusNode: focusNode,
      hintText: hintText,
      enabled: enabled,
      readOnly: false,
      autoFocus: autofocus,
      textStyle: inputStyle,
      hintStyle: hintStyle,
      cursorColor: cursorColor,
      selectionColor: selectionColor,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onEscape: onEscape,
    );
  }
}
