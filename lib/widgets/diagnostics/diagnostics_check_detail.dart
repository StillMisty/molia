import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/diagnostics.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/diagnostics_provider.dart';
import '../../services/notification_service.dart';
import '../settings/settings_tiles.dart';
import 'diagnostics_check_section.dart';
import 'diagnostics_labels.dart';

/// 检查详情弹层：三步 / 单项状态、耗时、类型化失败与可逆恢复动作。
///
/// 不展示原始异常、URL、Cookie；动作只做重新检查、重启音源引擎与跳转设置。
Future<void> showDiagnosticsCheckDetail(
  BuildContext context, {
  required DiagnosticsProvider provider,
  required DiagnosticCheckRow row,
  required VoidCallback onOpenSources,
  required VoidCallback onOpenAccount,
  required VoidCallback onOpenSync,
  required VoidCallback onOpenNotifications,
  required VoidCallback onOpenLogs,
}) {
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  final running = provider.checkResults.value.running;
  return M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.diagnosticsCheckDetailTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, l10n, row),
              const SizedBox(height: 12),
              SettingsSectionCard(
                children: [
                  SettingsInfoTile(
                    icon: Icons.category_rounded,
                    title: l10n.diagnosticsCheckDetailGroup,
                    subtitle: diagnosticGroupLabel(l10n, row.group),
                  ),
                  SettingsInfoTile(
                    icon: Icons.schedule_rounded,
                    title: l10n.diagnosticsCheckDetailTime,
                    subtitle: diagnosticDetailTime(row.steps.values.first.at),
                  ),
                  SettingsInfoTile(
                    icon: Icons.timer_rounded,
                    title: l10n.diagnosticsCheckDetailLatency,
                    subtitle: l10n.diagnosticsLatencyMs(row.latencyMs),
                  ),
                  if (_valueText(l10n, row) case final value?)
                    SettingsInfoTile(
                      icon: Icons.info_outline_rounded,
                      title: l10n.diagnosticsCheckDetailValue,
                      subtitle: value,
                    ),
                  ..._failureTiles(l10n, row),
                ],
              ),
              const SizedBox(height: 12),
              _stepsCard(context, l10n, row),
              const SizedBox(height: 12),
              _actionsCard(
                context,
                l10n,
                navigator: navigator,
                provider: provider,
                row: row,
                running: running,
                onOpenSources: onOpenSources,
                onOpenAccount: onOpenAccount,
                onOpenSync: onOpenSync,
                onOpenNotifications: onOpenNotifications,
                onOpenLogs: onOpenLogs,
              ),
            ],
          ),
        ),
      ),
      actions: [
        M3EButton.text(onPressed: navigator.pop, child: Text(l10n.close)),
      ],
    ),
  );
}

