import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';

/// AppLocalizations 查找：测试等场景可能未注册 delegate，回退简体中文。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 全 App 统一的搜索输入（M3E contained 胶囊搜索栏）。
///
/// 不直接在各页面用 [M3ESearchBar] 的原因：
/// - 内置清除键 tooltip 是硬编码英文（`M3ESearchConstants.clearButtonTooltip`），
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
    if (widget.controller.text.isEmpty) return;
    widget.controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    return M3ESearchBar(
      controller: widget.controller,
      focusNode: widget.focusNode,
      hintText: widget.hintText,
      leading: widget.leading ?? const Icon(Icons.search_rounded),
      // 清除键自绘：内置的 tooltip 是英文硬编码且清除时不回调 onChanged。
      showClearButton: false,
      autoFocus: widget.autofocus,
      enabled: widget.enabled,
      margin: widget.margin,
      focusedMargin: widget.focusedMargin,
      expandOnFocus: widget.expandOnFocus,
      constraints: widget.constraints,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      trailing: <Widget>[
        if (widget.controller.text.isNotEmpty)
          M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.close_rounded),
            tooltip: _l10n(context).clearSearch,
            onPressed: _clear,
          ),
        ...widget.trailing,
      ],
    );
  }
}
