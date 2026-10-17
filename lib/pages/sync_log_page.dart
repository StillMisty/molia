import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/sync/sync_state_store.dart';
import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/sync_format.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_device_page.dart';
import 'sync_dialogs.dart';
import 'sync_labels.dart';

/// 同步日志与诊断子页：近 24 小时动态 + 当前环境 + 完整日志（20 条）+ 复制诊断。
///
/// 观测面细节都在这里（首屏只留「最近一轮结论 + 时间」一句话）；失败行可
/// 点开看下一步动作，未知原因也能拿到重试 / 诊断出口。
class SyncLogPage extends StatelessWidget {
  const SyncLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    final entries = provider.log;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.syncLogTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            title: l10n.syncActivitySection,
            children: [
              SettingsInfoTile(
                key: const Key('settingsSyncActivityItem'),
                icon: Icons.insights_rounded,
                title: l10n.syncActivityTitle,
                subtitle: _activitySubtitle(provider, l10n),
              ),
            ],
          ),
          const SizedBox(height: kSettingsSectionSpacing),
          SettingsSectionCard(
            title: l10n.syncLogSection,
            footer: SettingsSectionHint(text: l10n.syncLogHint),
            children: [
              if (entries.isEmpty)
                SettingsInfoTile(
                  icon: Icons.history_rounded,
                  title: l10n.syncLogSection,
                  subtitle: l10n.syncLogEmpty,
                )
              else
                for (final entry in entries)
                  SyncLogRow(
                    key: Key('settingsSyncLogPage-${entry.at}'),
                    entry: entry,
                    onTap: syncLogEntryActionable(entry)
                        ? () => unawaited(showSyncIssueDialog(
                              context,
                              provider: provider,
                              issue: entry.error,
                              l10n: l10n,
                              // 口令动作直达设备子页（口令弹层在那里）。
                              onConfigurePassphrase: () => openSettingsSubPage(
                                  context, const SyncDevicePage()),
                            ))
                        : null,
                  ),
            ],
          ),
          const SizedBox(height: kSettingsSectionSpacing),
          SettingsSectionCard(
            title: l10n.syncDiagnosticTitle,
            footer: SettingsSectionHint(text: l10n.syncDiagnosticHint),
            children: [
              SettingsNavTile(
                key: const Key('settingsSyncDiagnosticItem'),
                icon: Icons.content_copy_rounded,
                title: l10n.syncDiagnosticCopy,
                subtitle: l10n.syncDiagnosticSubtitle,
                onTap: () => unawaited(_copyDiagnostics(context, provider, l10n)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 近 24 小时活动（触发 / 有效传输 / 流量）+ 当前环境
/// （同步等级 · 网络类型 · 是否省电）。
String _activitySubtitle(SyncProvider provider, AppLocalizations l10n) {
  final summary = provider.activity24h;
  final activity = l10n.syncActivityRounds(
    summary.rounds,
    summary.effectiveRounds,
    syncBytesText(summary.bytes),
  );
  final environment = l10n.syncActivityEnvironment(
    syncLevelText(l10n, provider.syncLevel),
    syncNetworkText(l10n, onCellular: provider.onCellular),
    provider.powerSaveActive ? l10n.syncPowerSaveOn : l10n.syncPowerSaveOff,
  );
  return '$activity\n$environment';
}

/// 复制诊断信息：只含运行状态与计数（无口令 / 无密钥 / 无快照内容）。
Future<void> _copyDiagnostics(
  BuildContext context,
  SyncProvider provider,
  AppLocalizations l10n,
) async {
  final report = provider.lastReport;
  // 传输状态与原始失败细节（`detail`）只进诊断导出，界面上不展示。
  final transports = <Map<String, Object?>>[];
  for (final kind in const [
    SyncTransportKind.lan,
    SyncTransportKind.webdav,
  ]) {
    final status = provider.transportStatus(kind);
    transports.add({
      'kind': kind,
      'enabled': provider.enabledTransports.contains(kind),
      'running': status?.running ?? false,
      'unavailableReason': status?.unavailableReason,
      'lastSuccessAt': provider.transportLastSuccessAt(kind),
      if (status?.error != null) 'error': status!.error!.toJson(),
    });
  }
  final payload = const JsonEncoder.withIndent('  ').convert({
    'deviceId': provider.deviceId,
    'deviceName': provider.deviceName,
    'enabled': provider.enabled,
    'transports': transports,
    'categories': {
      for (final entry in provider.categories.entries)
        entry.key.name: entry.value,
    },
    if (report != null)
      'lastRound': {
        'trigger': report.trigger.name,
        'outcome': report.outcome.name,
        'durationMs': report.durationMs,
        'applied': report.applied,
        'remoteRecords': report.remoteRecords,
        if (report.error != null) 'error': report.error!.toJson(),
        'transports': [for (final item in report.transports) item.toJson()],
      },
    'peers': [for (final peer in provider.peers) peer.toJson()],
    'log': [for (final entry in provider.log.take(10)) entry.toJson()],
  });
  await Clipboard.setData(ClipboardData(text: payload));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(l10n.syncDiagnosticCopied)));
}

/// 日志行是否需要「下一步动作」（失败或有失败原因；成功行只是历史）。
bool syncLogEntryActionable(SyncLogEntry entry) =>
    entry.outcome == SyncOutcome.failed || entry.error != null;

/// 日志行：时间 + 触发原因 + 结论 + 本轮变更量；失败行可点开看下一步动作。
class SyncLogRow extends StatelessWidget {
  const SyncLogRow({super.key, required this.entry, this.onTap});

  final SyncLogEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final semantic = AppSemanticColors.of(context);
    final message = syncOutcomeText(l10n, entry.outcome);
    final trigger = switch (entry.trigger) {
      SyncTrigger.startup => l10n.syncTriggerStartup,
      SyncTrigger.debounce => l10n.syncTriggerDebounce,
      SyncTrigger.timer => l10n.syncTriggerTimer,
      SyncTrigger.incoming => l10n.syncTriggerIncoming,
      SyncTrigger.resume => l10n.syncTriggerResume,
      SyncTrigger.pause => l10n.syncTriggerPause,
      SyncTrigger.manual => l10n.syncTriggerManual,
    };
    final detail = <String>[
      if (entry.applied > 0) l10n.syncAppliedItems(entry.applied),
      if (entry.peersSeen > 0) l10n.syncPeerCount(entry.peersSeen),
      if (entry.failed > 0) l10n.syncFailedCount(entry.failed),
      if (entry.bytesIn + entry.bytesOut > 0)
        l10n.syncBytes(
          syncBytesText(entry.bytesIn),
          syncBytesText(entry.bytesOut),
        ),
      if (entry.error != null) l10n.syncLogFailed(syncIssueText(l10n, entry.error!)),
    ].join(' · ');
    // 失败用错误色，部分失败用警告色；其余状态是中性信息（形状已区分状态）。
    final iconColor = switch (entry.outcome) {
      SyncOutcome.failed => scheme.error,
      SyncOutcome.partial => semantic.warning,
      _ => scheme.onSurfaceVariant,
    };

    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: '$message, $detail',
      onPressed: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              syncOutcomeIcon(entry.outcome),
              size: 18,
              color: iconColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${syncTimeText(entry.at)} · $trigger · $message',
                  style: m3e.typeScale.bodyMedium,
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: m3e.typeScale.bodySmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (onTap != null)
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }
}
