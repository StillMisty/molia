/// 问题排查各分区共用的文案映射：状态、检查项、稳定短值与问题建议。
///
/// 这一层只做「类型化事实 → 用户文案」，不读取服务、不拼报告；页面与详情
/// 弹层共用同一份映射，避免同一状态在不同卡片里换说法。
library;

import 'package:intl/intl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/diagnostics.dart';
import '../../domain/models/failure.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_semantic_colors.dart';

final DateFormat _shortTimeFormat = DateFormat('MM-dd HH:mm');
final DateFormat _detailTimeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

String diagnosticShortTime(DateTime time) => _shortTimeFormat.format(time);

String diagnosticDetailTime(DateTime time) => _detailTimeFormat.format(time);

String diagnosticStatusText(
  AppLocalizations l10n,
  DiagnosticCheckStatus status,
) => switch (status) {
  DiagnosticCheckStatus.ok => l10n.diagnosticsStatusOk,
  DiagnosticCheckStatus.warning => l10n.diagnosticsStatusWarning,
  DiagnosticCheckStatus.failed => l10n.diagnosticsStatusFailed,
  DiagnosticCheckStatus.skipped => l10n.diagnosticsStatusSkipped,
};

IconData diagnosticStatusIcon(DiagnosticCheckStatus status) => switch (status) {
  DiagnosticCheckStatus.ok => Icons.check_circle_outline_rounded,
  DiagnosticCheckStatus.warning => Icons.warning_amber_rounded,
  DiagnosticCheckStatus.failed => Icons.error_outline_rounded,
  DiagnosticCheckStatus.skipped => Icons.remove_circle_outline_rounded,
};

/// 状态色只用现有语义 / M3E 角色：失败 error、警告 warning、正常 success。
Color diagnosticStatusColor(
  BuildContext context,
  DiagnosticCheckStatus status,
) {
  final semantic = AppSemanticColors.of(context);
  return switch (status) {
    DiagnosticCheckStatus.ok => semantic.success,
    DiagnosticCheckStatus.warning => semantic.warning,
    DiagnosticCheckStatus.failed => M3ETheme.of(context).colorScheme.error,
    DiagnosticCheckStatus.skipped => M3ETheme.of(
      context,
    ).colorScheme.onSurfaceVariant,
  };
}

String diagnosticGroupLabel(
  AppLocalizations l10n,
  DiagnosticCheckGroup group,
) => switch (group) {
  DiagnosticCheckGroup.app => l10n.diagnosticsGroupApp,
  DiagnosticCheckGroup.sources => l10n.diagnosticsGroupSources,
  DiagnosticCheckGroup.playback => l10n.diagnosticsGroupPlayback,
  DiagnosticCheckGroup.storage => l10n.diagnosticsGroupStorage,
  DiagnosticCheckGroup.sync => l10n.diagnosticsGroupSync,
};

String diagnosticCheckLabel(
  AppLocalizations l10n,
  DiagnosticCheckId id,
) => switch (id) {
  DiagnosticCheckId.appVersion => l10n.diagnosticsCheckAppVersion,
  DiagnosticCheckId.sessionExit => l10n.diagnosticsCheckSessionExit,
  DiagnosticCheckId.notificationPermission => l10n.diagnosticsCheckNotification,
  DiagnosticCheckId.audioBackend => l10n.diagnosticsCheckAudioBackend,
  DiagnosticCheckId.sourceEngine => l10n.diagnosticsCheckSourceEngine,
  DiagnosticCheckId.channelSearch => l10n.diagnosticsChannelSearch,
  DiagnosticCheckId.channelResolve => l10n.diagnosticsChannelResolve,
  DiagnosticCheckId.channelStream => l10n.diagnosticsChannelStream,
  DiagnosticCheckId.logWrite => l10n.diagnosticsCheckLogWrite,
  DiagnosticCheckId.databaseSchema => l10n.diagnosticsCheckDatabaseSchema,
  DiagnosticCheckId.databaseIntegrity => l10n.diagnosticsCheckDatabaseIntegrity,
  DiagnosticCheckId.syncTransport => l10n.diagnosticsCheckSync,
  DiagnosticCheckId.biliAccount => l10n.diagnosticsCheckBiliAccount,
};

String diagnosticFailureReason(AppLocalizations l10n, FailureKind kind) {
  return switch (kind) {
    FailureKind.network => l10n.diagnosticsFailureNetwork,
    FailureKind.timeout => l10n.diagnosticsFailureTimeout,
    FailureKind.unsupported => l10n.diagnosticsFailureUnsupported,
    FailureKind.notFound => l10n.diagnosticsFailureNotFound,
    FailureKind.unauthorized => l10n.diagnosticsFailureUnauthorized,
    FailureKind.rateLimited => l10n.diagnosticsFailureRateLimited,
    FailureKind.scriptError => l10n.diagnosticsFailureScript,
    FailureKind.engineRestarting => l10n.diagnosticsFailureEngineRestarting,
    FailureKind.cancelled => l10n.diagnosticsFailureCancelled,
    FailureKind.playback => l10n.diagnosticsFailurePlayback,
    FailureKind.unknown => l10n.diagnosticsFailureUnknown,
  };
}

