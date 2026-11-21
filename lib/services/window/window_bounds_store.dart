/// 窗口几何的设备本地存储（SharedPreferences）。
///
/// 为什么**不登记** `SettingsRegistry`：窗口位置/大小是设备相关项（每台
/// 显示器的分辨率与摆放都不同），同步到别的设备只会把窗口丢到看不见的
/// 地方——与省流 / 托盘行为同一取舍。键名只出现在
/// `device_settings_keys.dart`。
///
/// 桌面端按**虚拟桌面**分组保存：同一台机器上不同虚拟桌面可以有各自的
/// 位置 / 大小 / 最大化状态（`window_bounds_by_desktop` /
/// `window_maximized_by_desktop`）。没有桌面信息（非 Windows / 原生接口
/// 不可用）时回退为旧的全局单键，升级前的数据仍能恢复。
library;

import 'dart:ui';

import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';

/// 上次关闭时的窗口几何。
///
/// `maximized` 为真时 [bounds] 是最大化矩形：只用于判断「启动后是否补
/// 最大化」，不能当作还原尺寸。
typedef SavedWindowBounds = ({Rect bounds, bool maximized});

/// 恢复窗口时读到的完整状态：几何与最大化分开存，可能只有其中一项
/// （首启就最大化 → 退出，只有标记可读）。
typedef PreferredWindowState = ({Rect? bounds, bool maximized});

/// 窗口几何读写（`WindowChrome` 的恢复与防抖保存路径调用）。
class WindowBoundsStore {
  /// [settings] 仅测试注入；生产构造自己的设备本地入口。
  WindowBoundsStore({DeviceSettings? settings})
    : _settings = settings ?? DeviceSettings();

  /// 几何合并成一个 JSON 字符串：桌面 shared_preferences 每次 set* 都会
  /// 重写整个偏好文件，四个 double 分开写就是四次整文件写入。最大化标记独立
  /// 保留（事件驱动、不参与几何防抖，合并会让两条写入路径互相覆盖）。
  static const String keyBounds = kWindowBoundsKeyName;

  static const String keyMaximized = kWindowMaximizedKeyName;

  /// 按虚拟桌面分组的几何 / 最大化标记。键是原生返回的规范化桌面 ID
  /// （小写、无大括号）；值带 `savedAt` 用于淘汰。
  static const String keyBoundsByDesktop = kWindowBoundsByDesktopKeyName;

  static const String keyMaximizedByDesktop = kWindowMaximizedByDesktopKeyName;

  /// 每个分组最多保留的桌面数：虚拟桌面会被删除 / 重建，旧 GUID 不会
  /// 再命中，靠最近使用淘汰，避免偏好文件无限增长。
  static const int maxDesktopEntries = 8;

  final DeviceSettings _settings;

  /// 读取全局保存值；四项几何缺一或不可用（非有限、非正）时返回 null
  /// （按「没有保存过」处理，窗口走系统默认位置）。新键损坏时回退旧键。
  Future<SavedWindowBounds?> load() async {
    final bounds =
        await _settings.readJson(kWindowBoundsKey) ?? await _loadLegacyBounds();
    if (bounds == null) return null;
    return (
      bounds: bounds,
      maximized: await _settings.read(kWindowMaximizedKey),
    );
  }

  /// 读取最大化标记（独立于几何：最大化期间不写几何，只有该标记可读）。
  Future<bool> loadMaximized() => _settings.read(kWindowMaximizedKey);

  /// 恢复路径的首选读取：该虚拟桌面 → 最近使用的分组 → 旧全局键。
  ///
  /// [desktopId] 为空（非 Windows / 原生不可用）时直接走旧全局键。
  /// 最大化标记只认同一桌面的分组：某桌面有几何但从未最大化过时不应继承
  /// 另一个桌面的最大化状态。
  Future<PreferredWindowState?> loadPreferred(String? desktopId) async {
    final boundsEntries =
        await _settings.readJson(kWindowBoundsByDesktopKey) ??
        const <String, WindowDesktopBounds>{};
    final flagEntries =
        await _settings.readJson(kWindowMaximizedByDesktopKey) ??
        const <String, WindowDesktopMaximized>{};

    final exactBounds = desktopId == null ? null : boundsEntries[desktopId];
    final fallbackBounds = exactBounds == null && boundsEntries.isNotEmpty
        ? _latest(boundsEntries, (entry) => entry.savedAt)
        : null;
    final groupedBounds = exactBounds?.bounds ?? fallbackBounds?.bounds;
    final legacyBounds = groupedBounds == null
        ? (await _settings.readJson(kWindowBoundsKey) ??
              await _loadLegacyBounds())
        : null;
    final bounds = groupedBounds ?? legacyBounds;

    final exactFlag = desktopId == null ? null : flagEntries[desktopId];
    final bool maximized;
    if (exactFlag != null) {
      maximized = exactFlag.maximized;
    } else if (groupedBounds == null && flagEntries.isNotEmpty) {
      // 只有最大化标记（首启就最大化 → 退出）：按最近一次分组恢复。
      maximized = _latest(flagEntries, (entry) => entry.savedAt).maximized;
    } else if (groupedBounds == null) {
      maximized = await _settings.read(kWindowMaximizedKey);
    } else {
      // 该分组有几何但没有标记 = 这个桌面从未最大化过。
      maximized = false;
    }

    if (bounds == null && !maximized) return null;
    return (bounds: bounds, maximized: maximized);
  }

