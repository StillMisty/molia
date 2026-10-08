import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final logger = Logger();

/// 壳层底部导航的三个目的地。
///
/// 枚举声明顺序 = IndexedStack 的固定子页顺序：调整导航顺序/可见性只影响
/// 底栏渲染与选中映射，不移动 IndexedStack 子节点，页面状态天然保持。
enum ShellDestination { nowPlaying, favorites, library }

/// 底部导航定制：顺序 + 显示/隐藏，SharedPreferences 持久化。
class NavProvider extends ChangeNotifier {
  static const String _orderKey = 'shell_nav_order';
  static const String _hiddenKey = 'shell_nav_hidden';

  /// 默认顺序：资料 / 播放 / 收藏。
  static const List<ShellDestination> defaultOrder = <ShellDestination>[
    ShellDestination.library,
    ShellDestination.nowPlaying,
    ShellDestination.favorites,
  ];

  List<ShellDestination> _order = List<ShellDestination>.of(defaultOrder);
  final Set<ShellDestination> _hidden = <ShellDestination>{};

  late final Future<void> _preferencesReady;

  NavProvider() {
    _preferencesReady = _loadPreferences();
  }

  /// 持久化偏好加载完成（测试等待启动态就绪）。
  Future<void> get preferencesReady => _preferencesReady;

  /// 全部目的地的当前顺序（含隐藏项，设置页按此顺序展示）。
  List<ShellDestination> get order =>
      List<ShellDestination>.unmodifiable(_order);

  /// 实际渲染到壳层的目的地（按顺序过滤隐藏项）。
  List<ShellDestination> get visibleDestinations =>
      _order.where(isVisible).toList(growable: false);

  bool isVisible(ShellDestination destination) =>
      !_hidden.contains(destination);

  /// 切换显示/隐藏；隐藏最后一项时拒绝并返回 false。
  Future<bool> setVisible(ShellDestination destination, bool visible) async {
    if (visible) {
      if (_hidden.remove(destination)) notifyListeners();
    } else {
      if (visibleDestinations.length <= 1) return false;
      if (_hidden.add(destination)) notifyListeners();
    }
    await _persist();
    return true;
  }

  /// 拖拽排序：oldIndex/newIndex 以 [order] 为基准（newIndex 已由
  /// ReorderableListView.onReorderItem 按移除后位置调整）。
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _order.length) return;
    final target = newIndex.clamp(0, _order.length - 1);
    if (target == oldIndex) return;
    final moved = _order.removeAt(oldIndex);
    _order.insert(target, moved);
    notifyListeners();
    await _persist();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final names = prefs.getStringList(_orderKey);
      if (names != null) {
        final restored = <ShellDestination>[];
        for (final name in names) {
          for (final destination in ShellDestination.values) {
            if (destination.name == name && !restored.contains(destination)) {
              restored.add(destination);
            }
          }
        }
        // 补齐旧版本/损坏数据中缺失的目的地。
        for (final destination in ShellDestination.values) {
          if (!restored.contains(destination)) restored.add(destination);
        }
        _order = restored;
      }
      final hiddenNames = prefs.getStringList(_hiddenKey);
      if (hiddenNames != null) {
        _hidden
          ..clear()
          ..addAll(ShellDestination.values.where(
            (value) => hiddenNames.contains(value.name),
          ));
        // 至少保留 1 个可见目的地。
        if (visibleDestinations.isEmpty) {
          _hidden.remove(_order.first);
        }
      }
      notifyListeners();
    } catch (e) {
      logger.e('加载底部导航偏好失败: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _orderKey,
        _order.map((destination) => destination.name).toList(),
      );
      await prefs.setStringList(
        _hiddenKey,
        _hidden.map((destination) => destination.name).toList(),
      );
    } catch (e) {
      logger.e('保存底部导航偏好失败: $e');
    }
  }
}
