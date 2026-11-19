import Flutter
import UIKit

/// Pigeon `AppleSystemHost` 的 iOS 实现（ADR-0038 阶段 3）。
///
/// 纯查询：字体族来自 `UIFont.familyNames`，电池与省电模式来自 UIKit /
/// `ProcessInfo`。失败时 Pigeon 会把错误回给 Dart，Dart 侧统一按空 / 未知降级。
final class AppleSystemHostImpl: AppleSystemHost {
  func listFontFamilies() throws -> [String] {
    return UIFont.familyNames.sorted()
  }

  func readBatterySnapshot() throws -> BatterySnapshotMessage {
    UIDevice.current.isBatteryMonitoringEnabled = true
    let level = UIDevice.current.batteryLevel
    let state = UIDevice.current.batteryState
    var snapshot = BatterySnapshotMessage()
    snapshot.level = level < 0 ? -1 : Int64((level * 100).rounded())
    snapshot.charging = state == .charging || state == .full
    snapshot.powerSave = ProcessInfo.processInfo.isLowPowerModeEnabled
    return snapshot
  }
}
