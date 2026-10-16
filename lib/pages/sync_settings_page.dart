import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/sync/sync_state_store.dart';
import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_peers_page.dart';

/// 跨设备同步设置页：口令 / 内容类别 / 传输方式 / 状态与日志。
///
/// 信任模型：口令即信任根，持有口令的设备完全互信（ADR-0003），
/// 页面只做口令的生成、复制、重置与加入，不做逐设备审批。
///
/// 可观察性约定：结论行给「五态 + 时间 + 本轮变更量」，日志给「触发原因 +
/// 本轮做了什么」；不再出现「跳过 N 项」这类全库规模计数（它随数据量增长，
/// 对用户没有意义）。失败行点开给出下一步动作。
class SyncSettingsPage extends StatelessWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
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
                  icon: _outcomeIcon(provider.lastOutcome),
                  title: _outcomeText(l10n, provider.lastOutcome),
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
                  subtitle: _transportSubtitle(provider, l10n, 'lan'),
                  value: provider.enabledTransports.contains('lan'),
                  onChanged: (value) => unawaited(
                      provider.setTransportEnabled('lan', value)),
                ),
                SettingsSwitchTile(
                  switchKey: const Key('settingsSyncWebdavSwitch'),
                  icon: Icons.cloud_rounded,
                  title: l10n.syncWebdavTitle,
                  subtitle: _transportSubtitle(provider, l10n, 'webdav'),
                  value: provider.enabledTransports.contains('webdav'),
                  onChanged: (value) => unawaited(
                      provider.setTransportEnabled('webdav', value)),
                ),
                SettingsNavTile(
                  key: const Key('settingsSyncWebdavConfigItem'),
                  icon: Icons.settings_rounded,
                  title: l10n.syncWebdavConfigTitle,
                  subtitle: provider.webdav.isConfigured
                      ? provider.webdav.baseUrl
                      : l10n.syncWebdavNotConfigured,
                  onTap: () => _showWebdavDialog(context, provider, l10n),
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

  static String _outcomeText(AppLocalizations l10n, SyncOutcome? outcome) =>
      switch (outcome) {
        null => l10n.syncNever,
        SyncOutcome.ok => l10n.syncOutcomeOk,
        SyncOutcome.noChanges => l10n.syncOutcomeNoChanges,
        SyncOutcome.noPeers => l10n.syncOutcomeNoPeers,
        SyncOutcome.partial => l10n.syncOutcomePartial,
        SyncOutcome.failed => l10n.syncOutcomeFailed,
      };

  /// 结论行图标：五态各有形状，颜色只作增强（不靠颜色单独编码状态）。
  static IconData _outcomeIcon(SyncOutcome? outcome) => switch (outcome) {
        null => Icons.sync_problem_rounded,
        SyncOutcome.ok => Icons.check_circle_rounded,
        SyncOutcome.noChanges => Icons.check_circle_outline_rounded,
        SyncOutcome.noPeers => Icons.wifi_tethering_off_rounded,
        SyncOutcome.partial => Icons.error_outline_rounded,
        SyncOutcome.failed => Icons.error_rounded,
      };

  static String _statusDetail(SyncProvider provider, AppLocalizations l10n) {
    final report = provider.lastReport;
    if (report == null) return l10n.syncNever;
    final parts = <String>[
      _time(report.finishedAt),
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
        l10n.syncBytes(_formatBytes(report.bytesIn), _formatBytes(report.bytesOut)),
      if (report.error != null && report.error!.isNotEmpty)
        l10n.syncLogFailed(report.error!),
    ];
  }

  static String _lastSyncText(SyncProvider provider, AppLocalizations l10n) {
    if (provider.syncing) return l10n.syncSyncing;
    final at = provider.lastSyncAt;
    if (at == 0) return l10n.syncNever;
    return l10n.syncLastSyncAt(_time(at));
  }

  static String _peersSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final count = provider.peers.length;
    return count == 0 ? l10n.syncPeersSubtitleEmpty : l10n.syncPeersSubtitle(count);
  }

  /// 传输副标题：基础说明 + 当前状态（开关开着但没在工作时必须看得出来）。
  static String _transportSubtitle(
    SyncProvider provider,
    AppLocalizations l10n,
    String kind,
  ) {
    final status = provider.transportStatus(kind);
    final base =
        kind == 'lan' ? l10n.syncLanSubtitle : l10n.syncWebdavSubtitle;
    final state = switch (status.unavailableReason) {
      SyncUnavailableReason.notConfigured => l10n.syncTransportNotConfigured,
      SyncUnavailableReason.startFailed => l10n.syncTransportStartFailed,
      _ => status.running ? l10n.syncTransportRunning : l10n.syncTransportStopped,
    };
    return '$base · $state';
  }

  static String _time(int at) =>
      DateFormat('MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(at));

  /// 字节数的紧凑展示（KB/MB 千位制；同步快照常用量级）。
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  // ---- 日志 ----

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
        _SyncLogRow(
          key: Key('settingsSyncLog-${entry.at}'),
          entry: entry,
          onTap: entry.outcome == SyncOutcome.failed
              ? () => _showFailureDialog(context, provider, entry, l10n)
              : null,
        ),
    ];
  }

  /// 失败行的下一步动作：不是死胡同——给出原因与重试入口。
  Future<void> _showFailureDialog(
    BuildContext context,
    SyncProvider provider,
    SyncLogEntry entry,
    AppLocalizations l10n,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.syncOutcomeFailed,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(entry.error ?? l10n.syncLogEmpty),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.filled(
            onPressed: () {
              navigator.pop();
              unawaited(provider.syncNow(manual: true));
            },
            label: Text(l10n.syncRetry),
          ),
        ],
      ),
    );
  }

  /// 复制诊断信息：只含运行状态与计数（无口令 / 无密钥 / 无快照内容）。
  Future<void> _copyDiagnostics(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    final report = provider.lastReport;
    final payload = const JsonEncoder.withIndent('  ').convert({
      'deviceId': provider.deviceId,
      'deviceName': provider.deviceName,
      'enabled': provider.enabled,
      'transports': [
        for (final kind in ['lan', 'webdav'])
          {
            'kind': kind,
            'enabled': provider.enabledTransports.contains(kind),
            'running': provider.transportStatus(kind).running,
            'unavailableReason': provider.transportStatus(kind).unavailableReason,
          },
      ],
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
          if (report.error != null) 'error': report.error,
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
            label: Text(l10n.syncPassphraseReset),
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
            label: Text(saveLabel),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _showWebdavDialog(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
  ) async {
    final password = await provider.readWebdavPassword() ?? '';
    if (!context.mounted) return;
    final config = provider.webdav;
    final server = TextEditingController(text: config.baseUrl);
    final username = TextEditingController(text: config.username);
    final passwordController = TextEditingController(text: password);
    final remoteDir = TextEditingController(text: config.remoteDir);
    final navigator = Navigator.of(context, rootNavigator: true);

    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: l10n.syncWebdavConfigTitle,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                M3ETextField(
                  controller: server,
                  label: l10n.syncWebdavServer,
                  placeholder: 'https://dav.example.com/dav',
                  leading: const Icon(Icons.link_rounded),
                ),
                const SizedBox(height: 12),
                M3ETextField(
                  controller: username,
                  label: l10n.syncWebdavUsername,
                  leading: const Icon(Icons.person_rounded),
                ),
                const SizedBox(height: 12),
                M3ETextField(
                  controller: passwordController,
                  label: l10n.syncWebdavPassword,
                  obscureText: true,
                  leading: const Icon(Icons.key_rounded),
                ),
                const SizedBox(height: 12),
                M3ETextField(
                  controller: remoteDir,
                  label: l10n.syncWebdavRemoteDir,
                  leading: const Icon(Icons.folder_rounded),
                ),
              ],
            ),
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.filled(
            onPressed: () async {
              await provider.setWebdavConfig(WebDavConfig(
                baseUrl: server.text.trim(),
                username: username.text.trim(),
                remoteDir: remoteDir.text.trim().isEmpty
                    ? 'molia-sync'
                    : remoteDir.text.trim(),
              ));
              await provider.setWebdavPassword(passwordController.text);
              navigator.pop();
            },
            label: Text(l10n.syncSave),
          ),
        ],
      ),
    );
    server.dispose();
    username.dispose();
    passwordController.dispose();
    remoteDir.dispose();
  }
}

