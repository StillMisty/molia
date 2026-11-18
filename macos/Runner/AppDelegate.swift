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

  /// macOS 播放菜单通道：原生 → Dart 发送命令，Dart → 原生发送文案 / 状态。
  private let playbackMenuChannelName = "top.stillmisty.molia/playback_menu"

  private var audioOutputChannel: FlutterMethodChannel?
  private var audioOutputListenerBlock: AudioObjectPropertyListenerBlock?
  private var audioOutputListenerAddress: AudioObjectPropertyAddress?
  private var defaultOutputDevice = AudioDeviceID(kAudioObjectUnknown)

  private var playbackChannel: FlutterMethodChannel?
  private var playbackMenuItem: NSMenuItem?
  private var playbackMenu: NSMenu?
  private var playPauseMenuItem: NSMenuItem?
  private var previousMenuItem: NSMenuItem?
  private var nextMenuItem: NSMenuItem?

  /// 原生只在值变化时改菜单（避免每次播放进度通知都重设标题）。
  private var playbackMenuTitle: String?
  private var playbackMenuPlayPauseLabel: String?
  private var playbackMenuPreviousLabel: String?
  private var playbackMenuNextLabel: String?
  private var playbackMenuHasState = false
  private var playbackMenuHasTrack = false
  private var playbackMenuIsPlaying = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    installPlaybackMenu()
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

  // MARK: - 播放菜单

  /// 程序化插入「播放」菜单（View 之后、Window 之前），不改 MainMenu.xib。
  /// 不设 keyEquivalent：媒体键与应用内可自定义快捷键仍是唯一键位来源。
  private func installPlaybackMenu() {
    guard playbackMenu == nil,
      let mainMenu = NSApp.mainMenu,
      let controller = mainFlutterViewController()
    else { return }

    let channel = FlutterMethodChannel(
      name: playbackMenuChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.applyPlaybackMenuUpdate(call.arguments)
      result(nil)
    }
    playbackChannel = channel

    let topItem = NSMenuItem()
    let menu = NSMenu(title: "Playback")
    menu.autoenablesItems = false
    let playPause = NSMenuItem(
      title: "Play/Pause",
      action: #selector(handlePlayPause),
      keyEquivalent: ""
    )
    playPause.target = self
    let previous = NSMenuItem(
      title: "Previous",
      action: #selector(handlePrevious),
      keyEquivalent: ""
    )
    previous.target = self
    let next = NSMenuItem(
      title: "Next",
      action: #selector(handleNext),
      keyEquivalent: ""
    )
    next.target = self
    menu.addItem(playPause)
    menu.addItem(previous)
    menu.addItem(next)

    topItem.submenu = menu
    let items = mainMenu.items
    let viewIndex = items.firstIndex { $0.title == "View" }
    let windowIndex = items.firstIndex { $0.title == "Window" }
    let insertIndex: Int
    if let windowIndex = windowIndex {
      insertIndex = windowIndex
    } else if let viewIndex = viewIndex {
      insertIndex = viewIndex + 1
    } else {
      insertIndex = items.count
    }
    mainMenu.insertItem(topItem, at: insertIndex)

    playbackMenuItem = topItem
    playbackMenu = menu
    playPauseMenuItem = playPause
    previousMenuItem = previous
    nextMenuItem = next
    updatePlaybackMenuEnabled()
  }

  private func applyPlaybackMenuUpdate(_ arguments: Any?) {
    guard let arguments = arguments as? [String: Any] else { return }
    if let title = arguments["menuTitle"] as? String,
      title != playbackMenuTitle
    {
      playbackMenuTitle = title
      playbackMenuItem?.title = title
      playbackMenu?.title = title
    }
    if let label = arguments["playPauseLabel"] as? String,
      label != playbackMenuPlayPauseLabel
    {
      playbackMenuPlayPauseLabel = label
      playPauseMenuItem?.title = label
    }
    if let label = arguments["previousLabel"] as? String,
      label != playbackMenuPreviousLabel
    {
      playbackMenuPreviousLabel = label
      previousMenuItem?.title = label
    }
    if let label = arguments["nextLabel"] as? String,
      label != playbackMenuNextLabel
    {
      playbackMenuNextLabel = label
      nextMenuItem?.title = label
    }
    let hasTrack = arguments["hasTrack"] as? Bool ?? false
    let isPlaying = arguments["isPlaying"] as? Bool ?? false
    playbackMenuHasState = true
    playbackMenuHasTrack = hasTrack
    playbackMenuIsPlaying = isPlaying
    updatePlaybackMenuEnabled()
  }

  private func updatePlaybackMenuEnabled() {
    let enabled = playbackMenuHasState && playbackMenuHasTrack
    playPauseMenuItem?.isEnabled = enabled
    previousMenuItem?.isEnabled = enabled
    nextMenuItem?.isEnabled = enabled
  }

  @objc private func handlePlayPause() {
    playbackChannel?.invokeMethod("togglePlayPause", arguments: nil)
  }

  @objc private func handlePrevious() {
    playbackChannel?.invokeMethod("previousTrack", arguments: nil)
  }

  @objc private func handleNext() {
    playbackChannel?.invokeMethod("nextTrack", arguments: nil)
  }

  private func mainFlutterViewController() -> FlutterViewController? {
    return NSApp.windows
      .compactMap({ $0.contentViewController as? FlutterViewController })
      .first
  }
}
