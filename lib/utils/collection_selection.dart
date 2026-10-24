import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 合集多选状态机（收藏 / 播放历史 / 本地歌曲共用）。
///
/// 选择集按**行稳定 key**（`CollectionRow.key`）表示，而不是可见行下标：
/// 播放历史会在浏览期间因后台写入在列表前部插入新行，按下标保存的选择会
/// 平移到别的曲目上。行 key 与行内容同源，插入 / 过滤 / 刷新后仍指向原来
/// 那一行；可见行集合变化时由宿主调用 [retainKeys] 丢弃已不存在的行。
///
/// 区间与锚点语义与文件管理器的经典多选一致：
/// - Ctrl 点击切换该行并移动锚点；
/// - Shift 点击选中锚点到当前行的闭区间，连续 Shift 只调整区间端点
///   （锚点只在不带 Shift 的点击时移动）；锚点为空 / 已不在可见行时退化为
///   单选该行；
/// - 搜索 / 排序 / 换合集等重排可见顺序的操作让锚点失效（[clearAnchor]）。
///
/// 宿主只负责「何时调用」与点播分支；选择语义都在这里。
class CollectionSelection extends ChangeNotifier {
  final Set<String> _selected = <String>{};
  String? _anchor;

  /// 当前选中的行 key（只读视图）。
  Set<String> get selectedKeys => Set<String>.unmodifiable(_selected);

  /// 是否处于选择模式（有任一选中行）。
  bool get isSelecting => _selected.isNotEmpty;

  /// 选中行数。
  int get selectedCount => _selected.length;

  bool isSelected(String key) => _selected.contains(key);

  /// 全选三态：可见行全选 true / 可见行都没选 false / 部分选中 null。
  ///
  /// 只统计 [visibleKeys] 内的选择：选择集里残留的不可见行不参与表头
  /// 三态（[retainKeys] 正常会在视图落定时清掉它们，这里再做一层防御）。
  bool? allSelectedFor(Iterable<String> visibleKeys) {
    final keys = visibleKeys.toSet();
    if (keys.isEmpty || _selected.isEmpty) return false;
    final selectedVisible = _selected.where(keys.contains).length;
    if (selectedVisible >= keys.length) return true;
    return selectedVisible == 0 ? false : null;
  }

  /// 选中 [key]（已选中则无操作）。
  void select(String key) {
    if (_selected.add(key)) notifyListeners();
  }

  /// 切换 [key] 的选中态。
  void toggle(String key) {
    if (!_selected.remove(key)) _selected.add(key);
    notifyListeners();
  }

  /// 全选 [visibleKeys]。
  void selectAll(Iterable<String> visibleKeys) {
    var changed = false;
    for (final key in visibleKeys) {
      changed = _selected.add(key) || changed;
    }
    if (changed) notifyListeners();
  }

  /// 桌面修饰键手势：返回 true = 已被修饰键语义接管（调用方不再处理点击）。
  ///
  /// 普通点击也会移动锚点（返回 false，交给调用方走原语义），下一次 Shift
  /// 从这里起算区间。
  bool applyModifiers(
    String key, {
    required List<String> visibleKeys,
    required bool ctrl,
    required bool shift,
  }) {
    final index = visibleKeys.indexOf(key);
    // 不在可见行里的点击没有可解释的区间语义：不接管也不改锚点。
    if (index < 0) return false;
    if (shift) {
      var anchorIndex = _anchor == null ? -1 : visibleKeys.indexOf(_anchor!);
      if (anchorIndex < 0) {
        anchorIndex = index;
        _anchor = key;
      }
      final start = math.min(anchorIndex, index);
      final end = math.max(anchorIndex, index);
      _selected.clear();
      for (var i = start; i <= end; i++) {
        _selected.add(visibleKeys[i]);
      }
      notifyListeners();
      return true;
    }
    _anchor = key;
    if (ctrl) {
      toggle(key);
      return true;
    }
    return false;
  }

  /// 按可见顺序提取选中行；不可见的选中 key 忽略。
  List<T> selectedFrom<T>(
    List<T> rows, {
    required String Function(T row) keyOf,
  }) =>
      [
        for (final row in rows)
          if (_selected.contains(keyOf(row))) row,
      ];

  /// 视图落定时同步可见行集合：丢弃已不存在行的选择，锚点失效。
  ///
  /// 静默执行（不通知）：只在宿主的 build 期同步视图时调用，宿主本帧已按
  /// 新值构建；这里通知会在 build 中触发监听者的 setState。
  void retainKeys(Iterable<String> visibleKeys) {
    final keys = visibleKeys.toSet();
    final kept = {
      for (final key in _selected)
        if (keys.contains(key)) key,
    };
    final anchor = _anchor;
    final anchorGone = anchor != null && !keys.contains(anchor);
    if (kept.length == _selected.length && !anchorGone) return;
    _selected
      ..clear()
      ..addAll(kept);
    if (anchorGone) _anchor = null;
  }

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
