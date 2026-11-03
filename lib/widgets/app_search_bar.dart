import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import 'row_extent.dart';

/// AppLocalizations 查找：测试等场景可能未注册 delegate，回退简体中文。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 全 App 统一的搜索输入（M3E contained 胶囊搜索栏）。
///
/// 不直接在各页面用 [M3ESearchBar] 的原因：
/// - 内置清除键会弹硬编码英文提示（`M3ESearchConstants.clearButtonTooltip`），
///   不符合「UI 文案必须走 AppLocalizations」；
/// - 内置清除键只 `controller.clear()`、不触发 onChanged，靠 onChanged 刷新
///   过滤结果的页面点 X 后列表不会刷新；
/// - leading 图标、图标风格（圆角）、回车行为需要在全 App 保持一致。
///
/// 约定：[onChanged] 在「用户输入」与「点击清除键」时都会触发（清除传空串），
/// 页面据此刷新过滤结果即可；清除后焦点保留在输入框。
class AppSearchBar extends StatefulWidget {
  const AppSearchBar({
    super.key,
    required this.controller,
    required this.hintText,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.onEscape,
    this.trailing = const <Widget>[],
    this.leading,
    this.autofocus = false,
    this.enabled = true,
    this.margin = 0,
    this.focusedMargin,
    this.expandOnFocus = false,
    this.constraints,
    this.textInputAction = TextInputAction.search,
  });

  /// 文本控制器（由调用方持有并负责 dispose）。
  final TextEditingController controller;

  /// 提示文案（必填，走 l10n）。
  final String hintText;

  /// 输入框焦点节点（可选，由调用方持有并负责 dispose）。
  final FocusNode? focusNode;

  /// 文本变化回调；点击清除键时以空串回调（见类注释）。
  final ValueChanged<String>? onChanged;

  /// 键盘提交（回车 / 搜索键）回调。
  final ValueChanged<String>? onSubmitted;

  /// Esc 回调：设置后 Esc 交给调用方（如关闭遮罩），不再退化为「输入框失焦」。
  final VoidCallback? onEscape;

  /// 清除键右侧的额外尾部动作（如歌词搜索的加载指示），最多两个。
  final List<Widget> trailing;

  /// 覆盖默认的 leading 搜索图标（如收藏页单胶囊布局放返回键）。
  final Widget? leading;

  /// 构建后是否自动聚焦。
  final bool autofocus;

  final bool enabled;

  /// 空闲时的横向边距；配合 [expandOnFocus] 可在聚焦时收缩到 [focusedMargin]。
  final double margin;

  /// 聚焦时的横向边距（默认取组件主题值 12）。
  final double? focusedMargin;

  /// 是否启用「聚焦时向两侧弹性展开」。
  final bool expandOnFocus;

  /// 覆盖搜索栏尺寸约束（默认 minWidth 360 / maxWidth 720 / minHeight 56）。
  ///
  /// minHeight 会按系统文字缩放后的真实字体行高继续抬高；本参数只覆盖
  /// 宽度与 1.0× 基线高度。
  final BoxConstraints? constraints;

  final TextInputAction textInputAction;

  @override
  State<AppSearchBar> createState() => _AppSearchBarState();
}

class _AppSearchBarState extends State<AppSearchBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleTextChanged);
  }

  @override
  void didUpdateWidget(covariant AppSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTextChanged);
      widget.controller.addListener(_handleTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChanged);
    super.dispose();
  }

  /// 清除键显隐跟随文本；尾部动作由本组件拼接，需要自己刷新。
  void _handleTextChanged() => setState(() {});

  void _clear() {
    if (!widget.enabled || widget.controller.text.isEmpty) return;
    widget.controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final layout = appSearchBarLayoutFor(context, widget.constraints);

    return M3ESearchBar(
      controller: widget.controller,
      focusNode: widget.focusNode,
      hintText: widget.hintText,
      leading: widget.leading ?? const Icon(Icons.search_rounded),
      // 清除键自绘：内置键会弹英文硬编码提示，且清除时不回调 onChanged。
      showClearButton: false,
      autoFocus: widget.autofocus,
      enabled: widget.enabled,
      margin: widget.margin,
      focusedMargin: widget.focusedMargin,
      expandOnFocus: widget.expandOnFocus,
      constraints: layout.constraints,
      // 输入框（EditableText）的高度决定 M3ESearchBarInput 的 Stack 高度；
      // 只调 hintStyle 仍会被 stack 夹在 16px 行框里，因此 textStyle 也同步
      // 使用自然行高，hint 才有足够的高度绘制。
      textStyle: WidgetStatePropertyAll<TextStyle?>(layout.inputStyle),
      hintStyle: WidgetStatePropertyAll<TextStyle?>(layout.hintStyle),
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      onEscape: widget.onEscape,
      trailing: <Widget>[
        // 禁用输入框时清除键也必须消失：否则点了 X 仍会改文本并触发
        // onChanged，绕过调用方的忙碌锁。
        if (widget.enabled && widget.controller.text.isNotEmpty)
          M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.close_rounded),
            semanticLabel: _l10n(context).clearSearch,
            onPressed: _clear,
          ),
        ...widget.trailing,
      ],
    );
  }
}

