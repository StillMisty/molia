import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/settings/device_settings.dart';
import '../data/settings/device_settings_keys.dart';
import '../data/settings/settings_access.dart';
import '../data/settings/settings_key.dart';
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
  /// [deviceSettings] 仅测试注入；生产构造自己的设备本地入口，保存上次
  /// 停留的一级页（不跟人走，见 `kShellLastDestinationKey`）。
  NavProvider({required this._settings, DeviceSettings? deviceSettings})
    : _deviceSettings = deviceSettings ?? DeviceSettings() {
    _preferencesReady = _loadPreferences();
  }

  final SettingsAccess _settings;
  final DeviceSettings _deviceSettings;

  /// 默认顺序来自登记键默认值（资料 / 播放 / 收藏），避免两处各写一份。
  static List<ShellDestination> get defaultOrder =>
      List<ShellDestination>.unmodifiable(
        _orderOf(kShellNavOrder.defaultValue),
      );

  /// 本 provider 读写的登记设置键：组合根按这份表挂载 `SettingsScope`。
  ///
  /// 必须覆盖 [_loadPreferences] 与各 setter 用到的全部登记键：作用域外的
  /// 键在读写时会抛 [StateError]，而加载路径的 catch 会吞掉它，导致后面的
  /// 偏好一起停在默认值（曾漏过「恢复上次页面」）。
  static const List<SettingsKey<Object?>> settingsKeys = [
    kShellNavLayout,
    // 旧版三键只读兜底：升级后首次启动仍能恢复导航定制，下次编辑写新键。
    kShellNavOrder,
    kShellNavHidden,
    kShellHomeDestination,
    // 进入播放页的歌词偏好与导航布局同属壳层导航偏好，共用一次重载。
    kShellNowPlayingLyricsOnEnter,
    kShellRestoreLastDestination,
  ];

  List<ShellDestination> _order = List<ShellDestination>.of(defaultOrder);
  final Set<ShellDestination> _hidden = _hiddenOf(kShellNavHidden.defaultValue);

  /// 存储的启动首页；同步推来的 hidden 列表可能让它当前不可见（见
  /// [effectiveHomeDestination]）。
  ShellDestination _homeDestination = _homeOf(
    kShellHomeDestination.defaultValue,
  );

  /// 从其它一级页进入播放页时是否固定先显示歌词。
  bool _showLyricsOnEnter = kShellNowPlayingLyricsOnEnter.defaultValue;

  /// 启动时是否恢复到上次停留的一级页。
  bool _restoreLastDestination = kShellRestoreLastDestination.defaultValue;

  /// 上次停留的一级页；null = 没有记录。
  ShellDestination? _lastDestination;

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

  /// 启动落点：「恢复上次页面」开启且记录仍可见时回到上次停留的一级页，
  /// 否则按 [effectiveHomeDestination]。
  ///
  /// 记录可能指向同步后已隐藏的目的地：此时不强行切到不可见页，回退启动页。
  ShellDestination get startupDestination {
    final last = _lastDestination;
    if (_restoreLastDestination && last != null && isVisible(last)) {
      return last;
    }
    return effectiveHomeDestination;
  }

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

  /// 启动时是否恢复到上次停留的一级页。
  bool get restoreLastDestination => _restoreLastDestination;

  /// 设置「恢复上次页面」：立即生效并持久化。
  ///
  /// 关闭时清掉记录，避免很久以后重新打开时恢复到一个早已无关的页面。
  Future<void> setRestoreLastDestination(bool value) async {
    if (_restoreLastDestination == value) return;
    _restoreLastDestination = value;
    if (!value) _lastDestination = null;
    notifyListeners();
    if (!value) {
      await _deviceSettings.remove(kShellLastDestinationKey);
    }
    try {
      await _settings.write(kShellRestoreLastDestination, value);
    } catch (e) {
      logger.severe('保存「恢复上次页面」偏好失败: $e');
    }
  }

  /// 记录用户切到的顶级页，供下次启动恢复。
  ///
  /// 开关关闭时不写：记录只在「恢复」启用期间有意义（见
  /// [setRestoreLastDestination] 的清理）。
  Future<void> recordLastDestination(ShellDestination destination) async {
    if (!_restoreLastDestination || _lastDestination == destination) return;
    _lastDestination = destination;
    await _deviceSettings.write(kShellLastDestinationKey, destination.name);
  }

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
      // 否则远端应用 / 重启后这些偏好永远停留在默认值。
      _showLyricsOnEnter = await _settings.read(kShellNowPlayingLyricsOnEnter);
      _restoreLastDestination = await _settings.read(
        kShellRestoreLastDestination,
      );
      _lastDestination = _destinationOf(
        await _deviceSettings.read(kShellLastDestinationKey),
      );
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

  /// 解析存储的一级页名字；空串 / 未知值返回 null（当作没有记录）。
  static ShellDestination? _destinationOf(String name) {
    for (final destination in ShellDestination.values) {
      if (destination.name == name) return destination;
    }
    return null;
  }

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
