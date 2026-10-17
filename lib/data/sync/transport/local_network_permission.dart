import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 局域网权限状态：未申请 / 已授予 / 被拒（可再问）/ 永久拒绝。
///
/// 「永久拒绝」与「被拒」必须分开：前者系统不再弹窗，唯一出路是
/// 去系统设置；后者还可以由用户显式再申请一次。
enum LocalNetworkPermissionStatus {
  /// 本会话尚未申请过。
  notRequested,

  granted,

  /// 被拒但系统允许再次申请。
  denied,

  /// 永久拒绝（系统不再弹窗）：只能去系统设置里开。
  permanentlyDenied,
}

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
/// - 永久拒绝时 `ensure` 不再请求（系统不会弹窗），UI 直接给「去系统设置」；
/// - 生产实现走 Android 自有通道（`top.stillmisty.molia/local_network`），
///   不引入权限库：项目只需要这一个 Android 运行时权限，而 `permission_handler`
///   的 Windows 实现会在注册时开启定位会话（上游 #1394）；
/// - 申请 / 查询 / 跳系统设置都经构造注入，单测不触发平台通道。
class LocalNetworkPermission {
  LocalNetworkPermission({
    required this.needsPermission,
    Future<LocalNetworkPermissionStatus> Function()? request,
    Future<LocalNetworkPermissionStatus> Function()? check,
    Future<void> Function()? openSettings,
  })  : _request = request,
        _check = check,
        _openSettings = openSettings;

  /// 平台通道（Android 原生实现见 `LocalNetworkPermissionChannelHandler.kt`）。
  static const MethodChannel _channel =
      MethodChannel('top.stillmisty.molia/local_network');

  /// 生产实现：Android 走 `ACCESS_LOCAL_NETWORK`，桌面恒定允许。
  factory LocalNetworkPermission.production() {
    final needs = defaultTargetPlatform == TargetPlatform.android;
    return LocalNetworkPermission(
      needsPermission: needs,
      request: () async => _statusOf(
        await _channel.invokeMethod<String>('requestPermission'),
      ),
      check: () async => _statusOf(
        await _channel.invokeMethod<String>('permissionStatus'),
      ),
      openSettings: _openSystemSettings,
    );
  }

  /// 平台通道状态 → 本模块状态（`restricted` 等同永久拒绝：
  /// 系统层面不允许申请；`limited` / `provisional` 视为已授予）。
  static LocalNetworkPermissionStatus _statusOf(String? status) =>
      switch (status) {
        'granted' || 'limited' || 'provisional' =>
          LocalNetworkPermissionStatus.granted,
        'permanentlyDenied' || 'restricted' =>
          LocalNetworkPermissionStatus.permanentlyDenied,
        _ => LocalNetworkPermissionStatus.denied,
      };

  static Future<void> _openSystemSettings() async {
    try {
      await _channel.invokeMethod<bool>('openAppSettings');
    } on PlatformException catch (e) {
      debugPrint('[Molia] 打开应用设置失败: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[Molia] 打开应用设置失败: $e');
    }
  }

  /// 本平台是否需要申请（false 时 [granted] 恒为 true）。
  final bool needsPermission;

  final Future<LocalNetworkPermissionStatus> Function()? _request;
  final Future<LocalNetworkPermissionStatus> Function()? _check;
  final Future<void> Function()? _openSettings;

  LocalNetworkPermissionStatus _status =
      LocalNetworkPermissionStatus.notRequested;

  /// 当前状态（不需要权限的平台恒为 [LocalNetworkPermissionStatus.granted]）。
  LocalNetworkPermissionStatus get status =>
      !needsPermission ? LocalNetworkPermissionStatus.granted : _status;

  /// 最近一次已知的授权状态（尚未探测时按「允许」处理，避免误报）。
  bool get granted =>
      !needsPermission ||
      _status == LocalNetworkPermissionStatus.notRequested ||
      _status == LocalNetworkPermissionStatus.granted;

  /// 永久拒绝（系统不再弹窗）：UI 的动作是「去系统设置」而不是再次申请。
  bool get permanentlyDenied =>
      status == LocalNetworkPermissionStatus.permanentlyDenied;

  /// 申请权限（幂等）。
  ///
  /// [retry] = true 表示用户显式请求（「授予权限」按钮），即使本会话已拒过也再问；
  /// 自动路径不会重复弹窗。永久拒绝时不再请求（系统不会弹窗），返回 false。
  Future<bool> ensure({bool retry = false}) async {
    if (!needsPermission) return true;
    if (permanentlyDenied) return false;
    final request = _request;
    if (request == null) return granted;
    if (_status != LocalNetworkPermissionStatus.notRequested && !retry) {
      return granted;
    }
    _status = await request();
    return granted;
  }

  /// 重新查询当前状态（不弹窗）。
  Future<bool> refresh() async {
    if (!needsPermission) return true;
    final check = _check;
    if (check != null) _status = await check();
    return granted;
  }

  /// 跳系统设置（权限被永久拒绝时的唯一出路）。
  Future<void> openSystemSettings() async {
    final open = _openSettings;
    if (open != null) await open();
  }
}
