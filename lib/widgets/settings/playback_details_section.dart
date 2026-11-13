import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/playback_feel.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/playback_provider.dart';
import 'settings_tiles.dart';

/// 播放细节卡：淡入淡出档位 + 随机播放少放最近听过的歌。
///
/// 单独成卡而不是塞进「播放」：两张卡各自是一类偏好（播放行为 vs 听感），
/// 也避免播放卡在移动端变得过长。两项都是设备本地值，不随同步。
class PlaybackDetailsSection extends StatelessWidget {
  const PlaybackDetailsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsSectionCard(
      title: l10n.settingsPlaybackDetailsTitle,
      children: [
        Selector<PlaybackProvider, PlaybackFadePreset>(
          selector: (context, provider) => provider.fadePreset,
          builder: (context, preset, _) =>
              SettingsChoiceRow<PlaybackFadePreset>(
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
      ],
    );
  }
}
