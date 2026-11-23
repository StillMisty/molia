import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../providers/app_providers.dart';
import '../providers/diagnostics_provider.dart';
import '../services/notification_permission.dart';
import '../services/save_as.dart';
import '../widgets/diagnostics/diagnostics_check_detail.dart';
import '../widgets/diagnostics/diagnostics_check_section.dart';
import '../widgets/diagnostics/diagnostics_issue_detail.dart';
import '../widgets/diagnostics/diagnostics_issue_section.dart';
import '../widgets/diagnostics/diagnostics_report_section.dart';
import '../widgets/diagnostics/diagnostics_session_section.dart';
import '../widgets/diagnostics/diagnostics_summary_card.dart';
import '../widgets/labels/save_as_label.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';
import 'bili_account_page.dart';
import 'diagnostics_log_page.dart';
import 'sources_page.dart';
import 'sync_settings_page.dart';

/// 问题排查页：支持中心定位，顺序为状态摘要 → 检查结果 → 最近问题 →
/// 本次运行 → 报告与日志。
///
/// 打开页面只读一次包信息；不自动跑检查、不扫库、不读日志。所有自检由用户
/// 点击主按钮触发，各分区独立订阅 provider 的窄 notifier。
class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  @override
  void initState() {
    super.initState();
    // 包信息是轻量平台元数据，不联网、不扫盘；只读一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(diagnosticsPageProvider).ensureAppInfo();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = ref.read(diagnosticsPageProvider);
    return SettingsSubPage(
      title: l10n.diagnosticsTitle,
      actions: [
        ValueListenableBuilder<DiagnosticsReportState>(
          valueListenable: provider.reportState,
          builder: (context, report, _) => M3EIconButton(
            key: const Key('diagnosticsCopyReportAction'),
            variant: M3EIconButtonVariant.standard,
            icon: Icon(
              report.busy
                  ? Icons.hourglass_top_rounded
                  : Icons.content_copy_rounded,
            ),
            semanticLabel: l10n.diagnosticsCopyReport,
            onPressed: report.busy
                ? null
                : () => unawaited(_copyReport(context, provider, l10n)),
          ),
        ),
      ],
      children: [
        DiagnosticsSummaryCard(
          provider: provider,
          onStart: () => unawaited(_startChecks(context, provider, l10n)),
          onStop: provider.stopChecks,
          onOpenLogs: () => _openLogs(context),
        ),
        const SizedBox(height: kSettingsSectionSpacing),
        DiagnosticsCheckSection(
          provider: provider,
          onOpenCheck: (row) => unawaited(
            showDiagnosticsCheckDetail(
              context,
              provider: provider,
              row: row,
              onOpenSources: () => _openSources(context),
              onOpenAccount: () => _openAccount(context),
              onOpenSync: () => _openSync(context),
              onOpenNotifications: _openNotifications,
              onOpenLogs: () => _openLogs(context),
            ),
          ),
        ),
        const SizedBox(height: kSettingsSectionSpacing),
        DiagnosticsIssueSection(
          provider: provider,
          onOpenIssue: (group) => unawaited(
            showDiagnosticsIssueDetail(
              context,
              provider: provider,
              group: group,
              onOpenSources: () => _openSources(context),
            ),
          ),
        ),
        const SizedBox(height: kSettingsSectionSpacing),
        DiagnosticsSessionSection(provider: provider),
        const SizedBox(height: kSettingsSectionSpacing),
        DiagnosticsReportSection(
          provider: provider,
          onPreviewReport: () => unawaited(
            showDiagnosticsReportSheet(context, provider: provider),
          ),
          onCopyReport: () => unawaited(_copyReport(context, provider, l10n)),
          onSaveReport: () => unawaited(_saveReport(context, provider, l10n)),
          onShareReport: () => unawaited(_shareReport(context, provider, l10n)),
          onReportIssue: () => unawaited(_reportIssue(context, provider, l10n)),
          onOpenLogs: () => _openLogs(context),
          onRevealLogs: () => unawaited(_revealLogs(context, provider, l10n)),
        ),
      ],
    );
  }

  Future<void> _startChecks(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
  ) async {
    final notifications = ref.read(notificationServiceProvider);
    final ok = await provider.startChecks();
    if (!ok) {
      notifications.showSnackBar(l10n.diagnosticsCheckStartFailed);
    }
  }

  Future<void> _copyReport(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
  ) async {
    final notifications = ref.read(notificationServiceProvider);
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final ok = await provider.copyReport(
      screenWidth: size.width,
      screenHeight: size.height,
      devicePixelRatio: dpr,
    );
    notifications.showSnackBar(
      ok ? l10n.diagnosticsReportCopied : l10n.diagnosticsReportCopyFailed,
      isError: !ok,
    );
  }

  Future<void> _saveReport(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
  ) async {
    final notifications = ref.read(notificationServiceProvider);
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final result = await provider.saveReport(
      dialogTitle: l10n.diagnosticsExportAction,
      screenWidth: size.width,
      screenHeight: size.height,
      devicePixelRatio: dpr,
    );
    switch (result) {
      case SaveAsSaved(:final displayPath, :final kind):
        notifications.showSuccessSnackBar(
          savedLocationMessage(l10n, kind, displayPath),
        );
      case SaveAsCancelled():
        return;
      case SaveAsFailed():
        notifications.showErrorSnackBar(l10n.saveFailed);
    }
  }

  Future<void> _shareReport(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
  ) async {
    final notifications = ref.read(notificationServiceProvider);
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final result = await provider.shareReport(
      screenWidth: size.width,
      screenHeight: size.height,
      devicePixelRatio: dpr,
    );
    switch (result.outcome) {
      case DiagnosticsShareOutcome.shared:
        notifications.showSuccessSnackBar(l10n.diagnosticsReportShared);
      case DiagnosticsShareOutcome.savedFallback:
        switch (result.saved) {
          case SaveAsSaved(:final displayPath):
            notifications.showSuccessSnackBar(
              l10n.diagnosticsReportShareFallback(displayPath),
            );
          case SaveAsCancelled():
            return;
          case SaveAsFailed():
          case null:
            notifications.showErrorSnackBar(l10n.diagnosticsReportShareFailed);
        }
      case DiagnosticsShareOutcome.failed:
        notifications.showErrorSnackBar(l10n.diagnosticsReportShareFailed);
    }
  }

  Future<void> _reportIssue(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
  ) async {
    final notifications = ref.read(notificationServiceProvider);
    final info = provider.appInfo.value;
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final outcome = await provider.reportIssue(
      version: info?.version ?? 'unknown',
      platform: info?.platform ?? 'unknown',
      screenWidth: size.width,
      screenHeight: size.height,
      devicePixelRatio: dpr,
    );
    switch (outcome) {
      case DiagnosticsReportIssueOutcome.copiedAndOpened:
        notifications.showSuccessSnackBar(l10n.diagnosticsReportIssueOpened);
      case DiagnosticsReportIssueOutcome.copiedButOpenFailed:
        notifications.showSnackBar(l10n.diagnosticsReportIssueOpenFailed);
      case DiagnosticsReportIssueOutcome.copyFailed:
        notifications.showErrorSnackBar(l10n.diagnosticsReportCopyFailed);
    }
  }

  Future<void> _revealLogs(
    BuildContext context,
    DiagnosticsProvider provider,
    AppLocalizations l10n,
  ) async {
    final notifications = ref.read(notificationServiceProvider);
    final ok = await provider.revealLogDirectory();
    if (!ok) {
      notifications.showErrorSnackBar(l10n.diagnosticsLogsOpenDirectoryFailed);
    }
  }

  void _openLogs(BuildContext context) {
    unawaited(openSettingsSubPage(context, const DiagnosticsLogPage()));
  }

  void _openSources(BuildContext context) {
    unawaited(openSettingsSubPage(context, const SourcesPage()));
  }

  void _openAccount(BuildContext context) {
    unawaited(openSettingsSubPage(context, const BiliAccountPage()));
  }

  void _openSync(BuildContext context) {
    unawaited(openSettingsSubPage(context, const SyncSettingsPage()));
  }

  void _openNotifications() {
    unawaited(NotificationPermission.openSettings());
  }
}