Widget _header(
  BuildContext context,
  AppLocalizations l10n,
  DiagnosticCheckRow row,
) {
  final m3e = M3ETheme.of(context);
  final title = row.isChannel
      ? '${row.channelDisplayName ?? row.channelKey}'
      : diagnosticCheckLabel(l10n, row.id!);
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(
          diagnosticStatusIcon(row.status),
          size: 24,
          color: diagnosticStatusColor(context, row.status),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: m3e.typeScale.titleMedium),
            Text(
              diagnosticStatusText(l10n, row.status),
              style: m3e.typeScale.bodySmall.copyWith(
                color: m3e.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

Widget _stepsCard(
  BuildContext context,
  AppLocalizations l10n,
  DiagnosticCheckRow row,
) {
  final services = [
    if (row.isChannel)
      for (final id in const [
        DiagnosticCheckId.channelSearch,
        DiagnosticCheckId.channelResolve,
        DiagnosticCheckId.channelStream,
      ])
        (id: id, result: row.step(id))
    else
      (id: row.id!, result: row.steps[row.id!]),
  ];
  return SettingsSectionCard(
    title: row.isChannel
        ? l10n.diagnosticsCheckDetailSteps
        : l10n.diagnosticsCheckDetailStatus,
    children: [
      for (final service in services)
        SettingsInfoTile(
          icon: diagnosticStatusIcon(
            service.result?.status ?? DiagnosticCheckStatus.skipped,
          ),
          title: diagnosticCheckLabel(l10n, service.id),
          subtitle: service.result == null
              ? l10n.diagnosticsStatusSkipped
              : [
                  diagnosticStatusText(l10n, service.result!.status),
                  l10n.diagnosticsLatencyMs(service.result!.latencyMs),
                ].join(' · '),
        ),
    ],
  );
}

List<Widget> _failureTiles(AppLocalizations l10n, DiagnosticCheckRow row) {
  final failure = diagnosticRowFailure(row);
  if (failure == null) return const [];
  return [
    SettingsInfoTile(
      icon: Icons.error_outline_rounded,
      title: l10n.diagnosticsCheckDetailFailure,
      subtitle: [
        diagnosticFailureReason(l10n, failure.kind),
        failure.failure.retryable
            ? l10n.diagnosticsIssueRetryable
            : l10n.diagnosticsIssueNotRetryable,
      ].join(' · '),
    ),
  ];
}

String? _valueText(AppLocalizations l10n, DiagnosticCheckRow row) {
  for (final result in row.steps.values) {
    final value = diagnosticStableValueText(l10n, result);
    if (value != null) return value;
  }
  return null;
}

Widget _actionsCard(
  BuildContext context,
  AppLocalizations l10n, {
  required NavigatorState navigator,
  required DiagnosticsProvider provider,
  required DiagnosticCheckRow row,
  required bool running,
  required VoidCallback onOpenSources,
  required VoidCallback onOpenAccount,
  required VoidCallback onOpenSync,
  required VoidCallback onOpenNotifications,
  required VoidCallback onOpenLogs,
}) {
  final id = row.id;
  final sourceRelated =
      row.isChannel ||
      id == DiagnosticCheckId.sourceEngine ||
      id == DiagnosticCheckId.channelSearch;
  return SettingsSectionCard(
    children: [
      _actionRow(
        context,
        key: const Key('diagnosticsCheckRetry'),
        icon: Icons.refresh_rounded,
        title: l10n.diagnosticsActionRetryCheck,
        subtitle: l10n.diagnosticsActionRetryCheckHint,
        onTap: running
            ? null
            : () => _closeThen(
                navigator,
                () => unawaited(provider.startChecks()),
              ),
      ),
      if (sourceRelated)
        _actionRow(
          context,
          key: const Key('diagnosticsCheckRestartEngine'),
          icon: Icons.restart_alt_rounded,
          title: l10n.diagnosticsActionRestartEngine,
          subtitle: l10n.diagnosticsActionRestartEngineHint,
          onTap: () => _restartEngine(context, provider, l10n),
        ),
      if (sourceRelated)
        _actionRow(
          context,
          key: const Key('diagnosticsCheckOpenSources'),
          icon: Icons.library_music_rounded,
          title: l10n.diagnosticsActionOpenSources,
          subtitle: l10n.diagnosticsActionOpenSourcesHint,
          onTap: () => _closeThen(navigator, onOpenSources),
        ),
      if (id == DiagnosticCheckId.biliAccount)
        _actionRow(
          context,
          key: const Key('diagnosticsCheckOpenAccount'),
          icon: Icons.person_rounded,
          title: l10n.diagnosticsActionOpenAccount,
          subtitle: l10n.diagnosticsActionOpenAccountHint,
          onTap: () => _closeThen(navigator, onOpenAccount),
        ),
      if (id == DiagnosticCheckId.syncTransport)
        _actionRow(
          context,
          key: const Key('diagnosticsCheckOpenSync'),
          icon: Icons.sync_rounded,
          title: l10n.diagnosticsActionOpenSync,
          subtitle: l10n.diagnosticsActionOpenSyncHint,
          onTap: () => _closeThen(navigator, onOpenSync),
        ),
      if (id == DiagnosticCheckId.notificationPermission)
        _actionRow(
          context,
          key: const Key('diagnosticsCheckOpenNotifications'),
          icon: Icons.notifications_rounded,
          title: l10n.diagnosticsActionOpenNotifications,
          subtitle: l10n.diagnosticsActionOpenNotificationsHint,
          onTap: () => _closeThen(navigator, onOpenNotifications),
        ),
      if (id == DiagnosticCheckId.logWrite ||
          id == DiagnosticCheckId.sessionExit)
        _actionRow(
          context,
          key: const Key('diagnosticsCheckOpenLogs'),
          icon: Icons.receipt_long_rounded,
          title: l10n.diagnosticsActionOpenLogs,
          subtitle: l10n.diagnosticsActionOpenLogsHint,
          onTap: () => _closeThen(navigator, onOpenLogs),
        ),
      _actionRow(
        context,
        key: const Key('diagnosticsCheckCopyDetails'),
        icon: Icons.content_copy_rounded,
        title: l10n.diagnosticsActionCopyDetails,
        subtitle: l10n.diagnosticsActionCopyDetailsHint,
        onTap: () => _copyDetails(context, provider, l10n, row),
      ),
    ],
  );
}

Widget _actionRow(
  BuildContext context, {
  required Key key,
  required IconData icon,
  required String title,
  required String subtitle,
  required VoidCallback? onTap,
}) {
  return SettingsTileRow(
    key: key,
    icon: icon,
    title: title,
    subtitle: subtitle,
    onPressed: onTap,
  );
}

void _closeThen(NavigatorState navigator, VoidCallback action) {
  navigator.pop();
  action();
}

Future<void> _restartEngine(
  BuildContext context,
  DiagnosticsProvider provider,
  AppLocalizations l10n,
) async {
  final notifications = context.read<NotificationService?>();
  final ok = await provider.restartSourceEngine();
  notifications?.showSnackBar(
    ok ? l10n.diagnosticsEngineRestarted : l10n.diagnosticsEngineRestartFailed,
    isError: !ok,
  );
}

Future<void> _copyDetails(
  BuildContext context,
  DiagnosticsProvider provider,
  AppLocalizations l10n,
  DiagnosticCheckRow row,
) async {
  final notifications = context.read<NotificationService?>();
  final text = _detailsText(l10n, row);
  final ok = await provider.copyPlainText(text);
  notifications?.showSnackBar(
    ok ? l10n.diagnosticsActionCopied : l10n.diagnosticsActionCopyFailed,
    isError: !ok,
  );
}

String _detailsText(AppLocalizations l10n, DiagnosticCheckRow row) {
  final title = row.isChannel
      ? '${row.channelDisplayName ?? row.channelKey}'
      : diagnosticCheckLabel(l10n, row.id!);
  final lines = <String>[
    title,
    '${l10n.diagnosticsCheckDetailGroup}: '
        '${diagnosticGroupLabel(l10n, row.group)}',
    '${l10n.diagnosticsCheckDetailStatus}: '
        '${diagnosticStatusText(l10n, row.status)}',
    '${l10n.diagnosticsCheckDetailLatency}: '
        '${l10n.diagnosticsLatencyMs(row.latencyMs)}',
  ];
  final service = row.id;
  if (service != null) {
    final value = _valueText(l10n, row);
    if (value != null) {
      lines.add('${l10n.diagnosticsCheckDetailValue}: $value');
    }
  }
  final failure = diagnosticRowFailure(row);
  if (failure != null) {
    lines.add(
      '${l10n.diagnosticsCheckDetailFailure}: '
      '${diagnosticFailureReason(l10n, failure.kind)}',
    );
  }
  return lines.join('\n');
}
