import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 定时关闭原生唤醒通道（强引用持有待触发的 DispatchWorkItem）。
  private var sleepTimerHandler: SleepTimerChannelHandler?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // UIScene 生命周期下启动早期还拿不到 Flutter 的根控制器；插件与通道
    // 统一在 `didInitializeImplicitFlutterEngine` 注册（见 Flutter 的 UIScene
    // 迁移），这里只保留父类行为。
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()

    // 设备字体枚举 / 电池状态：Pigeon 生成的 Swift host（ADR-0038 阶段 3）。
    AppleSystemHostSetup.setUp(
      binaryMessenger: messenger,
      api: AppleSystemHostImpl())

    // 定时关闭：原生定时器到点唤醒 Dart，补熄屏下 Dart timer 被挂起的
    // 缺口（后台音频期间进程保持活跃；真正暂停仍由 Dart 控制器执行）。
    sleepTimerHandler = SleepTimerChannelHandler(messenger: messenger)
  }
}

/// 定时关闭的原生唤醒通道（与 Android `SleepTimerChannelHandler` 同协议）。
///
/// 协议：`arm` { millis: Int, token: Int, keepAwake: Bool } / `cancel`；到点回调
/// `fired` { token }。iOS 由音频后台模式保持进程活跃；`keepAwake` 只为与
/// Android 协议对齐（iOS 没有 partial wake lock），这里忽略。
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
