import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // 设备字体枚举：供设置「应用字体」与海报字体选择使用。
    if let controller = window?.rootViewController as? FlutterViewController {
      let fontsChannel = FlutterMethodChannel(
        name: "top.stillmisty.molia/system_fonts",
        binaryMessenger: controller.binaryMessenger)
      fontsChannel.setMethodCallHandler { call, result in
        if call.method == "listFamilies" {
          result(UIFont.familyNames.sorted())
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
