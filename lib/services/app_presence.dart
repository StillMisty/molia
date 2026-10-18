/// 应用窗口存在态：可见 / 最小化 / 关闭到托盘。
///
/// 这是「窗口是否还在用户眼前」的唯一事实源：托盘与最小化的置位收在窗口层
/// （`window_chrome_io.dart`），消费者各自决定怎么应对——内存守卫据此清图片
/// 缓存，封面预取 / 取色据此停产，应用壳据此进入托盘休眠。服务不反向依赖
/// 任何 UI，测试可自建实例注入。
library;

import 'package:flutter/foundation.dart';

/// 窗口存在态。
enum AppPresenceState {
  /// 窗口可见（含失焦：失焦不改变界面语义）。
  visible,

  /// 窗口最小化：界面状态与缓存保持，只停后台解码类工作（恢复要跟手）。
  minimized,

  /// 关闭到托盘：窗口隐藏，界面进入休眠，重开等价一次「保留播放的冷启动」。
  trayHidden,
}

/// 全局窗口存在态（单例入口 [AppPresence.instance]）。
///
/// 状态翻转是低频事件（点关闭 / 点托盘 / 最小化），用 [ValueNotifier] 即可；
/// 置位方法幂等——最小化与托盘路径可能先后到达同一状态，重复置位不得触发
/// 多余的清理 / 重建。
class AppPresence extends ValueNotifier<AppPresenceState> {
  AppPresence([super.initial = AppPresenceState.visible]);

  /// 全局单例（组合根与各服务的缺省依赖）。
  static final AppPresence instance = AppPresence();

  bool get isVisible => value == AppPresenceState.visible;

  /// 窗口不在用户眼前（最小化或托盘隐藏）。
  bool get isBackgrounded => !isVisible;

  /// 关闭到托盘（应用壳据此休眠界面）。
  bool get isTrayHidden => value == AppPresenceState.trayHidden;

  void markVisible() => _set(AppPresenceState.visible);

  void markMinimized() => _set(AppPresenceState.minimized);

  void markTrayHidden() => _set(AppPresenceState.trayHidden);

  void _set(AppPresenceState next) {
    if (value == next) return;
    value = next;
  }
}
