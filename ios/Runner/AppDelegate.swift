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

      // 电池状态：同步调度器的省电等级判定。
      let batteryChannel = FlutterMethodChannel(
        name: "top.stillmisty.molia/battery",
        binaryMessenger: controller.binaryMessenger)
      batteryChannel.setMethodCallHandler { call, result in
        if call.method == "snapshot" {
          UIDevice.current.isBatteryMonitoringEnabled = true
          let level = UIDevice.current.batteryLevel
          let state = UIDevice.current.batteryState
          let charging = state == .charging || state == .full
          let payload: [String: Any] = [
            "level": level < 0 ? -1 : Int((level * 100).rounded()),
            "charging": charging,
            "powerSave": ProcessInfo.processInfo.isLowPowerModeEnabled,
          ]
          result(payload)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
