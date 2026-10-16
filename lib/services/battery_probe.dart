import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// 电池状态快照（探针输出）。
///
/// [level] 为百分比（0–100），-1 = 未知（桌面平台未实现 / 读取失败）。
/// 桌面端没有系统省电模式与充电状态的统一来源，`powerSave` 恒为 false。
class BatterySnapshot {
  const BatterySnapshot({
    this.level = -1,
    this.charging = false,
    this.powerSave = false,
  });

  final int level;
  final bool charging;

  /// 系统省电模式（Android `PowerManager.isPowerSaveMode` /
  /// iOS `isLowPowerModeEnabled`）。
  final bool powerSave;

  static const BatterySnapshot unknown = BatterySnapshot();
}

/// 电池探针：经平台通道读电量 / 充电状态 / 系统省电模式。
///
/// 平台实现：Android（`BatteryChannelHandler`）与 iOS（`AppDelegate`）；
/// 其余平台没有实现，调用返回 [BatterySnapshot.unknown]（探针失败一律按
/// 「未知」处理，调度器不会因此误判省电等级）。
class BatteryProbe {
  BatteryProbe({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('top.stillmisty.molia/battery');

  final MethodChannel _channel;
  final Logger _logger = Logger('molia.battery');

  Future<BatterySnapshot> read() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('snapshot');
      if (result == null) return BatterySnapshot.unknown;
      return BatterySnapshot(
        level: (result['level'] as num?)?.toInt() ?? -1,
        charging: result['charging'] == true,
        powerSave: result['powerSave'] == true,
      );
    } on MissingPluginException {
      return BatterySnapshot.unknown;
    } catch (error) {
      _logger.fine(() => '电池状态读取失败（按未知处理）: $error');
      return BatterySnapshot.unknown;
    }
  }
}