String diagnosticIssueSuggestion(AppLocalizations l10n, FailureKind kind) =>
    switch (kind) {
      FailureKind.network => l10n.diagnosticsIssueSuggestionNetwork,
      FailureKind.timeout => l10n.diagnosticsIssueSuggestionTimeout,
      FailureKind.unsupported => l10n.diagnosticsIssueSuggestionUnsupported,
      FailureKind.notFound => l10n.diagnosticsIssueSuggestionNotFound,
      FailureKind.unauthorized => l10n.diagnosticsIssueSuggestionUnauthorized,
      FailureKind.rateLimited => l10n.diagnosticsIssueSuggestionRateLimited,
      FailureKind.scriptError => l10n.diagnosticsIssueSuggestionScript,
      FailureKind.engineRestarting =>
        l10n.diagnosticsIssueSuggestionEngineRestarting,
      FailureKind.cancelled => l10n.diagnosticsIssueSuggestionCancelled,
      FailureKind.playback => l10n.diagnosticsIssueSuggestionPlayback,
      FailureKind.unknown => l10n.diagnosticsIssueSuggestionUnknown,
    };

/// 稳定短值 → 普通文案；跳过项里没有登记的内部字符串不直接展示。
String? diagnosticStableValueText(
  AppLocalizations l10n,
  DiagnosticCheckResult result,
) {
  final value = result.stableValue;
  if (value == null || value.isEmpty) return null;
  final known = switch (value) {
    'unknown' => l10n.diagnosticsStableUnknown,
    'abnormal' => l10n.diagnosticsStableAbnormal,
    'clean' => l10n.diagnosticsStableClean,
    'available' => l10n.diagnosticsStableAvailable,
    'unavailable' => l10n.diagnosticsStableUnavailable,
    'not_desktop' => l10n.diagnosticsStableNotDesktop,
    'no_script' => l10n.diagnosticsStableNoScript,
    'recording' => l10n.diagnosticsStableRecording,
    'stopped' => l10n.diagnosticsStableStopped,
    'unreadable' => l10n.diagnosticsStableUnreadable,
    'ok' => l10n.diagnosticsStableOk,
    'corrupt' => l10n.diagnosticsStableCorrupt,
    'off' => l10n.diagnosticsStableOff,
    'none' => l10n.diagnosticsStableNone,
    'logged_out' => l10n.diagnosticsStableLoggedOut,
    'expired' => l10n.diagnosticsStableExpired,
    'logged_in' => l10n.diagnosticsStableLoggedIn,
    'cooldown' => l10n.diagnosticsStableCooldown,
    'no_channels' => l10n.diagnosticsStableNoChannels,
    'timeout' => l10n.diagnosticsStableTimeout,
    'granted' => l10n.diagnosticsStableGranted,
    'denied' => l10n.diagnosticsStableDenied,
    'permanentlyDenied' => l10n.diagnosticsStablePermanentlyDenied,
    'unsupported' => l10n.diagnosticsStableUnsupported,
    _ => null,
  };
  if (known != null) return known;

  return switch (result.id) {
    DiagnosticCheckId.appVersion => l10n.diagnosticsStableVersion(value),
    DiagnosticCheckId.sourceEngine => l10n.diagnosticsStableScript(value),
    DiagnosticCheckId.databaseSchema => _schemaValue(l10n, value),
    DiagnosticCheckId.syncTransport => _syncValue(l10n, value),
    _ => result.status == DiagnosticCheckStatus.skipped ? null : value,
  };
}

String _schemaValue(AppLocalizations l10n, String value) {
  final parts = value.split('/');
  if (parts.length == 2) {
    return l10n.diagnosticsStableSchemaMismatch(parts[0], parts[1]);
  }
  return l10n.diagnosticsStableSchema(value);
}

String _syncValue(AppLocalizations l10n, String value) {
  final transports = <String>[];
  for (final entry in value.split(',')) {
    if (entry.isEmpty) continue;
    final separator = entry.indexOf(':');
    if (separator <= 0 || separator == entry.length - 1) {
      transports.add(entry);
      continue;
    }
    final name = _transportName(l10n, entry.substring(0, separator));
    final state = _transportState(l10n, entry.substring(separator + 1));
    transports.add(l10n.diagnosticsSyncTransport(name, state));
  }
  return transports.isEmpty ? value : transports.join(' · ');
}

String _transportName(AppLocalizations l10n, String name) => switch (name) {
  'webdav' => l10n.diagnosticsTransportWebdav,
  'lan' => l10n.diagnosticsTransportLan,
  _ => name,
};

String _transportState(AppLocalizations l10n, String state) => switch (state) {
  'ok' => l10n.diagnosticsTransportOk,
  'stopped' => l10n.diagnosticsTransportStopped,
  'permissionDenied' => l10n.diagnosticsTransportPermissionDenied,
  _ => l10n.diagnosticsTransportUnavailable,
};

/// 日志级别徽标文案；未知级别不直接显示内部枚举名。
String diagnosticLogLevelText(AppLocalizations l10n, String level) {
  return switch (level.toUpperCase()) {
    'FINEST' || 'FINER' || 'FINE' || 'CONFIG' => l10n.diagnosticsLogsLevelDebug,
    'INFO' => l10n.diagnosticsLogsLevelInfo,
    'WARNING' => l10n.diagnosticsLogsLevelWarningBadge,
    'SEVERE' || 'SHOUT' => l10n.diagnosticsLogsLevelError,
    _ => l10n.diagnosticsLogsLevelOther,
  };
}

Color diagnosticLogLevelColor(BuildContext context, String level) {
  final upper = level.toUpperCase();
  if (upper == 'SEVERE' || upper == 'SHOUT') {
    return M3ETheme.of(context).colorScheme.error;
  }
  if (upper == 'WARNING') return AppSemanticColors.of(context).warning;
  return M3ETheme.of(context).colorScheme.onSurfaceVariant;
}

String diagnosticDurationText(AppLocalizations l10n, Duration duration) {
  if (duration.inMinutes < 1) return l10n.diagnosticsDurationLessThanMinute;
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) return l10n.diagnosticsDurationMinutes(minutes);
  return l10n.diagnosticsDurationHoursMinutes(hours, minutes);
}
