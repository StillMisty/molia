/// 同步面的底栏提示出口：统一走 [NotificationService]（内部 = `M3ESnackbar`）。
///
/// 为什么单独成文件：同步页、配对流程与传输弹层三处都要弹提示，而
/// `NotificationService` 挂在应用根（`provider_tree`），提示固定出现在窗口
/// 底栏——不随设置弹层 / 嵌套 Navigator 的层级变化，也不依赖 `ScaffoldMessenger`
/// 的 context 位置（见 `notification_service.dart` 的说明）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../utils/device_id.dart';

/// 弹一条同步面提示。[isError] 只影响时长与语义（M3E 的 snack 不按级别改色）。
void showSyncNotice(
  BuildContext context,
  String message, {
  bool isError = false,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  // 可空读取：测试与未接线场景下没有提示出口（提示静默丢弃，不抛异常）。
  final notifications = context.read<NotificationService?>();
  if (notifications == null) return;
  if (isError) {
    notifications.showErrorSnackBar(
      message,
      actionLabel: actionLabel,
      onActionPressed: onAction,
    );
    return;
  }
  notifications.showSnackBar(
    message,
    actionLabel: actionLabel,
    onActionPressed: onAction,
  );
}

/// 弹层用：先取好提示出口再关弹层（`pop` 之后弹层 context 已失效）。
void showSyncNoticeAndClose(BuildContext context, String message) {
  final notifications = context.read<NotificationService?>();
  Navigator.of(context, rootNavigator: true).pop();
  notifications?.showSnackBar(message);
}

/// 「已与『设备』连通」提示（应用壳收到 `SyncProvider.peerConnectedNotices`
/// 时调用；每台设备只会在第一次真正交换数据后触发一次）。
///
/// [hostContext] 必须是 MaterialApp 之下的 context（本地化要它）——应用壳在
/// MaterialApp 之上，传 `navigatorKey.currentContext`；名称缺失时用短设备 id
/// 兜底，不把内部 id 全量暴露在提示里。
void showSyncPeerConnectedNotice(BuildContext hostContext, SyncPeerState peer) {
  final l10n = AppLocalizations.of(hostContext);
  if (l10n == null) return;
  final name =
      peer.name.trim().isEmpty ? shortDeviceId(peer.deviceId) : peer.name.trim();
  showSyncNotice(hostContext, l10n.syncPeerConnected(name));
}
