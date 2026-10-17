import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// 定时关闭原生唤醒通道（强引用持有待触发的 DispatchWorkItem）。
  private var sleepTimerHandler: SleepTimerChannelHandler?

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

      // 定时关闭：原生定时器到点唤醒 Dart，补熄屏下 Dart timer 被挂起的
      // 缺口（后台音频期间进程保持活跃；真正暂停仍由 Dart 控制器执行）。
      sleepTimerHandler = SleepTimerChannelHandler(
        messenger: controller.binaryMessenger)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// 定时关闭的原生唤醒通道（与 Android `SleepTimerChannelHandler` 同协议）。
///
/// 协议：`arm` { millis: Int, token: Int } / `cancel`；到点回调
/// `fired` { token }。iOS 由音频后台模式保持进程活跃；若系统仍挂起，Dart
/// 侧回前台补检兜底。
final class SleepTimerChannelHandler {
  private let channel: FlutterMethodChannel
  private var pending: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "top.stillmisty.molia/sleep_timer",
      binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "arm":
        let args = call.arguments as? [String: Any]
        let millis = (args?["millis"] as? NSNumber)?.int64Value ?? 0
        let token = (args?["token"] as? NSNumber)?.intValue ?? 0
        self?.schedule(millis: millis, token: token)
        result(nil)
      case "cancel":
        self?.cancel()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func schedule(millis: Int64, token: Int) {
    cancel()
    guard millis > 0 else { return }
    let work = DispatchWorkItem { [weak self] in
      self?.pending = nil
      self?.channel.invokeMethod("fired", arguments: token)
    }
    pending = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Int(millis)),
      execute: work)
  }

  private func cancel() {
    pending?.cancel()
    pending = nil
  }
}