/// AppSearchBar 在 1.0× 下的设计与放大字体后的实际最小高度。
///
/// 全局搜索的隐形占位盒 / 桌面壳定位也用它：占位高度必须与真实搜索条同源，
/// 否则 1.3× 下结果面板会按 56dp 旧锚点错位。
double appSearchBarMinHeightOf(
  BuildContext context, {
  BoxConstraints? constraints,
}) => appSearchBarLayoutFor(context, constraints).constraints.minHeight;

/// 搜索栏内部布局：约束与文字样式必须一起算（只调其中一个仍会被内层行框裁）。
///
/// 组合搜索条（`ChannelSearchBar`）复用同一份自适应高度与文字样式，
/// 避免自定义 TextField 在 1.3× / 1.5× 下被裁切。
({BoxConstraints constraints, TextStyle hintStyle, TextStyle inputStyle})
appSearchBarLayoutFor(BuildContext context, BoxConstraints? override) {
  // M3ESearchBar 的 56dp minHeight 按 1.0× 字阶设计；真实 CJK 字体放大后
  // hint 的 ascent 会顶出 pill 上缘（1.3× 实测 2–4px 被裁）。这里用真实
  // 字体行高测量把额外行高同时补到约束、输入框与 hintStyle：
  // - 1.0× 时 scaledLine == baseLine，高度仍是 56、文字样式不变；
  // - 放大时 pill 跟着行高增长，输入 / hint 行框也足够容纳字形，不再只靠
  //   某个页面单独加 Padding。
  final theme = M3ETheme.of(context);
  final barTheme = theme.searchBarTheme;
  final hintStyle = barTheme.hintStyle(theme.typeScale, theme.colorScheme);
  final inputStyle = barTheme.textStyle(theme.typeScale, theme.colorScheme);
  final scaler = MediaQuery.textScalerOf(context);
  // M3E 的 typeScale 样式只带字重 / 字距等增量，fontSize 常为空、由
  // DefaultTextStyle 继承；测量与自适应高度都必须先补上实际字号。
  final baseFontSize =
      hintStyle.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
  // 用「去掉固定 height」的自然字体行高测量：M3E 的 bodyLarge 固定行高
  // 1.5 在 CJK 字体下小于 ascent+descent，TextPainter 会把它当成精确行框，
  // 字形顶部被 ellipsis 裁掉；自然行高才是需要容纳的最小值。
  final naturalHintStyle = hintStyle.copyWith(
    fontSize: baseFontSize,
    height: null,
  );
  final baseLine = lineHeightFor(naturalHintStyle, TextScaler.noScaling);
  final scaledLine = lineHeightFor(naturalHintStyle, scaler);
  final extra = math.max(0.0, scaledLine - baseLine);
  final baseConstraints = barTheme.constraints(override: override);
  final constraints = baseConstraints.copyWith(
    minHeight: baseConstraints.minHeight + extra,
  );
  final adaptiveHeight = extra <= 0
      ? null
      : math.max(
          hintStyle.height ?? 1,
          scaledLine / math.max(1, scaler.scale(baseFontSize)),
        );
  return (
    constraints: constraints,
    hintStyle: adaptiveHeight == null
        ? hintStyle
        : hintStyle.copyWith(fontSize: baseFontSize, height: adaptiveHeight),
    inputStyle: adaptiveHeight == null
        ? inputStyle
        : inputStyle.copyWith(fontSize: baseFontSize, height: adaptiveHeight),
  );
}
