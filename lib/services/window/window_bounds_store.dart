/// 窗口几何的设备本地存储（SharedPreferences）。
///
/// 为什么**不登记** `SettingsRegistry`：窗口位置/大小是设备相关项（每台
/// 显示器的分辨率与摆放都不同），同步到别的设备只会把窗口丢到看不见的
/// 地方——与省流 / 托盘行为同一取舍。键名只出现在本文件
/// （`settings_keys_test` 只约束登记键）。
library;

import 'dart:convert';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

/// 上次关闭时的窗口几何。
///
/// `maximized` 为真时 [bounds] 是最大化矩形：只用于判断「启动后是否补
/// 最大化」，不能当作还原尺寸。
typedef SavedWindowBounds = ({Rect bounds, bool maximized});

/// 窗口几何读写（`WindowChrome` 的恢复与防抖保存路径调用）。
class WindowBoundsStore {
  WindowBoundsStore({this._prefs});

  /// 几何合并成一个 JSON 字符串：桌面 shared_preferences 每次 set* 都会
  /// 重写整个偏好文件，四个 double 分开写就是四次整文件写入。最大化标记独立
  /// 保留（事件驱动、不参与几何防抖，合并会让两条写入路径互相覆盖）。
  static const String keyBounds = 'window_bounds';

  static const String keyMaximized = 'window_maximized';

  // 旧版四键：只读兜底，升级后首次启动仍能恢复上次窗口。
  static const String _legacyKeyX = 'window_bounds_x';
  static const String _legacyKeyY = 'window_bounds_y';
  static const String _legacyKeyWidth = 'window_bounds_width';
  static const String _legacyKeyHeight = 'window_bounds_height';

  SharedPreferences? _prefs;

  /// 读取保存值；四项几何缺一或不可用（非有限、非正）时返回 null
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

  /// 保存窗口矩形（正常态；最大化态不调用，见 `WindowChrome` 的保存路径）。
  Future<void> saveBounds(Rect bounds) async {
    final prefs = await _prefsInstance();
    if (prefs == null) return;
    await prefs.setString(
      keyBounds,
      jsonEncode({
        'x': bounds.left,
        'y': bounds.top,
        'w': bounds.width,
        'h': bounds.height,
      }),
    );
  }

  /// 保存最大化标记（最大化 ⇄ 还原事件即时写入，不参与防抖）。
  Future<void> saveMaximized(bool maximized) async {
    final prefs = await _prefsInstance();
    await prefs?.setBool(keyMaximized, maximized);
  }

  static Rect? _decodeBounds(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
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
    } on FormatException {
      return null;
    }
  }

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

  Future<SharedPreferences?> _prefsInstance() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }
}
