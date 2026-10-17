import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/settings/settings_tiles.dart';

/// 同步内容子页：类别开关 + 移动数据策略。
///
/// 首屏只留「全部类别 / 已关闭 N 项」结论，逐类别取舍放这里（类别是
/// 「同步什么」的细节，不是首屏决策）。
class SyncContentPage extends StatelessWidget {
  const SyncContentPage({super.key});

  /// 展示顺序：常用数据在前，凭证与统计靠后。
  static const Map<SyncCategory, (IconData, String Function(AppLocalizations))>
      _categoryOrder = {
    SyncCategory.playlists: (Icons.queue_music_rounded, _playlistsTitle),
    SyncCategory.sources: (Icons.library_music_rounded, _sourcesTitle),
    SyncCategory.settings: (Icons.tune_rounded, _settingsTitle),
    SyncCategory.statistics: (Icons.insights_rounded, _statisticsTitle),
    SyncCategory.history: (Icons.history_rounded, _historyTitle),
    SyncCategory.session: (Icons.play_circle_outline_rounded, _sessionTitle),
    SyncCategory.credentials: (Icons.auto_awesome_rounded, _credentialsTitle),
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<SyncProvider>();
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.syncContentSection),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
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
            title: l10n.syncCellularSection,
            children: [
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
        ],
      ),
    );
  }
}
