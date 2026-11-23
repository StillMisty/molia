import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/diagnostics.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/diagnostics_provider.dart';
import '../../services/diagnostics/diagnostics_bundle.dart';
import '../../services/notification_service.dart';
import '../../services/save_as.dart';
import '../../widgets/labels/save_as_label.dart';
import '../settings/settings_tiles.dart';
import 'diagnostics_labels.dart';

/// 报告与日志分区：预览 / 复制 / 保存 / 分享 + 日志入口。
class DiagnosticsReportSection extends StatelessWidget {
  const DiagnosticsReportSection({
    super.key,
    required this.provider,
    required this.onPreviewReport,
    required this.onCopyReport,
    required this.onSaveReport,
    required this.onShareReport,
    required this.onOpenLogs,
    required this.onRevealLogs,
  });

  final DiagnosticsProvider provider;
  final VoidCallback onPreviewReport;
  final VoidCallback onCopyReport;
  final VoidCallback onSaveReport;
  final VoidCallback onShareReport;
  final VoidCallback onOpenLogs;
  final VoidCallback onRevealLogs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<DiagnosticsReportState>(
      valueListenable: provider.reportState,
      builder: (context, report, _) {
        return ValueListenableBuilder<DiagnosticsLogsState>(
          valueListenable: provider.logsState,
          builder: (context, logs, _) {
            return ValueListenableBuilder<DiagnosticsAppInfo?>(
              valueListenable: provider.appInfo,
              builder: (context, appInfo, _) {
                final busy = report.busy;
                return SettingsSectionCard(
                  title: l10n.diagnosticsReportSection,
                  footer: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SettingsSectionHint(text: l10n.diagnosticsExportPrivacy),
                      const SizedBox(height: 4),
                      SettingsSectionHint(text: l10n.diagnosticsExportWarning),
                    ],
                  ),
                  children: [
                    if (appInfo != null)
                      SettingsInfoTile(
                        icon: Icons.support_agent_rounded,
                        title: l10n.diagnosticsTitle,
                        subtitle: l10n.diagnosticsAppInfoValue(
                          appInfo.version,
                          appInfo.buildNumber,
                          appInfo.platform,
                        ),
                      ),
                    _actionRow(
                      context,
                      key: const Key('diagnosticsPreviewReport'),
                      icon: Icons.description_rounded,
                      title: l10n.diagnosticsReportPreview,
                      subtitle: l10n.diagnosticsReportPreviewSubtitle,
                      onTap: busy ? null : onPreviewReport,
                    ),
                    _actionRow(
                      context,
                      key: const Key('diagnosticsCopyReport'),
                      icon: Icons.content_copy_rounded,
                      title: l10n.diagnosticsCopyReport,
                      subtitle: l10n.diagnosticsCopyReportSubtitle,
                      onTap: busy ? null : onCopyReport,
                    ),
                    _actionRow(
                      context,
                      key: const Key('diagnosticsSaveReport'),
                      icon: Icons.save_alt_rounded,
                      title: l10n.diagnosticsExportAction,
                      subtitle: l10n.diagnosticsSaveReportSubtitle,
                      onTap: busy ? null : onSaveReport,
                    ),
                    _actionRow(
                      context,
                      key: const Key('diagnosticsShareReport'),
                      icon: Icons.ios_share_rounded,
                      title: l10n.diagnosticsShareReport,
                      subtitle: l10n.diagnosticsShareReportSubtitle,
                      onTap: busy ? null : onShareReport,
                    ),
                    _actionRow(
                      context,
                      key: const Key('diagnosticsViewLogs'),
                      icon: Icons.receipt_long_rounded,
                      title: l10n.diagnosticsLogView,
                      subtitle: _logSubtitle(l10n, logs),
                      onTap: onOpenLogs,
                    ),
                    _actionRow(
                      context,
                      key: const Key('diagnosticsOpenLogDirectory'),
                      icon: Icons.folder_open_rounded,
                      title: l10n.diagnosticsLogsOpenDirectory,
                      subtitle: l10n.diagnosticsLogsOpenDirectoryHint,
                      onTap: onRevealLogs,
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  String _logSubtitle(AppLocalizations l10n, DiagnosticsLogsState logs) {
    final status = switch (logs.logStatus) {
      DiagnosticLogStatus.recording => l10n.diagnosticsLogRecording,
      DiagnosticLogStatus.unavailable => l10n.diagnosticsLogUnavailable,
      DiagnosticLogStatus.stopped => l10n.diagnosticsLogStopped,
    };
    final loadedAt = logs.loadedAt;
    return loadedAt == null
        ? status
        : '$status · ${l10n.diagnosticsIssueLastAt(diagnosticShortTime(loadedAt))}';
  }
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

/// 报告预览弹层：先看脱敏内容，再选择复制 / 保存 / 分享。
Future<void> showDiagnosticsReportSheet(
  BuildContext context, {
  required DiagnosticsProvider provider,
}) {
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  final size = MediaQuery.sizeOf(context);
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final preview = provider.buildReportText(
    screenWidth: size.width,
    screenHeight: size.height,
    devicePixelRatio: dpr,
    maxBytes: diagnosticsReportPreviewMaxBytes,
  );
  return M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.diagnosticsReportSheetTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.diagnosticsReportSheetPrivacy,
              style: M3ETheme.of(context).typeScale.bodySmall.copyWith(
                color: M3ETheme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FutureBuilder<String>(
              future: preview,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: M3EProgressIndicator.circular()),
                  );
                }
                if (snapshot.hasError || !snapshot.hasData) {
                  return Text(l10n.diagnosticsReportUnavailable);
                }
                return _previewBox(context, snapshot.data!);
              },
            ),
            const SizedBox(height: 8),
            SettingsSectionHint(text: l10n.diagnosticsReportPreviewTruncated),
            const SizedBox(height: 16),
            ValueListenableBuilder<DiagnosticsReportState>(
              valueListenable: provider.reportState,
              builder: (context, report, _) {
                final busy = report.busy;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    M3EButton.filled(
                      key: const Key('diagnosticsReportCopy'),
                      enabled: !busy,
                      onPressed: () =>
                          _copy(context, provider, l10n, size, dpr),
                      child: Text(l10n.diagnosticsCopyReport),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: M3EButton.text(
                            key: const Key('diagnosticsReportSave'),
                            enabled: !busy,
                            onPressed: () =>
                                _save(context, provider, l10n, size, dpr),
                            child: Text(l10n.diagnosticsExportAction),
                          ),
                        ),
                        Expanded(
                          child: M3EButton.text(
                            key: const Key('diagnosticsReportShare'),
                            enabled: !busy,
                            onPressed: () =>
                                _share(context, provider, l10n, size, dpr),
                            child: Text(l10n.diagnosticsShareReport),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        M3EButton.text(onPressed: navigator.pop, child: Text(l10n.close)),
      ],
    ),
  );
}

Widget _previewBox(BuildContext context, String text) {
  final m3e = M3ETheme.of(context);
  return Container(
    constraints: const BoxConstraints(maxHeight: 240),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: m3e.colorScheme.surfaceContainerHighest,
      borderRadius: M3EShapes.radiusMedium,
    ),
    child: SingleChildScrollView(
      child: Text(text, style: m3e.typeScale.bodySmall),
    ),
  );
}

Future<void> _copy(
  BuildContext context,
  DiagnosticsProvider provider,
  AppLocalizations l10n,
  Size size,
  double dpr,
) async {
  final notifications = context.read<NotificationService?>();
  final ok = await provider.copyReport(
    screenWidth: size.width,
    screenHeight: size.height,
    devicePixelRatio: dpr,
  );
  notifications?.showSnackBar(
    ok ? l10n.diagnosticsReportCopied : l10n.diagnosticsReportCopyFailed,
    isError: !ok,
  );
}

Future<void> _save(
  BuildContext context,
  DiagnosticsProvider provider,
  AppLocalizations l10n,
  Size size,
  double dpr,
) async {
  final notifications = context.read<NotificationService?>();
  final result = await provider.saveReport(
    dialogTitle: l10n.diagnosticsExportAction,
    screenWidth: size.width,
    screenHeight: size.height,
    devicePixelRatio: dpr,
  );
  switch (result) {
    case SaveAsSaved(:final displayPath, :final kind):
      notifications?.showSuccessSnackBar(
        savedLocationMessage(l10n, kind, displayPath),
      );
    case SaveAsCancelled():
      return;
    case SaveAsFailed():
      notifications?.showErrorSnackBar(l10n.saveFailed);
  }
}

Future<void> _share(
  BuildContext context,
  DiagnosticsProvider provider,
  AppLocalizations l10n,
  Size size,
  double dpr,
) async {
  final notifications = context.read<NotificationService?>();
  final result = await provider.shareReport(
    screenWidth: size.width,
    screenHeight: size.height,
    devicePixelRatio: dpr,
  );
  switch (result.outcome) {
    case DiagnosticsShareOutcome.shared:
      notifications?.showSuccessSnackBar(l10n.diagnosticsReportShared);
    case DiagnosticsShareOutcome.savedFallback:
      switch (result.saved) {
        case SaveAsSaved(:final displayPath):
          notifications?.showSuccessSnackBar(
            l10n.diagnosticsReportShareFallback(displayPath),
          );
        case SaveAsCancelled():
          return;
        case SaveAsFailed():
        case null:
          notifications?.showErrorSnackBar(l10n.diagnosticsReportShareFailed);
      }
    case DiagnosticsShareOutcome.failed:
      notifications?.showErrorSnackBar(l10n.diagnosticsReportShareFailed);
  }
}