  /// 只读指定虚拟桌面的分组；没有该桌面的记录时返回 null（**不**回退）。
  ///
  /// 托盘 / 单实例切换桌面时用它：目标桌面没有记录就保持当前几何，不继承
  /// 其它桌面的位置 / 最大化状态。
  Future<PreferredWindowState?> loadFor(String desktopId) async {
    if (desktopId.isEmpty) return null;
    final boundsEntries =
        await _settings.readJson(kWindowBoundsByDesktopKey) ??
        const <String, WindowDesktopBounds>{};
    final flagEntries =
        await _settings.readJson(kWindowMaximizedByDesktopKey) ??
        const <String, WindowDesktopMaximized>{};
    final bounds = boundsEntries[desktopId]?.bounds;
    final flag = flagEntries[desktopId];
    if (bounds == null && flag == null) return null;
    return (bounds: bounds, maximized: flag?.maximized ?? false);
  }

  /// 保存窗口矩形（正常态；最大化态不调用，见 `WindowChrome` 的保存路径）。
  Future<void> saveBounds(Rect bounds) =>
      _settings.writeJson(kWindowBoundsKey, bounds);

  /// 保存最大化标记（最大化 ⇄ 还原事件即时写入，不参与防抖）。
  Future<void> saveMaximized(bool maximized) =>
      _settings.write(kWindowMaximizedKey, maximized);

  /// 按虚拟桌面保存几何；[desktopId] 为空时退回全局键。
  Future<void> saveBoundsFor(String desktopId, Rect bounds) async {
    if (desktopId.isEmpty) return saveBounds(bounds);
    final entries =
        await _settings.readJson(kWindowBoundsByDesktopKey) ??
        <String, WindowDesktopBounds>{};
    entries[desktopId] = (bounds: bounds, savedAt: _nowMs());
    _prune(entries, (entry) => entry.savedAt);
    await _settings.writeJson(kWindowBoundsByDesktopKey, entries);
  }

  /// 按虚拟桌面保存最大化标记；[desktopId] 为空时退回全局键。
  Future<void> saveMaximizedFor(String desktopId, bool maximized) async {
    if (desktopId.isEmpty) return saveMaximized(maximized);
    final entries =
        await _settings.readJson(kWindowMaximizedByDesktopKey) ??
        <String, WindowDesktopMaximized>{};
    entries[desktopId] = (maximized: maximized, savedAt: _nowMs());
    _prune(entries, (entry) => entry.savedAt);
    await _settings.writeJson(kWindowMaximizedByDesktopKey, entries);
  }

  /// 旧版四键：四个都在才算一份几何，缺一按「没有保存过」处理。
  Future<Rect?> _loadLegacyBounds() async {
    final x = await _settings.readIfPresent(kLegacyWindowBoundsXKey);
    final y = await _settings.readIfPresent(kLegacyWindowBoundsYKey);
    final width = await _settings.readIfPresent(kLegacyWindowBoundsWidthKey);
    final height = await _settings.readIfPresent(kLegacyWindowBoundsHeightKey);
    if (x == null || y == null || width == null || height == null) {
      return null;
    }
    return kWindowBoundsKey.decode({'x': x, 'y': y, 'w': width, 'h': height});
  }

  static T _latest<T>(Map<String, T> entries, int Function(T) savedAtOf) =>
      entries.values.reduce((a, b) => savedAtOf(a) >= savedAtOf(b) ? a : b);

  static void _prune<T extends Object>(
    Map<String, T> entries,
    int Function(T) savedAtOf,
  ) {
    if (entries.length <= maxDesktopEntries) return;
    final ordered = entries.keys.toList()
      ..sort(
        (a, b) => savedAtOf(entries[a]!).compareTo(savedAtOf(entries[b]!)),
      );
    for (final key in ordered.take(entries.length - maxDesktopEntries)) {
      entries.remove(key);
    }
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;
}
