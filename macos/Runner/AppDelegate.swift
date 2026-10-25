import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 与 `WindowChrome` 共用同一条窗口通道：Dock 图标被再次点击时，
  /// 把「恢复窗口」交给 Dart（`WindowChrome.show()`），而不是让 AppKit
  /// 直接显示一扇还停在托盘休眠态的空窗。
  private let windowChannelName = "top.stillmisty.molia/window"

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 托盘「退出」走 `windowManager.destroy()` → 销毁最后一扇窗 → 进程退出。
    // 关闭到托盘时窗口只是 orderOut，不触发这条路径。
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag else { return true }
    guard
      let controller = sender.windows
        .compactMap({ $0.contentViewController as? FlutterViewController })
        .first
    else {
      return true
    }
    FlutterMethodChannel(
      name: windowChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    ).invokeMethod("reopen", arguments: nil)
    return true
  }
}
