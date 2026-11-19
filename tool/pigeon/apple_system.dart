import 'package:pigeon/pigeon.dart';

/// Apple 纯查询契约（ADR-0038 阶段 3）。
///
/// 只放不依赖窗口 / 生命周期状态的查询：系统字体族与电池 / 省电模式。
/// Android 对应能力走 JNI（`lib/platform/android/`），不在这里重复。
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/pigeon/apple_system.g.dart',
    dartPackageName: 'molia',
    swiftOut: <String>[
      'ios/Runner/AppleSystemApi.g.swift',
      'macos/Runner/AppleSystemApi.g.swift',
    ],
    swiftOptions: SwiftOptions(),
  ),
)
class BatterySnapshotMessage {
  /// 电量百分比（0–100）；-1 表示当前平台无法读取。
  int? level;

  /// 是否正在充电 / 已充满。
  bool? charging;

  /// 系统省电模式（iOS / macOS `ProcessInfo.isLowPowerModeEnabled`）。
  bool? powerSave;
}

@HostApi()
abstract class AppleSystemHost {
  /// 设备已安装字体族名（去重 / 排序由调用方处理）。
  List<String> listFontFamilies();

  /// 电池 / 省电模式快照；读不到的字段保持 null，由 Dart 侧按未知降级。
  BatterySnapshotMessage readBatterySnapshot();
}