/// 日志行：结论 + 触发原因 + 本轮变更量（失败行可点开看重试入口）。
class _SyncLogRow extends StatelessWidget {
  const _SyncLogRow({super.key, required this.entry, this.onTap});

  final SyncLogEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = M3ETheme.of(context).colorScheme;
    final m3e = M3ETheme.of(context);
    final message = switch (entry.outcome) {
      SyncOutcome.ok => l10n.syncOutcomeOk,
      SyncOutcome.noChanges => l10n.syncOutcomeNoChanges,
      SyncOutcome.noPeers => l10n.syncOutcomeNoPeers,
      SyncOutcome.partial => l10n.syncOutcomePartial,
      SyncOutcome.failed => l10n.syncOutcomeFailed,
    };
    final trigger = switch (entry.trigger) {
      SyncTrigger.startup => l10n.syncTriggerStartup,
      SyncTrigger.debounce => l10n.syncTriggerDebounce,
      SyncTrigger.timer => l10n.syncTriggerTimer,
      SyncTrigger.incoming => l10n.syncTriggerIncoming,
      SyncTrigger.resume => l10n.syncTriggerResume,
      SyncTrigger.manual => l10n.syncTriggerManual,
    };
    final detail = <String>[
      if (entry.applied > 0) l10n.syncAppliedItems(entry.applied),
      if (entry.peersSeen > 0) l10n.syncPeerCount(entry.peersSeen),
      if (entry.failed > 0) l10n.syncFailedCount(entry.failed),
      if (entry.bytesIn + entry.bytesOut > 0)
        l10n.syncBytes(
          SyncSettingsPage._formatBytes(entry.bytesIn),
          SyncSettingsPage._formatBytes(entry.bytesOut),
        ),
      if (entry.error != null && entry.error!.isNotEmpty)
        l10n.syncLogFailed(entry.error!),
    ].join(' · ');

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
              SyncSettingsPage._outcomeIcon(entry.outcome),
              size: 18,
              color: entry.outcome == SyncOutcome.failed
                  ? scheme.error
                  : m3e.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${SyncSettingsPage._time(entry.at)} · $trigger · $message',
                  style: m3e.typeScale.bodyMedium,
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: m3e.typeScale.bodySmall.copyWith(
                      color: m3e.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (onTap != null)
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: m3e.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }
}
