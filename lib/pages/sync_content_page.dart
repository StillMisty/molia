import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/device_sync.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// 同步内容子页：类别开关 + 移动数据策略。
///
/// 首屏只留「全部类别 / 已关闭 N 项」结论，逐类别取舍放这里（类别是
/// 「同步什么」的细节，不是首屏决策）。类别行只保留标题和开关：关闭后果
/// 在卡片 footer 说明一次，避免八行重复同一句副标题把列表撑长。
class SyncContentPage extends StatelessWidget {
  const SyncContentPage({super.key});

  /// 展示顺序：媒体内容在前，设置与记录居中，凭证靠后；自定义封面体积大，
  /// 入口紧跟在音源之后，方便用户单独关掉而不必翻到列表末尾。
  static const Map<SyncCategory, (IconData, String Function(AppLocalizations))>
      _categoryOrder = {
    SyncCategory.playlists: (Icons.queue_music_rounded, _playlistsTitle),
    SyncCategory.sources: (Icons.library_music_rounded, _sourcesTitle),
    SyncCategory.covers: (Icons.image_rounded, _coversTitle),
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

  static String _coversTitle(AppLocalizations l10n) => l10n.syncCategoryCovers;

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
    return SettingsSubPage(
      title: l10n.syncContentSection,
      children: [
        SettingsSectionCard(
          // 页面标题已经说明这是「同步内容」，卡片不再重复一层标题。
          footer: SettingsSectionHint(text: l10n.syncCategorySubtitle),
          children: [
            for (final entry in _categoryOrder.entries)
              SettingsSwitchTile(
                switchKey: Key('settingsSyncCategory-${entry.key.name}'),
                icon: entry.value.$1,
                title: entry.value.$2(l10n),
                // 关闭后果集中在 footer；不逐行重复同一句话。
                subtitle: '',
                value: provider.categories[entry.key] ??
                    entry.key.defaultEnabled,
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
    );
  }
}
