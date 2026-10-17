import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 收藏页合集的桌面多选状态机：收藏 / 播放历史 / 本地歌曲共用一份。
///
/// 选择集按**当前可见行下标**表示；区间与锚点语义与文件管理器的经典多选
/// 一致：
/// - Ctrl 点击切换该行并移动锚点；
/// - Shift 点击选中锚点到当前行的闭区间，连续 Shift 只调整区间端点
///   （锚点只在不带 Shift 的点击时移动）；锚点为空 / 越界时退化为单选该行；
/// - 搜索 / 排序 / 换合集等重排可见顺序的操作让锚点失效（[clearAnchor]）；
/// - 越界下标在提取时忽略（选中后列表被过滤 / 刷新）。
///
/// 宿主只负责「何时调用」与点播分支；选择语义都在这里。
class CollectionSelection extends ChangeNotifier {
  final Set<int> _selected = <int>{};
  int? _anchor;

  /// 当前选中的行下标（只读视图）。
  Set<int> get selectedIndices => Set<int>.unmodifiable(_selected);

  /// 是否处于选择模式（有任一选中行）。
  bool get isSelecting => _selected.isNotEmpty;

  /// 选中行数。
  int get selectedCount => _selected.length;

  bool isSelected(int index) => _selected.contains(index);

  /// 全选三态：全选 true / 未选 false / 部分选中 null。
  bool? allSelectedFor(int itemCount) {
    if (itemCount <= 0 || _selected.isEmpty) return false;
    if (_selected.length >= itemCount) return true;
    return null;
  }

  /// 选中 [index]（已选中则无操作）。
  void select(int index) {
    if (_selected.add(index)) notifyListeners();
  }

  /// 切换 [index] 的选中态。
  void toggle(int index) {
    if (!_selected.remove(index)) _selected.add(index);
    notifyListeners();
  }

  /// 全选 `0..itemCount-1`。
  void selectAll(int itemCount) {
    if (itemCount <= 0) return;
    var changed = false;
    for (var i = 0; i < itemCount; i++) {
      changed = _selected.add(i) || changed;
    }
    if (changed) notifyListeners();
  }

  /// 桌面修饰键手势：返回 true = 已被修饰键语义接管（调用方不再处理点击）。
  ///
  /// 普通点击也会移动锚点（返回 false，交给调用方走原语义），下一次 Shift
  /// 从这里起算区间。
  bool applyModifiers(
    int index, {
    required int itemCount,
    required bool ctrl,
    required bool shift,
  }) {
    if (shift) {
      var anchor = _anchor;
      if (anchor == null || anchor >= itemCount) {
        anchor = index;
        _anchor = index;
      }
      final start = math.min(anchor, index);
      final end = math.max(anchor, index);
      _selected.clear();
      for (var i = start; i <= end; i++) {
        _selected.add(i);
      }
      notifyListeners();
      return true;
    }
    _anchor = index;
    if (ctrl) {
      toggle(index);
      return true;
    }
    return false;
  }

  /// 按可见行下标提取选中行；越界下标忽略。
  List<T> selectedFrom<T>(List<T> rows) => [
        for (final index in _selected)
          if (index >= 0 && index < rows.length) rows[index],
      ];

  /// 清空选择并让锚点失效。
  void clear() {
    if (_selected.isEmpty && _anchor == null) return;
    _selected.clear();
    _anchor = null;
    notifyListeners();
  }

  /// 只让锚点失效（可见顺序变化但选择保留）。
  void clearAnchor() => _anchor = null;
}
