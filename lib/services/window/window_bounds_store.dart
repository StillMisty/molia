/// 窗口几何的设备本地存储（SharedPreferences）。
///
/// 为什么**不登记** `SettingsRegistry`：窗口位置/大小是设备相关项（每台
/// 显示器的分辨率与摆放都不同），同步到别的设备只会把窗口丢到看不见的
/// 地方——与省流 / 托盘行为同一取舍。键名只出现在本文件
/// （`settings_keys_test` 只约束登记键）。
library;

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

  static const String keyX = 'window_bounds_x';
  static const String keyY = 'window_bounds_y';
  static const String keyWidth = 'window_bounds_width';
  static const String keyHeight = 'window_bounds_height';
  static const String keyMaximized = 'window_maximized';

  SharedPreferences? _prefs;

  /// 读取保存值；四项几何缺一或不可用（非有限、非正）时返回 null
  /// （按「没有保存过」处理，窗口走系统默认位置）。
  Future<SavedWindowBounds?> load() async {
    final prefs = await _prefsInstance();
    final x = prefs?.getDouble(keyX);
    final y = prefs?.getDouble(keyY);
    final width = prefs?.getDouble(keyWidth);
    final height = prefs?.getDouble(keyHeight);
    if (x == null || y == null || width == null || height == null) {
      return null;
    }
    final bounds = Rect.fromLTWH(x, y, width, height);
    if (!bounds.isFinite || bounds.width <= 0 || bounds.height <= 0) {
      return null;
    }
    return (bounds: bounds, maximized: prefs?.getBool(keyMaximized) ?? false);
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
    await prefs.setDouble(keyX, bounds.left);
    await prefs.setDouble(keyY, bounds.top);
    await prefs.setDouble(keyWidth, bounds.width);
    await prefs.setDouble(keyHeight, bounds.height);
  }

  /// 保存最大化标记（最大化 ⇄ 还原事件即时写入，不参与防抖）。
  Future<void> saveMaximized(bool maximized) async {
    final prefs = await _prefsInstance();
    await prefs?.setBool(keyMaximized, maximized);
  }

  Future<SharedPreferences?> _prefsInstance() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }
}
