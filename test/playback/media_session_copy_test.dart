/// 系统媒体会话文案：生产来源跟随界面语言，纯值映射到通知动作。
library;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/media_session_copy.dart';
import 'package:molia/playback/media_session_copy_source.dart';
import 'package:molia/services/language_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    LanguageService.localeNotifier.value = null;
  });

  test('MediaSessionCopy：取自生成的 l10n，动作文案反映当前状态', () {
    final copy =
        MediaSessionCopy.of(lookupAppLocalizations(const Locale('zh')));

    expect(copy.unknownArtist, '未知歌手');
    expect(copy.favoriteLabel(favorite: false), '收藏');
    expect(copy.favoriteLabel(favorite: true), '取消收藏');
    expect(copy.playModeLabel(PlayMode.listLoop), '列表循环');
    expect(copy.playModeLabel(PlayMode.sequential), '顺序播放');
    expect(copy.playModeLabel(PlayMode.singleRepeat), '单曲循环');
    expect(copy.playModeLabel(PlayMode.shuffle), '随机播放');
  });

  test('LocalizedMediaSessionCopy：语言切换后重算并通知', () {
    LanguageService.localeNotifier.value = const Locale('zh');
    final source = LocalizedMediaSessionCopy();
    addTearDown(source.dispose);
    expect(source.value.unknownArtist, '未知歌手');

    var notifies = 0;
    source.addListener(() => notifies++);

    LanguageService.localeNotifier.value = const Locale('en');

    expect(source.value.unknownArtist, 'Unknown artist');
    expect(source.value.playModeLabel(PlayMode.sequential), 'Sequential');
    expect(notifies, 1, reason: '语言切换只触发一次重算通知');
  });
}
