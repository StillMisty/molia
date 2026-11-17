/// 托盘存在态接线：窗口不可见时补一次防抖写，托盘内按播放变化 trim。
///
/// 托盘本身的创建 / 退出路径属于桌面栈（`desktop_stack.dart`）；这里只把
/// [AppPresence] 的翻转接到「补写」与内存 trim，不持有桌面插件。
library;

import 'package:flutter/foundation.dart' show VoidCallback;

import '../../../services/app_presence.dart';
import '../playback_stack.dart';
import 'memory_wiring.dart';

/// 注册托盘 / 最小化相关的存在态监听。
///
/// [flushDeferredWrites] 由生命周期接线提供：连续滑杆 / 封面 seed 用的是
/// 防抖写，窗口不可见或退后台前补一次，避免拖完就关窗口时丢掉最后一段。
void wireTrayPresence({
  required PlaybackStack playback,
  required VoidCallback flushDeferredWrites,
}) {
  // 桌面托盘 / 最小化不一定走 `AppLifecycleState`：窗口层置位 `AppPresence`
  // 时也补一次；`minimized` 同样算不可见（用户随时可能从任务栏恢复）。
  AppPresence.instance.addListener(() {
    if (!AppPresence.instance.isVisible) flushDeferredWrites();
  });
  wireTrayTrim(playback: playback);
}
