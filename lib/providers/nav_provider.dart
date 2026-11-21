import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../domain/models/shell_destination.dart';

export '../domain/models/shell_destination.dart' show ShellDestination;

final logger = Logger('molia.nav_provider');

typedef _NavLayout = ({
  List<ShellDestination> order,
  Set<ShellDestination> hidden,
  ShellDestination home,
});

/// 底部导航定制：顺序 + 显示/隐藏 + 启动首页 + 进入播放页的歌词偏好，
/// SharedPreferences 持久化。
class NavProvider extends ChangeNotifier {
  NavProvider({required this._settings}) {
    _preferencesReady = _loadPreferences();
  }

  final SettingsAccess _settings;

  /// 默认顺序来自登记键默认值（资料 / 播放 / 收藏），避免两处各写一份。
  static List<ShellDestination> get defaultOrder =>
      List<ShellDestination>.unmodifiable(
        _orderOf(kShellNavOrder.defaultValue),
      );

  List<ShellDestination> _order = List<ShellDestination>.of(defaultOrder);
  final Set<ShellDestination> _hidden = _hiddenOf(kShellNavHidden.defaultValue);

  /// 存储的启动首页；同步推来的 hidden 列表可能让它当前不可见（见
  /// [effectiveHomeDestination]）。
  ShellDestination _homeDestination = _homeOf(
    kShellHomeDestination.defaultValue,
  );

  /// 从其它一级页进入播放页时是否固定先显示歌词。
  bool _showLyricsOnEnter = kShellNowPlayingLyricsOnEnter.defaultValue;

  late final Future<void> _preferencesReady;

  /// 持久化偏好加载完成（测试等待启动态就绪）。
  Future<void> get preferencesReady => _preferencesReady;

  /// 重新读取导航偏好（跨设备同步应用远端设置后由组合根调用）。
  Future<void> reloadFromPreferences() => _loadPreferences();

  /// 全部目的地的当前顺序（含隐藏项，设置页按此顺序展示）。
  List<ShellDestination> get order =>
      List<ShellDestination>.unmodifiable(_order);

  /// 实际渲染到壳层的目的地（按顺序过滤隐藏项）。
  List<ShellDestination> get visibleDestinations =>
      _order.where(isVisible).toList(growable: false);

  bool isVisible(ShellDestination destination) =>
      !_hidden.contains(destination);

  /// 存储的启动首页（可能因同步隐藏而当前不可见）。
  ShellDestination get homeDestination => _homeDestination;

  /// 有效启动首页：存储值可见则用它；不可见时按 [order] 取第一个可见项。
  /// 纯内存兜底，不写存储（同步应用期间写回会造成回环）。
  ShellDestination get effectiveHomeDestination => isVisible(_homeDestination)
      ? _homeDestination
      : _order.firstWhere(isVisible, orElse: () => _order.first);

  /// 设置启动首页：立即生效并持久化。
  Future<void> setHomeDestination(ShellDestination destination) async {
    // 重复选中同一项不触发写入：避免制造一次内容无变化的同步变更。
    if (_homeDestination == destination) return;
    _homeDestination = destination;
    notifyListeners();
    await _persist();
  }

  /// 从其它一级页进入播放页时是否固定先显示歌词。
  bool get showLyricsOnEnter => _showLyricsOnEnter;

  /// 设置「进入播放页时显示歌词」：立即生效并持久化。
  Future<void> setShowLyricsOnEnter(bool value) async {
    if (_showLyricsOnEnter == value) return;
    _showLyricsOnEnter = value;
    notifyListeners();
    try {
      await _settings.write(kShellNowPlayingLyricsOnEnter, value);
    } catch (e) {
      // 写失败保留内存值：本次运行仍按用户刚选的来，下次启动回退到存储值。
      logger.severe('保存「进入播放页显示歌词」偏好失败: $e');
    }
  }

