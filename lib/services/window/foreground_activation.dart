/// 把前台激活权限交给已有实例（Windows）。
///
/// 第二实例由用户点击启动、拥有前台权限，因此在通知主实例 `show` 之前先
/// 调用 `AllowSetForegroundWindow(primaryPid)`，主实例的 `window.focus()`
/// 才能把窗口真正拉到前台。非 Windows / 调用失败都返回 false；调用方只记
/// 日志，不影响单实例流程。原生调用见
/// `lib/platform/desktop/foreground_activation.dart`（ADR-0038）。
library;

import '../../platform/desktop/foreground_activation.dart' as platform;

/// 允许 [pid] 进程设置前台窗口。
bool allowSetForegroundWindow(int pid) =>
    platform.allowSetForegroundWindow(pid);
