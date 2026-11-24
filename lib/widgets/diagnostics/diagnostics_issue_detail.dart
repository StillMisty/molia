import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/diagnostics.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
import '../../providers/diagnostics_provider.dart';
import '../../services/notification_service.dart';
import '../settings/settings_tiles.dart';
import 'diagnostics_labels.dart';

/// 问题详情弹层：时间、渠道、类别、次数与「可能原因 / 建议」+ 可逆动作。
Future<void> showDiagnosticsIssueDetail(
  BuildContext context, {
  required DiagnosticsProvider provider,
  required DiagnosticIssueGroup group,
  required VoidCallback onOpenSources,
}) {
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  return M3EDialog.show<void>(
    context,
    dialog: M3EDialog(
      title: l10n.diagnosticsIssueDetailTitle,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, l10n, group),
              const SizedBox(height: 12),
              SettingsSectionCard(
                children: [
                  SettingsInfoTile(
                    icon: Icons.podcasts_rounded,
                    title: l10n.diagnosticsIssueChannel,
                    subtitle: group.channelDisplayName,
                  ),
                  SettingsInfoTile(
                    icon: Icons.category_rounded,
                    title: l10n.diagnosticsIssueCategory,
                    subtitle: diagnosticFailureReason(l10n, group.kind),
                  ),
                  SettingsInfoTile(
                    icon: Icons.sell_rounded,
                    title: l10n.diagnosticsIssueKey,
                    subtitle: group.l10nKey ?? l10n.diagnosticsIssueKeyUnknown,
                  ),
                  SettingsInfoTile(
                    icon: Icons.numbers_rounded,
                    title: l10n.diagnosticsIssueOccurrencesTitle,
                    subtitle: l10n.diagnosticsIssueOccurrences(group.count),
                  ),
                  SettingsInfoTile(
                    icon: Icons.first_page_rounded,
                    title: l10n.diagnosticsIssueFirst,
                    subtitle: diagnosticDetailTime(group.firstAt),
                  ),
                  SettingsInfoTile(
                    icon: Icons.last_page_rounded,
                    title: l10n.diagnosticsIssueLast,
                    subtitle: diagnosticDetailTime(group.lastAt),
                  ),
                  SettingsInfoTile(
                    icon: Icons.replay_rounded,
                    title: l10n.diagnosticsIssueRetryableTitle,
                    subtitle: group.retryable
                        ? l10n.diagnosticsIssueRetryable
                        : l10n.diagnosticsIssueNotRetryable,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SettingsSectionCard(
                children: [
                  SettingsInfoTile(
                    icon: Icons.lightbulb_rounded,
                    title: l10n.diagnosticsIssueAdvice,
                    subtitle: diagnosticIssueSuggestion(l10n, group.kind),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SettingsSectionCard(
                children: [
                  SettingsTileRow(
                    key: const Key('diagnosticsIssueRecheck'),
                    icon: Icons.refresh_rounded,
                    title: l10n.diagnosticsIssueRecheck,
                    subtitle: l10n.diagnosticsIssueRecheckHint,
                    onPressed: provider.checkResults.value.running
                        ? null
                        : () => _closeThen(
                            navigator,
                            () => unawaited(provider.startChecks()),
                          ),
                  ),
                  SettingsTileRow(
                    key: const Key('diagnosticsIssueOpenSources'),
                    icon: Icons.library_music_rounded,
                    title: l10n.diagnosticsActionOpenSources,
                    subtitle: l10n.diagnosticsActionOpenSourcesHint,
                    onPressed: () => _closeThen(navigator, onOpenSources),
                  ),
                  SettingsTileRow(
                    key: const Key('diagnosticsIssueCopyDetails'),
                    icon: Icons.content_copy_rounded,
                    title: l10n.diagnosticsActionCopyDetails,
                    subtitle: l10n.diagnosticsActionCopyDetailsHint,
                    onPressed: () =>
                        _copyDetails(context, provider, l10n, group),
                  ),
                ],
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
  DiagnosticIssueGroup group,
) {
  final m3e = M3ETheme.of(context);
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(
          Icons.error_outline_rounded,
          size: 24,
          color: m3e.colorScheme.error,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${group.channelDisplayName} · '
              '${diagnosticFailureReason(l10n, group.kind)}',
              style: m3e.typeScale.titleMedium,
            ),
            Text(
              '${l10n.diagnosticsIssueOccurrences(group.count)} · '
              '${l10n.diagnosticsIssueLastAt(diagnosticShortTime(group.lastAt))}',
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

void _closeThen(NavigatorState navigator, VoidCallback action) {
  navigator.pop();
  action();
}

Future<void> _copyDetails(
  BuildContext context,
  DiagnosticsProvider provider,
  AppLocalizations l10n,
  DiagnosticIssueGroup group,
) async {
  // 弹层内的按钮回调只有 dialog context：从最近的 ProviderScope 取容器。
  final NotificationService? notifications = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(notificationServiceProvider);
  final text = [
    '${l10n.diagnosticsIssueChannel}: ${group.channelDisplayName}',
    '${l10n.diagnosticsIssueCategory}: '
        '${diagnosticFailureReason(l10n, group.kind)}',
    '${l10n.diagnosticsIssueKey}: '
        '${group.l10nKey ?? l10n.diagnosticsIssueKeyUnknown}',
    '${l10n.diagnosticsIssueOccurrencesTitle}: '
        '${l10n.diagnosticsIssueOccurrences(group.count)}',
    '${l10n.diagnosticsIssueFirst}: ${diagnosticDetailTime(group.firstAt)}',
    '${l10n.diagnosticsIssueLast}: ${diagnosticDetailTime(group.lastAt)}',
    '${l10n.diagnosticsIssueAdvice}: '
        '${diagnosticIssueSuggestion(l10n, group.kind)}',
  ].join('\n');
  final ok = await provider.copyPlainText(text);
  notifications?.showSnackBar(
    ok ? l10n.diagnosticsActionCopied : l10n.diagnosticsActionCopyFailed,
    isError: !ok,
  );
}
