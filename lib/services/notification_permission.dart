import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通知权限状态（Android 13+；其余平台/版本恒为 [granted]）。
enum NotificationPermissionStatus {
  granted,
  denied,

  /// 用户永久拒绝（系统不再弹窗）：只能去系统设置里开。
  permanentlyDenied,

  /// 当前平台没有通知权限概念（非 Android）。
  unsupported,
}

/// 通知权限门面：请求时机由业务决定（首次真正播放 / 首次开启歌词输出），
/// 不在冷启动时弹窗；被拒绝时提供系统「应用通知设置」深链。
///
/// 媒体通知本身豁免 `POST_NOTIFICATIONS`（媒体会话控制卡），但部分 ROM 在
/// 缺权限时仍不展示通知 / 前台服务通知会被限制，所以播放链路要有这条入口。
class NotificationPermission {
  NotificationPermission._();

  static const MethodChannel _channel =
      MethodChannel('top.stillmisty.molia/notifications');

  /// 每个会话至多请求一次（用户拒绝后反复弹窗属骚扰）。
  static bool _requestedThisSession = false;

  static bool get _isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;

  /// 查询当前状态（不弹窗）。
  static Future<NotificationPermissionStatus> status() async {
    if (!_isAndroid) return NotificationPermissionStatus.unsupported;
    return _invoke('permissionStatus');
  }

  /// 首次调用触发系统权限弹窗（每个会话至多一次）；返回请求后的状态。
  ///
  /// 已在本次会话请求过、或已被永久拒绝时不弹窗，只回报当前状态。
  static Future<NotificationPermissionStatus> ensureRequested() async {
    if (!_isAndroid) return NotificationPermissionStatus.unsupported;
    if (_requestedThisSession) return status();
    _requestedThisSession = true;
    return _invoke('requestPermission');
  }

  /// 打开系统「应用通知设置」页（用户在此可重新开启通知）。
  static Future<void> openSettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('openNotificationSettings');
    } catch (_) {
      // 打不开设置页只损失一个入口，不影响播放。
    }
  }

  static Future<NotificationPermissionStatus> _invoke(String method) async {
    try {
      final value = await _channel.invokeMethod<String>(method);
      return _parse(value);
    } catch (_) {
      // 通道缺失（测试 / 旧版本）按不支持处理，不阻塞业务。
      return NotificationPermissionStatus.unsupported;
    }
  }

  static NotificationPermissionStatus _parse(String? value) => switch (value) {
        'granted' => NotificationPermissionStatus.granted,
        'denied' => NotificationPermissionStatus.denied,
        'permanentlyDenied' => NotificationPermissionStatus.permanentlyDenied,
        _ => NotificationPermissionStatus.unsupported,
      };
}
