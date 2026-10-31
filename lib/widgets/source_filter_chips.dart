/// 通用来源筛选 chips：换源页与搜索结果面共用同一份焦点 / 滚动行为。
///
/// 固定单行横向滚动；每个 chip 持有独立 [FocusNode]，键盘焦点落到可视区
/// 外的 chip 时自动 `ensureVisible`。选项顺序完全由调用方给（搜索必须跟
/// 音源管理的渠道顺序），本组件不重排。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/motion_policy.dart';

/// 一个来源筛选选项；[key] 为空串 = 「全部」。
class SourceFilterOption {
  const SourceFilterOption({required this.key, required this.label});

  final String key;
  final String label;
}

class SourceFilterChips extends StatefulWidget {
  const SourceFilterChips({
    super.key,
    required this.options,
    required this.selectedKey,
    required this.onSelected,
    required this.groupLabel,
    required this.allLabel,
    this.chipKeyPrefix = 'sourceFilterChip',
    this.scrollKey,
    this.enabled = true,
  });

  /// 来源选项（不含「全部」；「全部」固定第一）。
  final List<SourceFilterOption> options;

  /// 空串 = 全部。
  final String selectedKey;
  final ValueChanged<String> onSelected;

  /// 读屏分组名（如「搜索来源」）。
  final String groupLabel;

  /// 「全部」chip 的文案。
  final String allLabel;

  /// chip 的稳定 Key 前缀：`<prefix>-all` / `<prefix>-<sourceKey>`。
  final String chipKeyPrefix;

  final Key? scrollKey;

  /// 异步写入 / 取词期间禁用切换；选中态仍按 [selectedKey] 显示。
  final bool enabled;

  @override
  State<SourceFilterChips> createState() => _SourceFilterChipsState();
}

class _SourceFilterChipsState extends State<SourceFilterChips> {
  final Map<String, FocusNode> _nodes = {};

  @override
  void initState() {
    super.initState();
    _syncNodes();
  }

  @override
  void didUpdateWidget(covariant SourceFilterChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncNodes();
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// 选项增删时只保留仍存在的节点，避免焦点停在已移除的 chip 上。
  void _syncNodes() {
    final keys = <String>['', for (final option in widget.options) option.key];
    final wanted = keys.toSet();
    final removed = [
      for (final key in _nodes.keys)
        if (!wanted.contains(key)) key,
    ];
    for (final key in removed) {
      _nodes.remove(key)?.dispose();
    }
    for (final key in keys) {
      _nodes.putIfAbsent(key, () {
        final node = FocusNode(debugLabel: 'sourceFilterChip:$key');
        node.addListener(() {
          if (!node.hasFocus) return;
          _ensureVisible(key);
        });
        return node;
      });
    }
  }

  /// 键盘焦点移到横向滚动区外的 chip：下一帧滚到可视区中间。
  void _ensureVisible(String key) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _nodes[key]?.context;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: effectDurationOf(context, M3EMotion.short3),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        key: widget.scrollKey,
        scrollDirection: Axis.horizontal,
        child: M3EChipGroup(
          groupLabel: widget.groupLabel,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: M3EChip(
                  key: ValueKey<String>('${widget.chipKeyPrefix}-all'),
                  focusNode: _nodes[''],
                  label: widget.allLabel,
                  type: M3EChipType.filter,
                  selected: widget.selectedKey.isEmpty,
                  onPressed: widget.enabled
                      ? () => widget.onSelected('')
                      : null,
                ),
              ),
              for (final option in widget.options)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: M3EChip(
                    key: ValueKey<String>(
                      '${widget.chipKeyPrefix}-${option.key}',
                    ),
                    focusNode: _nodes[option.key],
                    label: option.label,
                    type: M3EChipType.filter,
                    selected: widget.selectedKey == option.key,
                    onPressed: widget.enabled
                        ? () => widget.onSelected(option.key)
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
