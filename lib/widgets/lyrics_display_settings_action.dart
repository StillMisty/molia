import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../pages/lyrics_display/lyrics_content_settings_page.dart';
import '../utils/responsive.dart';

/// 打开「歌词显示设置」：歌词页 FAB 与播放器「更多」共用同一入口。
///
/// 抽成函数而不是各宿主各拼一遍：入口的页面标题 / 弹层档位 / 最大宽度是
/// 同一份口径，漏改一处会出现同一个设置页从不同入口打开后宽度不一致。
Future<void> showLyricsDisplaySettings(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    title: l10n.lyricsContentTitle,
    body: const LyricsContentSettingsPage(embedded: true),
    preferredMode: SecondaryPageMode.sideSheet,
    maxWidth: 520,
  );
}
