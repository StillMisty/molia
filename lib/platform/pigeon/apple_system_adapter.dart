import 'dart:io' show Platform;

import 'apple_system.g.dart' as pigeon;

/// Apple 纯查询的薄适配器（ADR-0038 阶段 3）。
///
/// 只做平台守卫与失败降级：iOS / macOS 走 Pigeon 生成的 Swift host，
/// 其它平台返回空 / null。业务层（services）只消费本适配器，不直接碰
/// 生成代码或 Swift 通道名。
class AppleSystemAdapter {
  AppleSystemAdapter({pigeon.AppleSystemHost? host, bool? supported})
    : _host = host ?? pigeon.AppleSystemHost(),
      _supported = supported ?? (Platform.isIOS || Platform.isMacOS);

  final pigeon.AppleSystemHost _host;
  final bool _supported;

  /// 当前平台是否走 Apple host（测试可强制 true 覆盖 Pigeon 映射）。
  bool get supported => _supported;

  /// 设备字体族；非 Apple 平台 / 查询失败返回空列表。
  Future<List<String>> listFontFamilies() async {
    if (!_supported) return const <String>[];
    try {
      return await _host.listFontFamilies();
    } catch (_) {
      return const <String>[];
    }
  }

  /// 电池 / 省电模式；非 Apple 平台 / 查询失败返回 null（调用方按未知处理）。
  Future<({int level, bool charging, bool powerSave})?>
  readBatterySnapshot() async {
    if (!_supported) return null;
    try {
      final snapshot = await _host.readBatterySnapshot();
      return (
        level: snapshot.level ?? -1,
        charging: snapshot.charging ?? false,
        powerSave: snapshot.powerSave ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}
