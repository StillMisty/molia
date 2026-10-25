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

    // 设备字体枚举：供设置「应用字体」与海报字体选择使用（与 iOS 同协议）。
    let fontsChannel = FlutterMethodChannel(
      name: "top.stillmisty.molia/system_fonts",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    fontsChannel.setMethodCallHandler { call, result in
      if call.method == "listFamilies" {
        result(NSFontManager.shared.availableFontFamilies.sorted())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
