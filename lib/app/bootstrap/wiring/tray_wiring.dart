/// 托盘存在态接线：窗口不可见时补一次防抖写，托盘内按播放变化 trim。
///
/// 托盘本身的创建 / 退出路径属于桌面栈（`desktop_stack.dart`）；这里只把
/// [AppPresence] 的翻转接到「补写」与内存 trim，不持有桌面插件。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;

import '../../../services/app_presence.dart';
import '../../../services/diagnostics/diagnostics_service.dart';
import '../playback_stack.dart';
import 'memory_wiring.dart';

/// 注册托盘 / 最小化相关的存在态监听。
///
/// [flushDeferredWrites] 由生命周期接线提供：连续滑杆 / 封面 seed 用的是
/// 防抖写，窗口不可见或退后台前补一次，避免拖完就关窗口时丢掉最后一段。
/// [diagnostics] 同步会话的「最后可见状态」：桌面托盘隐藏不一定走
/// `AppLifecycleState`，这里补写同一份后台 / 前台标记。
void wireTrayPresence({
  required PlaybackStack playback,
  required VoidCallback flushDeferredWrites,
  required DiagnosticsService diagnostics,
}) {
  // 桌面托盘 / 最小化不一定走 `AppLifecycleState`：窗口层置位 `AppPresence`
  // 时也补一次；`minimized` 同样算不可见（用户随时可能从任务栏恢复）。
  AppPresence.instance.addListener(() {
    final presence = AppPresence.instance;
    // 边界：移动端没有托盘事件，仍由 `AppLifecycleListener` 驱动；桌面两者
    // 都写同一份 phase，后到的事件覆盖前者，语义都是「最后可见状态」。
    unawaited(
      presence.isVisible
          ? diagnostics.session.onResumed()
          : diagnostics.session.onHidden(),
    );
    if (!presence.isVisible) flushDeferredWrites();
  });
  wireTrayTrim(playback: playback);
}
