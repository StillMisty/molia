import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_content_page.dart';
import 'sync_device_page.dart';
import 'sync_dialogs.dart';
import 'sync_labels.dart';
import 'sync_log_page.dart';
import 'sync_peers_page.dart';

/// 跨设备同步设置页：首屏只留结论与配置入口，细节下沉子页。
///
/// 信任模型：口令即信任根，持有口令的设备完全互信（ADR-0003）。首屏信息
/// 预算 ≤ 9 行：开关 / 名册 / 内容 / 日志 / 传输 / 设备入口；同步何时跑
/// 由调度器声明式决定，页面不提供「立即同步」这类手动主操作。口令与设备名
/// 在「设备与口令」子页，类别与蜂窝策略在「同步内容」子页，动态与日志在
/// 「同步日志」子页。
///
/// 状态行给「五态结论 + 相对时间」一句话，不堆本轮变更量（细节在日志页）。
class SyncSettingsPage extends StatelessWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    final lanState =
        _transportState(context, provider, l10n, SyncTransportKind.lan);
    final webdavState =
        _transportState(context, provider, l10n, SyncTransportKind.webdav);
    final webdavEnabled =
        provider.enabledTransports.contains(SyncTransportKind.webdav);
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
              SettingsSwitchTile(
                switchKey: const Key('settingsSyncSwitch'),
                icon: Icons.sync_rounded,
                title: l10n.syncEnabledTitle,
                // 启用后副文案让位给状态结论（一句话）；关闭时才是能力说明。
                subtitle: provider.enabled
                    ? _statusSubtitle(provider, l10n)
                    : l10n.syncEnabledSubtitle,
                value: provider.enabled,
                onChanged: (value) =>
                    unawaited(_toggleEnabled(context, provider, value, l10n)),
              ),
              if (provider.enabled) ...[
                SettingsNavTile(
                  key: const Key('settingsSyncPeersItem'),
                  icon: Icons.group_rounded,
                  title: l10n.syncPeersTitle,
                  subtitle: _peersSubtitle(provider, l10n),
                  onTap: () =>
                      openSettingsSubPage(context, const SyncPeersPage()),
                ),
                SettingsNavTile(
                  key: const Key('settingsSyncContentItem'),
                  icon: Icons.tune_rounded,
                  title: l10n.syncContentSection,
                  subtitle: _contentSubtitle(provider, l10n),
                  onTap: () =>
                      openSettingsSubPage(context, const SyncContentPage()),
                ),
                SettingsNavTile(
                  key: const Key('settingsSyncLogItem'),
                  icon: Icons.receipt_long_rounded,
                  title: l10n.syncLogTitle,
                  subtitle: _logSubtitle(provider, l10n),
                  onTap: () =>
                      openSettingsSubPage(context, const SyncLogPage()),
                ),
              ],
            ],
          ),
          if (provider.enabled) ...[
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
                  value: provider.enabledTransports
                      .contains(SyncTransportKind.lan),
                  onChanged: (value) => unawaited(provider.setTransportEnabled(
                      SyncTransportKind.lan, value)),
                ),
                SettingsSwitchTile(
                  switchKey: const Key('settingsSyncWebdavSwitch'),
                  icon: Icons.cloud_rounded,
                  title: l10n.syncWebdavTitle,
                  subtitle: webdavState.text,
                  subtitleColor: webdavState.color,
                  value: webdavEnabled,
                  onChanged: (value) => unawaited(provider.setTransportEnabled(
                      SyncTransportKind.webdav, value)),
                ),
                // 配置入口只在 WebDAV 启用后才有意义（未启用时开关副文案已说明）。
                if (webdavEnabled)
                  SettingsNavTile(
                    key: const Key('settingsSyncWebdavConfigItem'),
                    icon: Icons.settings_rounded,
                    title: l10n.syncWebdavConfigTitle,
                    subtitle: provider.webdav.isConfigured
                        ? provider.webdav.baseUrl
                        : l10n.syncWebdavNotConfigured,
                    onTap: () => unawaited(
                        showWebdavConfigDialog(context, provider, l10n)),
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
                    onTap: () => unawaited(
                        provider.lanPermissionPermanentlyDenied
                            ? provider.openSystemSettings()
                            : _requestLanPermission(context, provider, l10n)),
                  ),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            SettingsSectionCard(
              title: l10n.syncPeersSection,
              children: [
                SettingsNavTile(
                  key: const Key('settingsSyncAdvancedItem'),
                  icon: Icons.key_rounded,
                  title: l10n.syncDevicePassphraseTitle,
                  subtitle: _deviceSubtitle(provider, l10n),
                  onTap: () =>
                      openSettingsSubPage(context, const SyncDevicePage()),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 开关副文案：五态结论 + 相对时间（如「未发现对端 · 3 分钟前」）；
  /// 未跑过任何一轮时只说「尚未同步」。
  static String _statusSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final report = provider.lastReport;
    if (report == null) return l10n.syncNever;
    final peersSeen = report.peersSeen;
    final conclusion = report.outcome == SyncOutcome.ok && peersSeen > 0
        ? l10n.syncStatusSyncedPeers(peersSeen)
        : syncOutcomeText(l10n, report.outcome);
    return '$conclusion · ${syncRelativeTimeText(
      l10n,
      nowMs: provider.engine.state.nowMs(),
      atMs: report.finishedAt,
    )}';
  }

  /// 名册入口副文案：对端数 + 最后同步时间；无对端时给局域网发现预期。
  static String _peersSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final count = provider.peers.length;
    if (count == 0) return l10n.syncPeersSummaryEmpty;
    final countText = l10n.syncPeerCount(count);
    final lastSyncAt = provider.lastSyncAt;
    if (lastSyncAt == 0) return countText;
    return '$countText · ${syncRelativeTimeText(
      l10n,
      nowMs: provider.engine.state.nowMs(),
      atMs: lastSyncAt,
    )}';
  }

  /// 内容入口副文案：全开只说「全部类别」，否则给关闭项数。
  static String _contentSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final off = provider.categories.values.where((on) => !on).length;
    return off == 0 ? l10n.syncContentAllOn : l10n.syncContentOffCount(off);
  }

  /// 日志入口副文案：最近一轮结论 + 时间；没有记录时说「暂无记录」。
  static String _logSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final entries = provider.log;
    if (entries.isEmpty) return l10n.syncLogEmpty;
    final latest = entries.first;
    return '${syncOutcomeText(l10n, latest.outcome)} · ${syncRelativeTimeText(
      l10n,
      nowMs: provider.engine.state.nowMs(),
      atMs: latest.at,
    )}';
  }

  /// 设备入口副文案：设备名 + 口令状态（口令本身在子页里显示 / 复制）。
  static String _deviceSubtitle(SyncProvider provider, AppLocalizations l10n) {
    final passphrase = provider.passphrase == null
        ? l10n.syncPassphraseNotSet
        : l10n.syncPassphraseSet;
    return '${provider.deviceName} · $passphrase';
  }

  /// 传输副文案：只说状态词（运行中 / 已关闭 / 未配置 / 启动失败 / 缺少权限）。
  ///
  /// 用户主动关闭的传输先于状态判定：开关状态由 `enabled` 表达，关闭后不再
  /// 显示「未配置 / 启动失败」这类残留原因。状态色只作增强：不可用 / 启动失败
  /// 走 warning，运行中且有成功记录走 success。最后成功时间与原始失败细节
  /// 不进首屏（日志子页的失败行里有）。
  static ({String text, Color? color}) _transportState(
    BuildContext context,
    SyncProvider provider,
    AppLocalizations l10n,
    String kind,
  ) {
    final status = provider.transportStatus(kind);
    if (status == null) {
      return (text: l10n.syncTransportNotConfigured, color: null);
    }
    if (!status.enabled) {
      return (text: l10n.syncTransportDisabled, color: null);
    }
    final semantic = AppSemanticColors.of(context);
    final state = switch (status.unavailableReason) {
      SyncUnavailableReason.notConfigured => l10n.syncTransportNotConfigured,
      // 启动类失败只说「启动失败」；原因码细节在日志子页的失败弹层里。
      SyncUnavailableReason.startFailed => l10n.syncTransportStartFailed,
      SyncUnavailableReason.permissionDenied =>
        l10n.syncTransportPermissionDenied,
      _ =>
        status.running ? l10n.syncTransportRunning : l10n.syncTransportStopped,
    };
    final available = status.running && status.unavailableReason == null;
    return (
      text: state,
      color: available
          ? (provider.transportLastSuccessAt(kind) > 0
              ? semantic.success
              : null)
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

  Future<void> _toggleEnabled(
    BuildContext context,
    SyncProvider provider,
    bool value,
    AppLocalizations l10n,
  ) async {
    final hadPassphrase = provider.passphrase != null;
    await provider.setEnabled(value);
    if (!context.mounted) return;
    // 首次开启自动生成口令：立刻展示，用户才复制得到（其它设备要输入它）。
    if (value && !hadPassphrase && provider.passphrase != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.syncGeneratedHint)));
      await showSyncPassphraseDialog(context, provider, l10n);
    }
  }
}
