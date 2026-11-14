import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/backup_restore_page.dart';
import '../../pages/play_statistics_page.dart';
import '../../pages/sync_settings_page.dart';
import '../../providers/sync_provider.dart';
import '../../services/play_statistics_service.dart';
import 'settings_tiles.dart';

/// 设置首屏「数据与备份」卡：听歌统计、备份与恢复、跨设备同步。
///
/// 三件事都围绕「数据怎么留、怎么走」：统计留着看，备份导出到文件，同步
/// 发到别的设备。导出 / 导入 / 收藏迁移下沉到「备份与恢复」子页，低频且带
/// 破坏性的动作不再与日常入口混排。
class DataBackupSection extends StatelessWidget {
  const DataBackupSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 完整备份只经同步引擎的适配器收集/合并；引擎未挂载（测试）时导出 /
    // 导入按失败处理（没有可回退的旧数据源），入口仍然可见。
    final syncProvider = context.watch<SyncProvider?>();
    final statistics = context.watch<PlayStatisticsService?>();
    return SettingsSectionCard(
      title: l10n.settingsDataBackupTitle,
      children: [
        // 统计采集开关（关闭 = 停止记录新事件，已有数据保留）。
        if (statistics != null)
          ValueListenableBuilder<bool>(
            valueListenable: statistics.enabledNotifier,
            builder: (context, enabled, _) => SettingsSwitchTile(
              switchKey: const Key('settingsPlayStatisticsSwitch'),
              icon: Icons.query_stats_rounded,
              title: l10n.statsRecordSwitch,
              subtitle: l10n.statsRecordSwitchSubtitle,
              value: enabled,
              onChanged: (value) => unawaited(statistics.setEnabled(value)),
            ),
          ),
        // 听歌统计：事件级采集（本机），播放次数 / 热力图 / 导出。
        if (statistics != null)
          SettingsNavTile(
            key: const Key('settingsPlayStatisticsItem'),
            icon: Icons.insights_rounded,
            title: l10n.statsTitle,
            subtitle: l10n.statsSettingsSubtitle,
            onTap: () =>
                openSettingsSubPage(context, const PlayStatisticsPage()),
          ),
        // 备份与恢复：完整备份 / 导入 / LX 收藏迁移。
        SettingsNavTile(
          key: const Key('settingsBackupRestoreItem'),
          icon: Icons.settings_backup_restore_rounded,
          title: l10n.settingsBackupRestoreTitle,
          subtitle: l10n.settingsBackupRestoreSubtitle,
          onTap: () => openSettingsSubPage(context, const BackupRestorePage()),
        ),
        if (syncProvider != null)
          SettingsNavTile(
            key: const Key('settingsSyncItem'),
            icon: Icons.sync_rounded,
            title: l10n.settingsSyncTitle,
            subtitle: l10n.settingsSyncItemSubtitle,
            onTap: () => openSettingsSubPage(context, const SyncSettingsPage()),
          ),
      ],
    );
  }
}
