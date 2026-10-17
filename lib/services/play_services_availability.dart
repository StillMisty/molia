import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Google Play 服务可用性探测（扫码入口门控用）。
///
/// - Android：自有通道（`top.stillmisty.molia/play_services`，原生
///   `GoogleApiAvailability.isGooglePlayServicesAvailable == SUCCESS`）——
///   unbundled ML Kit 的识别模型由 Play 服务下载，无 GMS 的设备不给扫码入口；
/// - iOS：恒为 true（扫码走系统 Vision/AVFoundation，不需要 GMS）；
/// - 桌面三平台：恒为 false（桌面不构建扫码入口，即便构建也没有 ML Kit 实现）。
///
/// 缓存语义：true 在会话内缓存（一次运行里 GMS 不会消失）；**false 不缓存**
/// ——用户可能在会话中安装 / 启用 Play 服务，重开添加设备弹层应能出现入口。
class PlayServicesAvailability {
  PlayServicesAvailability._();

  static const MethodChannel _channel =
      MethodChannel('top.stillmisty.molia/play_services');

  /// 通道探测超时：GMS 查询本身是同步的，这里只兜「通道无响应」。
  static const Duration probeTimeout = Duration(seconds: 2);

  /// 测试注入：覆盖平台判定与通道探测（不触达平台通道）。
  @visibleForTesting
  static Future<bool> Function()? debugOverride;

  static bool _availableThisSession = false;

  /// 当前环境是否可用（见类文档的平台语义与缓存规则）。
  static Future<bool> isAvailable() async {
    final override = debugOverride;
    if (override != null) return override();
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => true,
      TargetPlatform.android => _probeAndroid(),
      _ => false,
    };
  }

  static Future<bool> _probeAndroid() async {
    if (_availableThisSession) return true;
    try {
      final value = await _channel
          .invokeMethod<bool>('isAvailable')
          .timeout(probeTimeout);
      final available = value ?? false;
      if (available) _availableThisSession = true;
      return available;
    } catch (_) {
      // 通道缺失（旧原生版本 / 测试）/ 超时 / 平台异常：按不可用处理，
      // 最坏结果是少一个可选入口，不给用户死胡同。
      return false;
    }
  }

  /// 清会话缓存（测试；或将来需要重新探测的入口）。
  @visibleForTesting
  static void resetCache() => _availableThisSession = false;
}
