/// 窗口几何的设备本地存储（SharedPreferences）。
///
/// 为什么**不登记** `SettingsRegistry`：窗口位置/大小是设备相关项（每台
/// 显示器的分辨率与摆放都不同），同步到别的设备只会把窗口丢到看不见的
/// 地方——与省流 / 托盘行为同一取舍。键名只出现在本文件
/// （`settings_keys_test` 只约束登记键）。
///
/// 桌面端按**虚拟桌面**分组保存：同一台机器上不同虚拟桌面可以有各自的
/// 位置 / 大小 / 最大化状态（`window_bounds_by_desktop` /
/// `window_maximized_by_desktop`）。没有桌面信息（非 Windows / 原生接口
/// 不可用）时回退为旧的全局单键，升级前的数据仍能恢复。
library;

import 'dart:convert';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

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
  WindowBoundsStore({this._prefs});

  /// 几何合并成一个 JSON 字符串：桌面 shared_preferences 每次 set* 都会
  /// 重写整个偏好文件，四个 double 分开写就是四次整文件写入。最大化标记独立
  /// 保留（事件驱动、不参与几何防抖，合并会让两条写入路径互相覆盖）。
  static const String keyBounds = 'window_bounds';

  static const String keyMaximized = 'window_maximized';

  /// 按虚拟桌面分组的几何 / 最大化标记。键是原生返回的规范化桌面 ID
  /// （小写、无大括号）；值带 `savedAt` 用于淘汰。
  static const String keyBoundsByDesktop = 'window_bounds_by_desktop';

  static const String keyMaximizedByDesktop = 'window_maximized_by_desktop';

  /// 每个分组最多保留的桌面数：虚拟桌面会被删除 / 重建，旧 GUID 不会
  /// 再命中，靠最近使用淘汰，避免偏好文件无限增长。
  static const int maxDesktopEntries = 8;

  // 旧版四键：只读兜底，升级后首次启动仍能恢复上次窗口。
  static const String _legacyKeyX = 'window_bounds_x';
  static const String _legacyKeyY = 'window_bounds_y';
  static const String _legacyKeyWidth = 'window_bounds_width';
  static const String _legacyKeyHeight = 'window_bounds_height';

  SharedPreferences? _prefs;

  /// 读取全局保存值；四项几何缺一或不可用（非有限、非正）时返回 null
  /// （按「没有保存过」处理，窗口走系统默认位置）。新键损坏时回退旧键。
  Future<SavedWindowBounds?> load() async {
    final prefs = await _prefsInstance();
    if (prefs == null) return null;
    final bounds =
        _decodeBounds(prefs.getString(keyBounds)) ?? _loadLegacyBounds(prefs);
    if (bounds == null) return null;
    return (bounds: bounds, maximized: prefs.getBool(keyMaximized) ?? false);
  }

  /// 读取最大化标记（独立于几何：最大化期间不写几何，只有该标记可读）。
  Future<bool> loadMaximized() async {
    final prefs = await _prefsInstance();
    return prefs?.getBool(keyMaximized) ?? false;
  }

  /// 恢复路径的首选读取：该虚拟桌面 → 最近使用的分组 → 旧全局键。
  ///
  /// [desktopId] 为空（非 Windows / 原生不可用）时直接走旧全局键。
  /// 最大化标记只认同一桌面的分组：某桌面有几何但从未最大化过时不应继承
  /// 另一个桌面的最大化状态。
  Future<PreferredWindowState?> loadPreferred(String? desktopId) async {
    final prefs = await _prefsInstance();
    if (prefs == null) return null;

    final boundsEntries = _decodeBoundsMap(prefs.getString(keyBoundsByDesktop));
    final flagEntries = _decodeMaximizedMap(
      prefs.getString(keyMaximizedByDesktop),
    );

    final exactBounds = desktopId == null ? null : boundsEntries[desktopId];
    final fallbackBounds = exactBounds == null && boundsEntries.isNotEmpty
        ? _latest(boundsEntries, (entry) => entry.savedAt)
        : null;
    final groupedBounds = exactBounds?.bounds ?? fallbackBounds?.bounds;
    final legacyBounds = groupedBounds == null
        ? (_decodeBounds(prefs.getString(keyBounds)) ??
              _loadLegacyBounds(prefs))
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
      maximized = prefs.getBool(keyMaximized) ?? false;
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
    final prefs = await _prefsInstance();
    if (prefs == null) return null;
    final boundsEntries = _decodeBoundsMap(prefs.getString(keyBoundsByDesktop));
    final flagEntries = _decodeMaximizedMap(
      prefs.getString(keyMaximizedByDesktop),
    );
    final bounds = boundsEntries[desktopId]?.bounds;
    final flag = flagEntries[desktopId];
    if (bounds == null && flag == null) return null;
    return (bounds: bounds, maximized: flag?.maximized ?? false);
  }

  /// 保存窗口矩形（正常态；最大化态不调用，见 `WindowChrome` 的保存路径）。
  Future<void> saveBounds(Rect bounds) async {
    final prefs = await _prefsInstance();
    if (prefs == null) return;
    await prefs.setString(keyBounds, jsonEncode(_boundsToJson(bounds)));
  }

  /// 保存最大化标记（最大化 ⇄ 还原事件即时写入，不参与防抖）。
  Future<void> saveMaximized(bool maximized) async {
    final prefs = await _prefsInstance();
    await prefs?.setBool(keyMaximized, maximized);
  }

  /// 按虚拟桌面保存几何；[desktopId] 为空时退回全局键。
  Future<void> saveBoundsFor(String desktopId, Rect bounds) async {
    if (desktopId.isEmpty) return saveBounds(bounds);
    final prefs = await _prefsInstance();
    if (prefs == null) return;
    final entries = _decodeBoundsMap(prefs.getString(keyBoundsByDesktop));
    entries[desktopId] = _DesktopBounds(bounds, _nowMs());
    _prune(entries, (entry) => entry.savedAt);
    await prefs.setString(
      keyBoundsByDesktop,
      jsonEncode({
        for (final entry in entries.entries)
          entry.key: {
            ..._boundsToJson(entry.value.bounds),
            'savedAt': entry.value.savedAt,
          },
      }),
    );
  }

  /// 按虚拟桌面保存最大化标记；[desktopId] 为空时退回全局键。
  Future<void> saveMaximizedFor(String desktopId, bool maximized) async {
    if (desktopId.isEmpty) return saveMaximized(maximized);
    final prefs = await _prefsInstance();
    if (prefs == null) return;
    final entries = _decodeMaximizedMap(prefs.getString(keyMaximizedByDesktop));
    entries[desktopId] = _DesktopFlag(maximized, _nowMs());
    _prune(entries, (entry) => entry.savedAt);
    await prefs.setString(
      keyMaximizedByDesktop,
      jsonEncode({
        for (final entry in entries.entries)
          entry.key: {
            'maximized': entry.value.maximized,
            'savedAt': entry.value.savedAt,
          },
      }),
    );
  }

  static Rect? _decodeBounds(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return _boundsFromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  static Map<String, _DesktopBounds> _decodeBoundsMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final result = <String, _DesktopBounds>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (entry.key.isEmpty || value is! Map<String, dynamic>) continue;
        final bounds = _boundsFromJson(value);
        if (bounds == null) continue;
        final savedAt = value['savedAt'];
        result[entry.key] = _DesktopBounds(
          bounds,
          savedAt is num ? savedAt.toInt() : 0,
        );
      }
      return result;
    } on FormatException {
      return {};
    }
  }

  static Map<String, _DesktopFlag> _decodeMaximizedMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final result = <String, _DesktopFlag>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (entry.key.isEmpty || value is! Map<String, dynamic>) continue;
        final maximized = value['maximized'];
        if (maximized is! bool) continue;
        final savedAt = value['savedAt'];
        result[entry.key] = _DesktopFlag(
          maximized,
          savedAt is num ? savedAt.toInt() : 0,
        );
      }
      return result;
    } on FormatException {
      return {};
    }
  }

  static Rect? _boundsFromJson(Map<String, dynamic> decoded) {
    final x = decoded['x'];
    final y = decoded['y'];
    final width = decoded['w'];
    final height = decoded['h'];
    if (x is! num || y is! num || width is! num || height is! num) {
      return null;
    }
    return _validBounds(
      Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        width.toDouble(),
        height.toDouble(),
      ),
    );
  }

  static Map<String, double> _boundsToJson(Rect bounds) => {
    'x': bounds.left,
    'y': bounds.top,
    'w': bounds.width,
    'h': bounds.height,
  };

  static Rect? _loadLegacyBounds(SharedPreferences prefs) {
    final x = prefs.getDouble(_legacyKeyX);
    final y = prefs.getDouble(_legacyKeyY);
    final width = prefs.getDouble(_legacyKeyWidth);
    final height = prefs.getDouble(_legacyKeyHeight);
    if (x == null || y == null || width == null || height == null) {
      return null;
    }
    return _validBounds(Rect.fromLTWH(x, y, width, height));
  }

  static Rect? _validBounds(Rect bounds) {
    if (!bounds.isFinite || bounds.width <= 0 || bounds.height <= 0) {
      return null;
    }
    return bounds;
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

  Future<SharedPreferences?> _prefsInstance() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }
}

class _DesktopBounds {
  const _DesktopBounds(this.bounds, this.savedAt);

  final Rect bounds;
  final int savedAt;
}

class _DesktopFlag {
  const _DesktopFlag(this.maximized, this.savedAt);

  final bool maximized;
  final int savedAt;
}
