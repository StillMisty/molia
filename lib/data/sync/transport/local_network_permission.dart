import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// 局域网访问权限门（Android 17 / API 37 起局域网默认阻断，见 ADR-0003 v2 §3）。
///
/// 为什么需要它：`targetSdk 37` 的应用在 Android 17 上访问局域网（含 UDP 单播
/// 与广播、对外 TCP 连接）默认被系统拒绝，Dart socket 直接抛 `SocketException`。
/// 权限被拒时**手动填对端地址也无效**（网关级阻断），只能引导授权或转 WebDAV。
///
/// 设计要点：
/// - 只在需要该权限的平台申请（Android）；其它平台恒为允许；
/// - 一个会话内被拒后不自动重复弹窗（否则每轮同步都弹），
///   用户显式点「授予权限」时走 `ensure(retry: true)`；
/// - 申请 / 查询 / 跳系统设置都经构造注入，单测不触发平台通道。
class LocalNetworkPermission {
  LocalNetworkPermission({
    required this.needsPermission,
    Future<bool> Function()? request,
    Future<bool> Function()? check,
    Future<void> Function()? openSettings,
  })  : _request = request,
        _check = check,
        _openSettings = openSettings;

  /// 生产实现：Android 走 `ACCESS_LOCAL_NETWORK`，Web 与桌面恒定允许。
  factory LocalNetworkPermission.production() {
    final needs = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return LocalNetworkPermission(
      needsPermission: needs,
      request: () async =>
          (await Permission.accessLocalNetwork.request()).isGranted,
      check: () async =>
          (await Permission.accessLocalNetwork.status).isGranted,
      openSettings: () => openAppSettings(),
    );
  }

  /// 本平台是否需要申请（false 时 [granted] 恒为 true）。
  final bool needsPermission;

  final Future<bool> Function()? _request;
  final Future<bool> Function()? _check;
  final Future<void> Function()? _openSettings;

  bool _granted = true;
  bool _asked = false;

  /// 最近一次已知的授权状态（尚未探测时按「允许」处理，避免误报）。
  bool get granted => !needsPermission || _granted;

  /// 本会话内已申请过（用于「拒绝后不再自动弹窗」）。
  bool get askedThisSession => _asked;

  /// 申请权限（幂等）。
  ///
  /// [retry] = true 表示用户显式请求（「授予权限」按钮），即使本会话已拒过也再问；
  /// 自动路径不会重复弹窗。
  Future<bool> ensure({bool retry = false}) async {
    if (!needsPermission) return true;
    final request = _request;
    if (request == null) return granted;
    if (_asked && !retry) return _granted;
    _asked = true;
    _granted = await request();
    return _granted;
  }

  /// 重新查询当前状态（不弹窗）。
  Future<bool> refresh() async {
    if (!needsPermission) return true;
    final check = _check;
    if (check != null) _granted = await check();
    return _granted;
  }

  /// 跳系统设置（权限被永久拒绝时的唯一出路）。
  Future<void> openSystemSettings() async {
    final open = _openSettings;
    if (open != null) await open();
  }
}
