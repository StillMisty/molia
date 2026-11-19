import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 首次启动没有保存的几何时居中；`WindowChrome` 恢复保存的 bounds 时会覆盖。
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 设备字体枚举 / 电池状态：Pigeon 生成的 Swift host（与 iOS 同一契约）。
    AppleSystemHostSetup.setUp(
      binaryMessenger: flutterViewController.engine.binaryMessenger,
      api: AppleSystemHostImpl())

    super.awakeFromNib()
  }
}
