import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/settings/settings_tiles.dart';
import 'lyrics_shared_display_section.dart';

/// 歌词输出子页：所有输出（悬浮窗 / 通知 / 蓝牙）共用的展示策略。
///
/// 翻译、罗马音、偏移与未同步回退都在 Dart 侧统一应用（见
/// `LyricsDisplayProvider`），所以这里改一次全输出生效；行组件与桌面歌词
/// 页内联的共享分组同源。
class LyricsOutputSettingsPage extends StatelessWidget {
  const LyricsOutputSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.lyricsDisplaySharedTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: const [
          LyricsSharedDisplaySection(),
        ],
      ),
    );
  }
}
