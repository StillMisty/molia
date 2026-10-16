import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/sync_format.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_dialogs.dart';
import 'sync_labels.dart';
import 'sync_log_page.dart';
import 'sync_peers_page.dart';

/// 跨设备同步设置页：口令 / 内容类别 / 传输方式 / 状态与日志。
///
/// 信任模型：口令即信任根，持有口令的设备完全互信（ADR-0003），
/// 页面只做口令的生成、复制、重置与加入，不做逐设备审批。
///
/// 可观察性约定：结论行给「五态 + 时间 + 本轮变更量」，日志给「触发原因 +
/// 本轮做了什么」；计数一律是本轮变更量（不随数据量增长）。失败行点开给出
/// 下一步动作。
class SyncSettingsPage extends StatelessWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    final lanState = _transportState(context, provider, l10n, SyncTransportKind.lan);
    final webdavState =
        _transportState(context, provider, l10n, SyncTransportKind.webdav);
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.settingsSyncTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            title: l10n.syncGeneralSection,
            children: [
              // 信任模型说明行：口令即信任根，先讲清互信范围再给操作。
              SettingsInfoTile(
                icon: Icons.verified_user_rounded,
                title: l10n.syncTrustModelTitle,
                subtitle: l10n.syncPassphraseTrustHint,
              ),
              SettingsNavTile(
                key: const Key('settingsSyncDeviceNameItem'),
                icon: Icons.devices_rounded,
                title: l10n.syncDeviceNameTitle,
                subtitle: provider.deviceName,
                onTap: () => _showRenameDialog(context, provider, l10n),
              ),
              SettingsSwitchTile(
                switchKey: const Key('settingsSyncSwitch'),
                icon: Icons.sync_rounded,
                title: l10n.syncEnabledTitle,
                subtitle: l10n.syncEnabledSubtitle,
                value: provider.enabled,
                onChanged: (value) =>
                    unawaited(_toggleEnabled(context, provider, value, l10n)),
              ),
              if (provider.enabled) ...[
                SettingsInfoTile(
                  key: const Key('settingsSyncStatusItem'),
                  icon: syncOutcomeIcon(provider.lastOutcome),
                  title: syncOutcomeText(l10n, provider.lastOutcome),
                  subtitle: _statusDetail(provider, l10n),
                ),
                SettingsNavTile(
                  key: const Key('settingsSyncNowItem'),
                  icon: Icons.sync_lock_rounded,
                  title: l10n.syncSyncNow,
                  subtitle: _lastSyncText(provider, l10n),
                  onTap: () => unawaited(provider.syncNow(manual: true)),
                ),
                SettingsNavTile(
                  key: const Key('settingsSyncPeersItem'),
                  icon: Icons.group_rounded,
                  title: l10n.syncPeersTitle,
                  subtitle: _peersSubtitle(provider, l10n),
                  onTap: () => openSettingsSubPage(context, const SyncPeersPage()),
                ),
                SettingsNavTile(
                  key: const Key('settingsSyncPassphraseItem'),
                  icon: Icons.key_rounded,
                  title: l10n.syncPassphraseTitle,
                  subtitle: provider.passphrase == null
                      ? l10n.syncPassphraseNotSet
                      : provider.maskedPassphrase,
                  onTap: () => _showPassphraseDialog(context, provider, l10n),
                ),
                SettingsNavTile(
                  key: const Key('settingsSyncJoinItem'),
                  icon: Icons.login_rounded,
                  title: l10n.syncPassphraseJoin,
                  subtitle: l10n.syncPassphraseJoinHint,
                  onTap: () => _showJoinDialog(context, provider, l10n),
                ),
              ],
            ],
          ),
          if (provider.enabled) ...[
            const SizedBox(height: kSettingsSectionSpacing),
            SettingsSectionCard(
              title: l10n.syncActivitySection,
              children: [
                SettingsInfoTile(
                  key: const Key('settingsSyncActivityItem'),
                  icon: Icons.insights_rounded,
                  title: l10n.syncActivityTitle,
                  subtitle: _activitySubtitle(provider, l10n),
                ),
                SettingsSwitchTile(
                  switchKey: const Key('settingsSyncCellularPauseSwitch'),
                  icon: Icons.signal_cellular_off_rounded,
                  title: l10n.syncCellularPauseTitle,
                  subtitle: l10n.syncCellularPauseSubtitle,
                  value: provider.cellularPolicy == SyncCellularPolicy.pause,
                  onChanged: (value) => unawaited(provider.setCellularPolicy(
                      value ? SyncCellularPolicy.pause : SyncCellularPolicy.auto)),
                ),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            SettingsSectionCard(
              title: l10n.syncContentSection,
              children: [
                for (final entry in _categoryOrder.entries)
                  SettingsSwitchTile(
                    switchKey: Key('settingsSyncCategory-${entry.key.name}'),
                    icon: entry.value.$1,
                    title: entry.value.$2(l10n),
                    subtitle: l10n.syncCategorySubtitle,
                    value: provider.categories[entry.key] ?? true,
                    onChanged: (value) =>
                        unawaited(provider.setCategory(entry.key, value)),
                  ),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            SettingsSectionCard(
              title: l10n.syncTransportSection,
              children: [
                SettingsSwitchTile(
                  switchKey: const Key('settingsSyncLanSwitch'),
                  icon: Icons.wifi_rounded,
                  title: l10n.syncLanTitle,
                  subtitle: lanState.text,
                  subtitleColor: lanState.color,
                  value: provider.enabledTransports.contains(SyncTransportKind.lan),
                  onChanged: (value) => unawaited(
                      provider.setTransportEnabled(SyncTransportKind.lan, value)),
                ),
                SettingsSwitchTile(
                  switchKey: const Key('settingsSyncWebdavSwitch'),
                  icon: Icons.cloud_rounded,
                  title: l10n.syncWebdavTitle,
                  subtitle: webdavState.text,
                  subtitleColor: webdavState.color,
                  value:
                      provider.enabledTransports.contains(SyncTransportKind.webdav),
                  onChanged: (value) => unawaited(provider.setTransportEnabled(
                      SyncTransportKind.webdav, value)),
                ),
                SettingsNavTile(
                  key: const Key('settingsSyncWebdavConfigItem'),
                  icon: Icons.settings_rounded,
                  title: l10n.syncWebdavConfigTitle,
                  subtitle: provider.webdav.isConfigured
                      ? provider.webdav.baseUrl
                      : l10n.syncWebdavNotConfigured,
                  onTap: () => unawaited(showWebdavConfigDialog(context, provider, l10n)),
                ),
                // 权限被拒时给可行动入口（手动地址救不了权限，只能授权或转 WebDAV）。
                if (_needsLanPermission(provider))
                  SettingsNavTile(
                    key: const Key('settingsSyncLanPermissionItem'),
                    icon: provider.lanPermissionPermanentlyDenied
                        ? Icons.settings_rounded
                        : Icons.lock_open_rounded,
                    title: provider.lanPermissionPermanentlyDenied
                        ? l10n.syncOpenSystemSettings
                        : l10n.syncLanPermissionTitle,
                    subtitle: provider.lanPermissionPermanentlyDenied
                        ? l10n.syncLanPermissionPermanentSubtitle
                        : l10n.syncLanPermissionSubtitle,
                    onTap: () => unawaited(provider.lanPermissionPermanentlyDenied
                        ? provider.openSystemSettings()
                        : _requestLanPermission(context, provider, l10n)),
                  ),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            SettingsSectionCard(
              title: l10n.syncLogSection,
              children: _logRows(context, provider, l10n),
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
        ],
      ),
    );
  }

  static const Map<SyncCategory, (IconData, String Function(AppLocalizations))>
      _categoryOrder = {
    SyncCategory.playlists: (
      Icons.queue_music_rounded,
      _playlistsTitle,
    ),
    SyncCategory.sources: (
      Icons.library_music_rounded,
      _sourcesTitle,
    ),
    SyncCategory.settings: (
      Icons.tune_rounded,
      _settingsTitle,
    ),
    SyncCategory.statistics: (
      Icons.insights_rounded,
      _statisticsTitle,
    ),
    SyncCategory.history: (
      Icons.history_rounded,
      _historyTitle,
    ),
    SyncCategory.session: (
      Icons.play_circle_outline_rounded,
      _sessionTitle,
    ),
    SyncCategory.credentials: (
      Icons.auto_awesome_rounded,
      _credentialsTitle,
    ),
  };

  static String _playlistsTitle(AppLocalizations l10n) =>
      l10n.syncCategoryPlaylists;

  static String _sourcesTitle(AppLocalizations l10n) =>
      l10n.syncCategorySources;

  static String _settingsTitle(AppLocalizations l10n) =>
      l10n.syncCategorySettings;

  static String _statisticsTitle(AppLocalizations l10n) =>
      l10n.syncCategoryStatistics;

  static String _historyTitle(AppLocalizations l10n) =>
      l10n.syncCategoryHistory;

  static String _sessionTitle(AppLocalizations l10n) =>
      l10n.syncCategorySession;

  static String _credentialsTitle(AppLocalizations l10n) =>
      l10n.syncCategoryCredentials;

  // ---- 状态文案 ----

  static String _statusDetail(SyncProvider provider, AppLocalizations l10n) {
    final report = provider.lastReport;
    if (report == null) return l10n.syncNever;
    final parts = <String>[
      syncTimeText(report.finishedAt),
      ..._roundParts(l10n, report),
    ];
    return parts.join(' · ');
  }

  static List<String> _roundParts(AppLocalizations l10n, SyncRoundReport report) {
    return <String>[
      if (report.applied > 0) l10n.syncAppliedItems(report.applied),
      if (report.peersSeen > 0) l10n.syncPeerCount(report.peersSeen),
      if (report.failedCount > 0) l10n.syncFailedCount(report.failedCount),
      if (report.bytesIn + report.bytesOut > 0)
        l10n.syncBytes(
          syncBytesText(report.bytesIn),
          syncBytesText(report.bytesOut),
        ),
      if (report.error != null)
        l10n.syncLogFailed(syncIssueText(l10n, report.error!)),
    ];
  }

  static String _lastSyncText(SyncProvider provider, AppLocalizations l10n) {
    if (provider.syncing) return l10n.syncSyncing;
    final at = provider.lastSyncAt;
    if (at == 0) return l10n.syncNever;
    return l10n.syncLastSyncAt(syncTimeText(at));
  }

  /// 观测面：近 24 小时活动（触发 / 有效传输 / 流量）+ 当前环境
  /// （同步等级 · 网络类型 · 是否省电）。
  static String _activitySubtitle(SyncProvider provider, AppLocalizations l10n) {
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

  static String _peersSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final count = provider.peers.length;
    return count == 0 ? l10n.syncPeersSubtitleEmpty : l10n.syncPeersSubtitle(count);
  }

  /// 传输副文案：基础说明 + 当前状态（含启动失败原因）+ 最后成功时间。
  ///
  /// 用户主动关闭的传输先于状态判定：开关状态由 `enabled` 表达，关闭后不再
  /// 显示「未配置 / 启动失败」这类残留原因。状态色只作增强：不可用 / 启动失败
  /// 走 warning，运行中且有成功记录走 success。
  static ({String text, Color? color}) _transportState(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    String kind,
  ) {
    final status = provider.transportStatus(kind);
    final base =
        kind == SyncTransportKind.lan ? l10n.syncLanSubtitle : l10n.syncWebdavSubtitle;
    if (status == null) return (text: base, color: null);
    if (!status.enabled) {
      return (text: '$base · ${l10n.syncTransportDisabled}', color: null);
    }
    final semantic = AppSemanticColors.of(context);
    final lastSuccess = provider.transportLastSuccessAt(kind);
    final state = switch (status.unavailableReason) {
      SyncUnavailableReason.notConfigured => l10n.syncTransportNotConfigured,
      // 启动类失败展示原因码映射文案（原始细节在诊断信息里，不上界面）。
      SyncUnavailableReason.startFailed => status.error != null
          ? syncIssueText(l10n, status.error!)
          : l10n.syncTransportStartFailed,
      SyncUnavailableReason.permissionDenied => l10n.syncTransportPermissionDenied,
      _ => status.running ? l10n.syncTransportRunning : l10n.syncTransportStopped,
    };
    final lastText = lastSuccess == 0
        ? l10n.syncTransportNeverSucceeded
        : l10n.syncTransportLastSuccessAt(syncTimeText(lastSuccess));
    final available = status.running && status.unavailableReason == null;
    return (
      text: '$base · $state · $lastText',
      color: available
          ? (lastSuccess > 0 ? semantic.success : null)
          : semantic.warning,
    );
  }

  /// 局域网因缺少权限而不可用（Android 17+：手动地址也无效，只能授权或转 WebDAV）。
  static bool _needsLanPermission(SyncProvider provider) =>
      provider.lanPermissionNeeded &&
      provider.enabledTransports.contains(SyncTransportKind.lan) &&
      provider.transportStatus(SyncTransportKind.lan)?.unavailableReason ==
          SyncUnavailableReason.permissionDenied;

  /// 用户显式申请权限；仍被拒时给「去系统设置」的下一步动作。
  static Future<void> _requestLanPermission(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    final granted = await provider.requestLanPermission();
    if (granted || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.syncLanPermissionDenied),
        action: SnackBarAction(
          label: l10n.syncOpenSystemSettings,
          onPressed: () => unawaited(provider.openSystemSettings()),
        ),
      ),
    );
  }

  // ---- 日志 ----

  /// 首屏只留最近 6 行；更多历史进子页，失败行可点开看下一步动作。
  List<Widget> _logRows(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) {
    final entries = provider.log.take(6).toList();
    if (entries.isEmpty) {
      return [
        SettingsInfoTile(
          icon: Icons.history_rounded,
          title: l10n.syncLogSection,
          subtitle: l10n.syncLogEmpty,
        ),
      ];
    }
    return [
      for (final entry in entries)
        SyncLogRow(
          key: Key('settingsSyncLog-${entry.at}'),
          entry: entry,
          onTap: syncLogEntryActionable(entry)
              ? () => unawaited(showSyncIssueDialog(
                    context,
                    provider: provider,
                    issue: entry.error,
                    l10n: l10n,
                    onConfigurePassphrase: () =>
                        _showPassphraseDialog(context, provider, l10n),
                  ))
              : null,
        ),
      if (provider.log.length > 6)
        SettingsNavTile(
          key: const Key('settingsSyncLogMoreItem'),
          icon: Icons.list_alt_rounded,
          title: l10n.syncLogViewAll(provider.log.length),
          subtitle: l10n.syncLogHint,
          onTap: () => unawaited(openSettingsSubPage(context, const SyncLogPage())),
        ),
    ];
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

  // ---- 口令 / 名称 / 配置 ----

  Future<void> _toggleEnabled(
    BuildContext context,
    SyncProvider provider,
    bool value,
    AppLocalizations l10n,
  ) async {
    final hadPassphrase = provider.passphrase != null;
    await provider.setEnabled(value);
    if (!context.mounted) return;
    if (value && !hadPassphrase && provider.passphrase != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.syncGeneratedHint)));
      await _showPassphraseDialog(context, provider, l10n);
    }
  }

  Future<void> _showPassphraseDialog(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final passphrase = provider.passphrase ?? '';
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.syncPassphraseTitle,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                passphrase,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.syncPassphraseTrustHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: passphrase));
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.copiedToClipboard(
                      l10n.syncPassphraseTitle))));
            },
            child: Text(l10n.syncPassphraseCopy),
          ),
          M3EButton.text(
            onPressed: () {
              navigator.pop();
              unawaited(_confirmReset(context, provider, l10n));
            },
            child: Text(l10n.syncPassphraseReset),
          ),
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.syncPassphraseReset,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(l10n.syncPassphraseResetConfirm),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.filled(
            onPressed: () async {
              navigator.pop();
              await provider.resetPassphrase();
              if (!context.mounted) return;
              await _showPassphraseDialog(context, provider, l10n);
            },
            child: Text(l10n.syncPassphraseReset),
          ),
        ],
      ),
    );
  }

  Future<void> _showJoinDialog(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    await _showTextDialog(
      context,
      title: l10n.syncPassphraseJoinTitle,
      hint: l10n.syncPassphraseJoinHint,
      initialValue: '',
      saveLabel: l10n.syncSave,
      onSave: (value) async {
        try {
          await provider.joinWithPassphrase(value);
          return null;
        } on ArgumentError {
          return l10n.syncPassphraseInvalid;
        }
      },
    );
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    await _showTextDialog(
      context,
      title: l10n.syncDeviceNameDialogTitle,
      hint: l10n.syncRenameHint,
      initialValue: provider.deviceName,
      saveLabel: l10n.syncSave,
      onSave: (value) async {
        if (value.trim().isEmpty) return l10n.syncDeviceNameEmpty;
        await provider.setDeviceName(value.trim());
        return null;
      },
    );
  }

  /// 通用文本输入弹窗；[onSave] 返回错误文案或 null（null = 已保存/关闭）。
  Future<void> _showTextDialog(
    BuildContext context, {
    required String title,
    required String hint,
    required String initialValue,
    required String saveLabel,
    required Future<String?> Function(String value) onSave,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final navigator = Navigator.of(context, rootNavigator: true);
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: title,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: M3ETextField(
            controller: controller,
            label: title,
            placeholder: hint,
            leading: const Icon(Icons.edit_rounded),
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(AppLocalizations.of(context)!.cancelButton),
          ),
          M3EButton.filled(
            onPressed: () async {
              final error = await onSave(controller.text);
              if (!context.mounted) return;
              if (error != null) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(error)));
                return;
              }
              navigator.pop();
            },
            child: Text(saveLabel),
          ),
        ],
      ),
    );
    controller.dispose();
  }
}

