import 'package:shared_preferences/shared_preferences.dart';

/// 桌面壳层布局偏好（侧栏展开 / 队列面板开关与宽度）的**设备本地**持久化。
///
/// 为什么是设备本地键（不登记 `SettingsRegistry`）：窗口布局是设备相关项——
/// 桌面窗口尺寸与移动端屏幕无关，跨设备同步只会把「A 机器上展开的侧栏 /
/// 拉宽的队列面板」带到 B 机器的窄窗口，产生与当前窗口不匹配的状态；与
/// 省流 / 托盘 / 应用内音量同一取舍，键名只出现在本文件。
///
/// 读写失败静默（读取回默认、写入不打断交互）：布局记忆是尽力而为的体验
/// 设置，存储不可用（测试 / 平台异常）时壳层照常可用。
class ShellLayoutPrefs {
  /// [preferences] 仅测试注入；生产走 SharedPreferences 单例。
  ShellLayoutPrefs({SharedPreferences? preferences})
      : _preferences = preferences;

  /// 设备本地键。
  static const String keyRailExpanded = 'shell_rail_expanded';
  static const String keyQueuePanelOpen = 'queue_panel_open';
  static const String keyQueuePanelWidth = 'queue_panel_width';

  /// 默认侧栏展开（桌面空间充裕，首启即展示完整导航）。
  static const bool defaultRailExpanded = true;

  /// 默认队列面板关闭（常驻底部播放条已承载当前曲目，队列按需拉出）。
  static const bool defaultQueuePanelOpen = false;

  /// 队列面板宽度：默认 360，可拖区间 260–480。
  static const double defaultQueuePanelWidth = 360;
  static const double minQueuePanelWidth = 260;
  static const double maxQueuePanelWidth = 480;

  final SharedPreferences? _preferences;

  /// 读取已保存的布局状态；无记录 / 读取失败回默认值。
  Future<({bool railExpanded, bool queuePanelOpen, double queuePanelWidth})>
      load() async {
    try {
      final prefs = _preferences ?? await SharedPreferences.getInstance();
      return (
        railExpanded: prefs.getBool(keyRailExpanded) ?? defaultRailExpanded,
        queuePanelOpen:
            prefs.getBool(keyQueuePanelOpen) ?? defaultQueuePanelOpen,
        // 越界值（旧数据 / 手工改偏好）收进可拖区间，避免面板一开始就
        // 渲染在把手拖不回来的宽度上。
        queuePanelWidth:
            (prefs.getDouble(keyQueuePanelWidth) ?? defaultQueuePanelWidth)
                .clamp(minQueuePanelWidth, maxQueuePanelWidth),
      );
    } catch (_) {
      return (
        railExpanded: defaultRailExpanded,
        queuePanelOpen: defaultQueuePanelOpen,
        queuePanelWidth: defaultQueuePanelWidth,
      );
    }
  }

  Future<void> saveRailExpanded(bool value) =>
      _write((prefs) => prefs.setBool(keyRailExpanded, value));

  Future<void> saveQueuePanelOpen(bool value) =>
      _write((prefs) => prefs.setBool(keyQueuePanelOpen, value));

  Future<void> saveQueuePanelWidth(double value) => _write(
        (prefs) => prefs.setDouble(
          keyQueuePanelWidth,
          value.clamp(minQueuePanelWidth, maxQueuePanelWidth),
        ),
      );

  /// 统一吞掉写入异常：布局记忆失败只影响下次启动，不值得打断交互。
  Future<void> _write(
      Future<void> Function(SharedPreferences prefs) write) async {
    try {
      final prefs = _preferences ?? await SharedPreferences.getInstance();
      await write(prefs);
    } catch (_) {
      // 静默：持久化失败不打断用户操作。
    }
  }
}
