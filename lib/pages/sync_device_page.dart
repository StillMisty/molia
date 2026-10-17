import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_dialogs.dart';

/// 设备与口令子页：信任模型说明 + 设备名 + 口令（生成 / 复制 / 重置）+ 加入口令。
///
/// 口令即信任根（ADR-0003），说明与操作放同一页；首屏只留
/// 「设备名 · 口令已设置 / 未设置」这一句结论。
class SyncDevicePage extends StatelessWidget {
  const SyncDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.syncDevicePassphraseTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            title: l10n.syncDevicePassphraseTitle,
            children: [
              // 信任模型说明行：先讲清互信范围，再给口令操作。
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
                onTap: () =>
                    unawaited(showSyncRenameDialog(context, provider, l10n)),
              ),
              SettingsNavTile(
                key: const Key('settingsSyncPassphraseItem'),
                icon: Icons.key_rounded,
                title: l10n.syncPassphraseTitle,
                subtitle: provider.passphrase == null
                    ? l10n.syncPassphraseNotSet
                    : provider.maskedPassphrase,
                onTap: () =>
                    unawaited(showSyncPassphraseDialog(context, provider, l10n)),
              ),
              SettingsNavTile(
                key: const Key('settingsSyncJoinItem'),
                icon: Icons.login_rounded,
                title: l10n.syncPassphraseJoin,
                subtitle: l10n.syncPassphraseJoinHint,
                onTap: () =>
                    unawaited(showSyncJoinDialog(context, provider, l10n)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
