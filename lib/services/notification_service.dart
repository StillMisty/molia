import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 全局提示出口：内部统一走 M3E 反馈组件（`M3ESnackbar`）。
///
/// 注意：`M3ESnackbar.show` 需要能解析到根 Overlay 的 context，而
/// `ScaffoldMessenger` 位于 Navigator 之上（其 context 没有 Overlay 祖先），
/// 因此额外接收 [hostContextKey] —— main.dart 挂在 home 上的 GlobalKey。
/// [scaffoldMessengerKey] 保留以兼容构造签名（当前不再直接展示 material
/// SnackBar）。
class NotificationService {
  NotificationService(
    this.scaffoldMessengerKey, {
    this.hostContextKey,
  });

  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;

  /// 指向 Navigator 之下、可解析根 Overlay 的宿主 context（main.dart 注入）。
  final GlobalKey? hostContextKey;

  /// 通用提示（信息 / 错误）。错误语义通过 [isError] 标记与调用方时长体现；
  /// M3E 的 `M3ESnackbar` 不提供按级别改容器色的 API（统一 inverseSurface），
  /// 原 material 版的 redAccent 底色不再保留（已在迁移报告中记录）。
  void showSnackBar(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 4),
    String? actionLabel,
    VoidCallback? onActionPressed,
  }) {
    final context = hostContextKey?.currentContext;
    if (context == null) {
      return;
    }
    // M3ESnackbar 的默认控制器 present 时替换当前条，
    // 等价于旧的 removeCurrentSnackBar + showSnackBar 组合。
    M3ESnackbar.show(
      context,
      message: message,
      actionLabel: actionLabel,
      onAction: onActionPressed,
      duration: duration,
    );
  }

  void showSuccessSnackBar(String message,
      {Duration duration = const Duration(seconds: 3)}) {
    showSnackBar(message, isError: false, duration: duration);
  }

  void showErrorSnackBar(
      String message,
      {Duration duration = const Duration(seconds: 8),
      String? actionLabel,
      VoidCallback? onActionPressed}) {
    showSnackBar(
      message,
      isError: true,
      duration: duration,
      actionLabel: actionLabel,
      onActionPressed: onActionPressed,
    );
  }
}
