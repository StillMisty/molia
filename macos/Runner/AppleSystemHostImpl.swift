import AppKit
import FlutterMacOS

/// Pigeon `AppleSystemHost` 的 macOS 实现（ADR-0038 阶段 3）。
///
/// 字体族来自 `NSFontManager`，与 Flutter macOS 的字体解析同源；桌面没有
/// 电池读取的统一来源，电量 / 充电状态保持未知（-1 / false），但省电模式
/// 仍可读。
final class AppleSystemHostImpl: AppleSystemHost {
  func listFontFamilies() throws -> [String] {
    return NSFontManager.shared.availableFontFamilies.sorted()
  }

  func readBatterySnapshot() throws -> BatterySnapshotMessage {
    var snapshot = BatterySnapshotMessage()
    snapshot.level = -1
    snapshot.charging = false
    snapshot.powerSave = ProcessInfo.processInfo.isLowPowerModeEnabled
    return snapshot
  }
}
