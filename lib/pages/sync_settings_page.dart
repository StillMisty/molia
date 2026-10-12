import 'dart:async';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/sync/sync_state_store.dart';
import '../domain/models/device_sync.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/settings/settings_tiles.dart';

/// 跨设备同步设置页：口令 / 内容类别 / 传输方式 / 手动同步与日志。
///
/// 信任模型：口令即信任根，持有口令的设备完全互信（ADR-0003），
/// 页面只做口令的生成、复制、重置与加入，不做逐设备审批。
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
                SettingsNavTile(
                  key: const Key('settingsSyncNowItem'),
                  icon: Icons.sync_lock_rounded,
                  title: l10n.syncSyncNow,
                  subtitle: _statusText(provider, l10n),
                  onTap: () => unawaited(provider.syncNow(manual: true)),
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
                  subtitle: l10n.syncLanSubtitle,
                  value: provider.enabledTransports.contains('lan'),
                  onChanged: (value) => unawaited(
                      provider.setTransportEnabled('lan', value)),
                ),
                SettingsSwitchTile(
                  switchKey: const Key('settingsSyncWebdavSwitch'),
                  icon: Icons.cloud_rounded,
                  title: l10n.syncWebdavTitle,
                  subtitle: l10n.syncWebdavSubtitle,
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

  String _statusText(SyncProvider provider, AppLocalizations l10n) {
    if (provider.syncing) return l10n.syncSyncing;
    if (provider.lastSyncAt == 0) return l10n.syncNever;
    final time = DateFormat('MM-dd HH:mm')
        .format(DateTime.fromMillisecondsSinceEpoch(provider.lastSyncAt));
    if (!provider.lastSyncOk) {
      return l10n.syncLastResultFail(provider.lastSyncError ?? '');
    }
    final applied =
        provider.log.isNotEmpty ? provider.log.first.applied : 0;
    return l10n.syncLastResultOk(time, applied);
  }

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
    final scheme = Theme.of(context).colorScheme;
    return [
      for (final entry in entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                entry.ok ? Icons.check_circle_rounded : Icons.error_rounded,
                size: 18,
                color: entry.ok ? scheme.primary : scheme.error,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${DateFormat('MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(entry.at))} · '
                  '${entry.ok ? l10n.syncLogApplied(entry.applied, entry.skipped) : l10n.syncLogFailed(entry.error ?? '')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
    ];
  }

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
