import 'package:material_ui/material_ui.dart';

import '../domain/models/device_sync.dart';
import '../l10n/app_localizations.dart';

/// 同步观测面的文案映射（结论 / 失败原因 / 触发原因；设置页与子页共用）。
///
/// [SyncIssue.detail]（原始异常 / 错误串）不参与展示：它只出现在日志与
/// 「复制诊断信息」导出里；英文界面与不可读的 `$e` 都在这里被隔离。
String syncIssueText(AppLocalizations l10n, SyncIssue issue) {
  final peer = _stringArg(issue, 'peer', fallback: l10n.syncPeerUnknown);
  final count = _intArg(issue, 'count');
  return switch (issue.code) {
    SyncIssueCode.notConfigured => l10n.syncIssueNotConfigured,
    SyncIssueCode.startFailed => l10n.syncIssueStartFailed,
    SyncIssueCode.permissionDenied => l10n.syncIssuePermissionDenied,
    SyncIssueCode.noPassphrase => l10n.syncIssueNoPassphrase,
    SyncIssueCode.allPeersUnreachable => l10n.syncIssueAllPeersUnreachable,
    SyncIssueCode.pullFailed => l10n.syncIssuePullFailed,
    SyncIssueCode.pushFailed => l10n.syncIssuePushFailed,
    SyncIssueCode.applyFailed => l10n.syncIssueApplyFailed(count),
    SyncIssueCode.peerReadFailed => l10n.syncIssuePeerReadFailed(peer),
    SyncIssueCode.peerDecryptFailed => l10n.syncIssuePeerDecryptFailed(peer),
    SyncIssueCode.peerPushFailed => l10n.syncIssuePeerPushFailed(peer),
    SyncIssueCode.broadcastUnavailable => l10n.syncIssueBroadcastUnavailable,
    SyncIssueCode.discoverySilent => l10n.syncIssueDiscoverySilent,
    SyncIssueCode.webdavDirFailed => l10n.syncIssueWebdavDirFailed,
    SyncIssueCode.webdavListFailed => l10n.syncIssueWebdavListFailed,
    SyncIssueCode.webdavReadFailed => l10n.syncIssueWebdavReadFailed(peer),
    SyncIssueCode.webdavDecryptFailed => l10n.syncIssueWebdavDecryptFailed(peer),
    SyncIssueCode.webdavUploadFailed => l10n.syncIssueWebdavUploadFailed,
    SyncIssueCode.deleteRemoteFailed => l10n.syncIssueDeleteRemoteFailed(peer),
    SyncIssueCode.internal => l10n.syncIssueInternal,
    _ => l10n.syncIssueUnknown,
  };
}

/// 五态结论文案。
String syncOutcomeText(AppLocalizations l10n, SyncOutcome? outcome) =>
    switch (outcome) {
      null => l10n.syncNever,
      SyncOutcome.ok => l10n.syncOutcomeOk,
      SyncOutcome.noChanges => l10n.syncOutcomeNoChanges,
      SyncOutcome.noPeers => l10n.syncOutcomeNoPeers,
      SyncOutcome.partial => l10n.syncOutcomePartial,
      SyncOutcome.failed => l10n.syncOutcomeFailed,
    };

/// 五态结论图标：各有形状，颜色只作增强（不靠颜色单独编码状态）。
IconData syncOutcomeIcon(SyncOutcome? outcome) => switch (outcome) {
      null => Icons.sync_problem_rounded,
      SyncOutcome.ok => Icons.check_circle_rounded,
      SyncOutcome.noChanges => Icons.check_circle_outline_rounded,
      SyncOutcome.noPeers => Icons.wifi_tethering_off_rounded,
      SyncOutcome.partial => Icons.error_outline_rounded,
      SyncOutcome.failed => Icons.error_rounded,
    };

String _stringArg(SyncIssue issue, String key, {required String fallback}) {
  final value = issue.args[key];
  if (value is String && value.isNotEmpty) return value;
  return fallback;
}

/// 同步等级文案（观测面：当前等级）。
String syncLevelText(AppLocalizations l10n, SyncLevel? level) => switch (level) {
      null => l10n.syncLevelUnknown,
      SyncLevel.active => l10n.syncLevelActive,
      SyncLevel.idle => l10n.syncLevelIdle,
      SyncLevel.background => l10n.syncLevelBackground,
      SyncLevel.powerSave => l10n.syncLevelPowerSave,
    };

/// 网络类型文案（观测面：是否移动数据）。
String syncNetworkText(AppLocalizations l10n, {required bool onCellular}) =>
    onCellular ? l10n.syncNetworkCellular : l10n.syncNetworkOther;

int _intArg(SyncIssue issue, String key) {
  final value = issue.args[key];
  return value is num ? value.toInt() : 0;
}