  /// 切换显示/隐藏；隐藏启动首页或最后一项时拒绝并返回 false。
  Future<bool> setVisible(ShellDestination destination, bool visible) async {
    if (visible) {
      if (_hidden.remove(destination)) notifyListeners();
    } else {
      // 启动首页锁定：想关先改首页。已隐藏的不一致态走上面的显示分支解除，
      // 因此这里不会把「已被同步隐藏的首页」也堵死（给出路，避免死锁）。
      if (destination == _homeDestination) return false;
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
      // 与导航布局互相独立：新 JSON 分支会 early return，必须在这里先读，
      // 否则远端应用 / 重启后该偏好永远停留在默认值。
      _showLyricsOnEnter = await _settings.read(kShellNowPlayingLyricsOnEnter);
      final layout = _decodeLayout(await _settings.read(kShellNavLayout));
      if (layout != null) {
        _order = layout.order;
        _hidden
          ..clear()
          ..addAll(layout.hidden);
        // 至少保留 1 个可见目的地。
        if (visibleDestinations.isEmpty) {
          _hidden.remove(_order.first);
        }
        _homeDestination = layout.home;
        notifyListeners();
        return;
      }

      // 旧版三键兜底：只读，不改写存储（下次编辑会写成新 JSON 键）。
      final names = await _settings.read(kShellNavOrder);
      if (names.isNotEmpty) {
        _order = _orderOf(names);
      }
      final hiddenNames = await _settings.read(kShellNavHidden);
      if (hiddenNames.isNotEmpty) {
        _hidden
          ..clear()
          ..addAll(_hiddenOf(hiddenNames));
        // 至少保留 1 个可见目的地。
        if (visibleDestinations.isEmpty) {
          _hidden.remove(_order.first);
        }
      }
      // 非法值回退默认播放页（与键默认值一致）。
      final homeName = await _settings.read(kShellHomeDestination);
      _homeDestination = _homeOf(homeName);
      notifyListeners();
    } catch (e) {
      logger.severe('加载底部导航偏好失败: $e');
    }
  }

  /// 解析新 JSON 键；损坏 / 缺字段返回 null，交给旧键 / 默认值兜底。
  static _NavLayout? _decodeLayout(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final order = decoded['order'];
      final hidden = decoded['hidden'];
      final home = decoded['home'];
      if (order is! List || hidden is! List || home is! String) return null;
      final orderNames = order.whereType<String>().toList(growable: false);
      if (orderNames.isEmpty) return null;
      return (
        order: _orderOf(orderNames),
        hidden: _hiddenOf(hidden.whereType<String>().toList(growable: false)),
        home: _homeOf(home),
      );
    } on FormatException {
      return null;
    }
  }

  /// 键默认值 → 枚举列表（补齐损坏数据缺失的目的地）。
  static List<ShellDestination> _orderOf(List<String> names) {
    final restored = <ShellDestination>[];
    for (final name in names) {
      for (final destination in ShellDestination.values) {
        if (destination.name == name && !restored.contains(destination)) {
          restored.add(destination);
        }
      }
    }
    for (final destination in ShellDestination.values) {
      if (!restored.contains(destination)) restored.add(destination);
    }
    return restored;
  }

  static Set<ShellDestination> _hiddenOf(List<String> names) => ShellDestination
      .values
      .where((value) => names.contains(value.name))
      .toSet();

  static ShellDestination _homeOf(String name) =>
      ShellDestination.values.firstWhere(
        (destination) => destination.name == name,
        orElse: () => ShellDestination.values.firstWhere(
          (destination) =>
              destination.name == kShellHomeDestination.defaultValue,
        ),
      );

  Future<void> _persist() async {
    try {
      // 一次 setString 写完整布局：桌面偏好每次写入都会重写整个文件。
      await _settings.write(
        kShellNavLayout,
        jsonEncode({
          'order': _order.map((destination) => destination.name).toList(),
          'hidden': _hidden.map((destination) => destination.name).toList(),
          'home': _homeDestination.name,
        }),
      );
    } catch (e) {
      logger.severe('保存底部导航偏好失败: $e');
    }
  }
}
