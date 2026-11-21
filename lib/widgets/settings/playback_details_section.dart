import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/playback_feel.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/nav_provider.dart';
import '../../providers/playback_provider.dart';
import 'settings_tiles.dart';

/// 播放细节行：淡入淡出档位 + 随机播放少放最近听过的歌 +
/// 从其它一级页进入播放页时是否固定歌词。
///
/// 首屏「播放」卡直接把这些行铺进同一张卡（[rows]），独立挂载（测试 / 旧
/// 入口）时仍是一张自带标题的卡。前两项是设备本地值，不随同步；歌词偏好
/// 跟人走（由 [NavProvider] 持有）。
class PlaybackDetailsSection extends StatelessWidget {
  const PlaybackDetailsSection({super.key});

  /// 播放细节的两行（供设置首屏并入「播放」卡）。
  ///
  /// 必须返回扁平的行列表，让外层 [SettingsSectionCard] 统一下发行形状；
  /// 不要在卡内再套一层 [SettingsRows]（会重置首末形状）。
  static List<Widget> rows(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final nav = context.read<NavProvider?>();
    return [
      Selector<PlaybackProvider, PlaybackFadePreset>(
        selector: (context, provider) => provider.fadePreset,
        builder: (context, preset, _) => SettingsChoiceRow<PlaybackFadePreset>(
          key: const Key('settingsFadeItem'),
          icon: Icons.volume_up_rounded,
          title: l10n.settingsFadeTitle,
          subtitle: l10n.settingsFadeSubtitle,
          value: preset,
          options: [
            (PlaybackFadePreset.off, l10n.settingsFadeOff),
            (PlaybackFadePreset.ms150, l10n.settingsFade150),
            (PlaybackFadePreset.ms200, l10n.settingsFade200),
            (PlaybackFadePreset.ms300, l10n.settingsFade300),
          ],
          onChanged: (value) =>
              context.read<PlaybackProvider>().setFadePreset(value),
        ),
      ),
      Selector<PlaybackProvider, bool>(
        selector: (context, provider) => provider.smartShuffleEnabled,
        builder: (context, enabled, _) => SettingsSwitchTile(
          switchKey: const Key('settingsSmartShuffleSwitch'),
          icon: Icons.shuffle_rounded,
          title: l10n.settingsSmartShuffleTitle,
          subtitle: l10n.settingsSmartShuffleSubtitle,
          value: enabled,
          onChanged: (value) =>
              context.read<PlaybackProvider>().setSmartShuffleEnabled(value),
        ),
      ),
      // 没有挂 NavProvider 的独立挂载（旧入口 / 精简测试）隐藏该行，
      // 而不是让整张卡构建失败。
      if (nav != null)
        Selector<NavProvider, bool>(
          selector: (context, provider) => provider.showLyricsOnEnter,
          builder: (context, enabled, _) => SettingsSwitchTile(
            switchKey: const Key('settingsReturnToPlayerLyricsSwitch'),
            icon: Icons.lyrics_rounded,
            title: l10n.settingsReturnToPlayerLyricsTitle,
            subtitle: l10n.settingsReturnToPlayerLyricsSubtitle,
            value: enabled,
            onChanged: (value) =>
                context.read<NavProvider>().setShowLyricsOnEnter(value),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      title: AppLocalizations.of(context)!.settingsPlaybackDetailsTitle,
      children: rows(context),
    );
  }
}
