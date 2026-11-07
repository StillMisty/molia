/// 把前台激活权限交给已有实例（Windows）。
///
/// Windows 的前台锁会阻止后台进程调用 `SetForegroundWindow`：第二实例由
/// 用户点击启动、拥有前台权限，因此在通知主实例 `show` 之前先调用
/// `AllowSetForegroundWindow(primaryPid)`，主实例的 `window.focus()` 才能
/// 真正把窗口拉到前台，而不是只闪任务栏。
///
/// 非 Windows / 调用失败都返回 false；调用方只记日志，不影响单实例流程。
library;

import 'dart:ffi';
import 'dart:io';

/// 允许 [pid] 进程设置前台窗口。
bool allowSetForegroundWindow(int pid) {
  if (!Platform.isWindows || pid <= 0) return false;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final allow = user32
        .lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'AllowSetForegroundWindow',
        );
    return allow(pid) != 0;
  } catch (_) {
    return false;
  }
}
