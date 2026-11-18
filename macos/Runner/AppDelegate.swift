import AudioToolbox
import Cocoa
import CoreAudio
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 与 `WindowChrome` 共用同一条窗口通道：Dock 图标被再次点击时，
  /// 把「恢复窗口」交给 Dart（`WindowChrome.show()`），而不是让 AppKit
  /// 直接显示一扇还停在托盘休眠态的空窗。
  private let windowChannelName = "top.stillmisty.molia/window"

  /// 输出设备丢失通道：与 Dart 侧
  /// `lib/playback/desktop_audio_output_port_io.dart` 成对。
  private let audioOutputChannelName = "top.stillmisty.molia/audio_output"

  private var audioOutputChannel: FlutterMethodChannel?
  private var audioOutputListenerBlock: AudioObjectPropertyListenerBlock?
  private var audioOutputListenerAddress: AudioObjectPropertyAddress?
  private var defaultOutputDevice = AudioDeviceID(kAudioObjectUnknown)

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    startAudioOutputWatcher()
  }

  override func applicationWillTerminate(_ notification: Notification) {
    stopAudioOutputWatcher()
    super.applicationWillTerminate(notification)
  }

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

  // MARK: - 默认输出设备丢失

  /// 在系统对象上监听默认输出变化，回调固定投递到主队列（CoreAudio 的 block
  /// listener 可能来自任意 HAL 线程；直接碰 Flutter 通道是崩溃风险）。
  private func startAudioOutputWatcher() {
    guard audioOutputChannel == nil,
      let controller = mainFlutterViewController()
    else { return }
    audioOutputChannel = FlutterMethodChannel(
      name: audioOutputChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    defaultOutputDevice = currentDefaultOutputDevice()

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    audioOutputListenerAddress = address
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.handleDefaultOutputChanged()
    }
    audioOutputListenerBlock = block
    _ = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      block
    )
  }

  private func stopAudioOutputWatcher() {
    guard let block = audioOutputListenerBlock,
      var address = audioOutputListenerAddress
    else { return }
    _ = AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      block
    )
    audioOutputListenerBlock = nil
    audioOutputListenerAddress = nil
    audioOutputChannel = nil
  }

  /// 只有「上一台默认输出已经不可用 / 新默认未知」才上报；两台仍存活的设备
  /// 之间主动切换继续播放（ADR-0036）。
  private func handleDefaultOutputChanged() {
    let previous = defaultOutputDevice
    let current = currentDefaultOutputDevice()
    if previous != AudioDeviceID(kAudioObjectUnknown) {
      let lost = current == AudioDeviceID(kAudioObjectUnknown)
        || !isDeviceAlive(previous)
      if lost {
        audioOutputChannel?.invokeMethod("outputLost", arguments: nil)
      }
    }
    defaultOutputDevice = current
  }

  private func currentDefaultOutputDevice() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &device
    )
    return status == noErr ? device : AudioDeviceID(kAudioObjectUnknown)
  }

  private func isDeviceAlive(_ device: AudioDeviceID) -> Bool {
    guard device != AudioDeviceID(kAudioObjectUnknown) else { return false }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      device,
      &address,
      0,
      nil,
      &size,
      &alive
    )
    return status == noErr && alive != 0
  }

  private func mainFlutterViewController() -> FlutterViewController? {
    return NSApp.windows
      .compactMap({ $0.contentViewController as? FlutterViewController })
      .first
  }
}
