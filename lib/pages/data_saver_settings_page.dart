import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/data_saver_service.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/source_quality_label.dart';

/// 省流模式子页：总开关 + 生效时的音质上限与封面省流。
///
/// 入口在设置首屏「播放」区（副标题带当前网络状态）；本页只做策略读写，
/// 生效判定与取链 / 封面网关都在 [DataSaverService] 消费侧。
class DataSaverSettingsPage extends StatelessWidget {
  const DataSaverSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 测试等场景可能不提供 provider：显示空页而不是崩溃（入口行同样隐藏）。
    final dataSaver = context.watch<DataSaverService?>();

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.settingsDataSaverTitle),
        automaticallyImplyLeading: true,
      ),
      body: dataSaver == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.all(kSettingsPadding),
              children: [
                SettingsSectionCard(
                  children: [
                    SettingsSwitchTile(
                      switchKey: const Key('settingsDataSaverSwitch'),
                      icon: Icons.data_saver_on_rounded,
                      title: l10n.settingsDataSaverTitle,
                      subtitle: _statusSubtitle(l10n, dataSaver),
                      value: dataSaver.enabled,
                      onChanged: (value) => dataSaver.setEnabled(value),
                    ),
                    if (dataSaver.enabled) ...[
                      SettingsChoiceRow<String>(
                        key: const Key('settingsDataSaverQualityItem'),
                        icon: Icons.graphic_eq_rounded,
                        title: l10n.settingsDataSaverQuality,
                        value: dataSaver.qualityCap,
                        options: [
                          for (final option in DataSaverService.qualityOptions)
                            (option, sourceQualityLabel(l10n, option)),
                        ],
                        onChanged: (value) => dataSaver.setQualityCap(value),
                      ),
                      SettingsSwitchTile(
                        switchKey: const Key('settingsDataSaverCoversSwitch'),
                        icon: Icons.image_rounded,
                        title: l10n.settingsDataSaverCovers,
                        subtitle: l10n.settingsDataSaverCoversSubtitle,
                        value: dataSaver.coversSaverEnabled,
                        onChanged: (value) =>
                            dataSaver.setCoversSaverEnabled(value),
                      ),
                    ],
                  ],
                ),
              ],
            ),
    );
  }

  /// 生效状态副标题：仅移动数据生效，网络状态对用户透明。
  String _statusSubtitle(AppLocalizations l10n, DataSaverService dataSaver) {
    final status = !dataSaver.detectionAvailable
        ? l10n.settingsDataSaverNetworkUnknown
        : (dataSaver.onCellular
            ? l10n.settingsDataSaverNetworkCellular
            : l10n.settingsDataSaverNetworkWifi);
    return dataSaver.enabled
        ? '${l10n.settingsDataSaverSubtitle} · $status'
        : l10n.settingsDataSaverSubtitle;
  }
}
