import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../platform/android/system_interop_adapter.dart' as android_interop;
import '../platform/pigeon/apple_system_adapter.dart' as apple_interop;

/// 电池状态快照（探针输出）。
///
/// [level] 为百分比（0–100），-1 = 未知（桌面平台未实现 / 读取失败）。
/// macOS 没有电池读取的统一来源，`level` 恒为 -1；系统省电模式在
/// iOS / macOS 都可用。
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

/// 电池探针：Android 优先走 JNI，Apple 走 Pigeon，其余平台回退平台通道。
///
/// 平台实现：Android（Kotlin `SystemInterop`，通道 handler 委托同一对象）、
/// iOS / macOS（Pigeon `AppleSystemHost`）；其余平台没有实现，调用返回
/// [BatterySnapshot.unknown]（探针失败一律按「未知」处理，调度器不会因此
/// 误判省电等级）。
class BatteryProbe {
  BatteryProbe({
    MethodChannel? channel,
    apple_interop.AppleSystemAdapter? apple,
  }) : _channel =
           channel ?? const MethodChannel('top.stillmisty.molia/battery'),
       _apple = apple ?? apple_interop.AppleSystemAdapter();

  final MethodChannel _channel;
  final apple_interop.AppleSystemAdapter _apple;
  final Logger _logger = Logger('molia.battery');

  Future<BatterySnapshot> read() async {
    // Android：JNI 直连同一个 Kotlin 对象，不经通道序列化；失败（类未加载 /
    // 未初始化 / JNI 异常）时仍走下面的通道，保持旧行为不变。
    if (Platform.isAndroid) {
      final snapshot = android_interop.readBatterySnapshot();
      if (snapshot != null) {
        return BatterySnapshot(
          level: snapshot.level,
          charging: snapshot.charging,
          powerSave: snapshot.powerSave,
        );
      }
    }
    // Apple：Pigeon Swift host；失败按未知处理，不再回退旧 Map 通道。
    if (_apple.supported) {
      final snapshot = await _apple.readBatterySnapshot();
      if (snapshot == null) return BatterySnapshot.unknown;
      return BatterySnapshot(
        level: snapshot.level,
        charging: snapshot.charging,
        powerSave: snapshot.powerSave,
      );
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'snapshot',
      );
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
