import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_display/media_lyric_composer.dart';
import 'package:molia/services/lyrics_display/lyrics_output.dart';

/// 媒体元数据歌词合成：字段映射 / 格式 / 翻译 / A2DP 门控 / 优先级 / 暂停回退。
void main() {
  const composer = MediaLyricComposer();

  LyricsPresentation presentation({
    String line = '歌词行',
    List<String> extended = const [],
    bool isPlaying = true,
    bool hasLyrics = true,
    String title = '歌名',
  }) =>
      LyricsPresentation(
        trackId: 'fake:1',
        title: title,
        line: line,
        extended: extended,
        isPlaying: isPlaying,
        hasLyrics: hasLyrics,
      );

  Future<LyricsDisplaySettings> settings({
    bool notification = false,
    LyricsMetadataTarget notificationTarget = LyricsMetadataTarget.subtitle,
    LyricsMetadataFormat notificationFormat = LyricsMetadataFormat.lyric,
    bool notificationTranslation = false,
    LyricsPauseBehavior notificationPause = LyricsPauseBehavior.title,
    bool bluetooth = false,
    bool onlyWhenA2dp = true,
    LyricsMetadataTarget bluetoothTarget = LyricsMetadataTarget.artist,
    LyricsMetadataFormat bluetoothFormat = LyricsMetadataFormat.lyric,
    bool bluetoothTranslation = false,
    LyricsPauseBehavior bluetoothPause = LyricsPauseBehavior.title,
  }) async {
    final s = LyricsDisplaySettings();
    await s.setNotificationEnabled(notification);
    await s.setNotificationTarget(notificationTarget);
    await s.setNotificationFormat(notificationFormat);
    await s.setNotificationIncludeTranslation(notificationTranslation);
    await s.setNotificationPauseBehavior(notificationPause);
    await s.setBluetoothEnabled(bluetooth);
    await s.setBluetoothOnlyWhenA2dp(onlyWhenA2dp);
    await s.setBluetoothTarget(bluetoothTarget);
    await s.setBluetoothFormat(bluetoothFormat);
    await s.setBluetoothIncludeTranslation(bluetoothTranslation);
    await s.setBluetoothPauseBehavior(bluetoothPause);
    return s;
  }

  test('通知 profile 默认写副标题，其他字段保持原值', () async {
    final s = await settings(notification: true);
    final override = composer.compose(
      presentation: presentation(),
      settings: s,
      a2dpConnected: false,
    );
    expect(override, isNotNull);
    expect(override!.displaySubtitle, '歌词行');
    expect(override.artist, isNull);
    expect(override.title, isNull);
    expect(override.album, isNull);
  });

  test('翻译按开关拼接', () async {
    final withTranslation =
        await settings(notification: true, notificationTranslation: true);
    final override = composer.compose(
      presentation: presentation(extended: ['翻译']),
      settings: withTranslation,
      a2dpConnected: false,
    );
    expect(override!.displaySubtitle, '歌词行 / 翻译');

    final withoutTranslation = await settings(notification: true);
    final plain = composer.compose(
      presentation: presentation(extended: ['翻译']),
      settings: withoutTranslation,
      a2dpConnected: false,
    );
    expect(plain!.displaySubtitle, '歌词行');
  });

  test('格式：歌词·歌名 / 歌名·歌词', () async {
    final lyricTitle = await settings(
      notification: true,
      notificationFormat: LyricsMetadataFormat.lyricTitle,
    );
    expect(
      composer
          .compose(
            presentation: presentation(),
            settings: lyricTitle,
            a2dpConnected: false,
          )!
          .displaySubtitle,
      '歌词行 · 歌名',
    );

    final titleLyric = await settings(
      notification: true,
      notificationFormat: LyricsMetadataFormat.titleLyric,
    );
    expect(
      composer
          .compose(
            presentation: presentation(),
            settings: titleLyric,
            a2dpConnected: false,
          )!
          .displaySubtitle,
      '歌名 · 歌词行',
    );
  });

  test('蓝牙 profile 受 A2DP 门控；仅蓝牙开启且未连接时无覆盖', () async {
    final s = await settings(bluetooth: true, onlyWhenA2dp: true);
    expect(
      composer.compose(
        presentation: presentation(),
        settings: s,
        a2dpConnected: false,
      ),
      isNull,
    );
    expect(
      composer
          .compose(
            presentation: presentation(),
            settings: s,
            a2dpConnected: true,
          )!
          .artist,
      '歌词行',
    );
  });

  test('关闭门控后蓝牙歌词始终生效', () async {
    final s = await settings(bluetooth: true, onlyWhenA2dp: false);
    expect(
      composer
          .compose(
            presentation: presentation(),
            settings: s,
            a2dpConnected: false,
          )!
          .artist,
      '歌词行',
    );
  });

  test('同字段冲突时蓝牙优先', () async {
    final s = await settings(
      notification: true,
      notificationTarget: LyricsMetadataTarget.artist,
      bluetooth: true,
      onlyWhenA2dp: false,
      bluetoothTarget: LyricsMetadataTarget.artist,
      bluetoothFormat: LyricsMetadataFormat.lyricTitle,
    );
    final override = composer.compose(
      presentation: presentation(),
      settings: s,
      a2dpConnected: false,
    );
    expect(override!.artist, '歌词行 · 歌名');
  });

  test('暂停回退：保留 / 显示歌名 / 清空', () async {
    final keep = await settings(
      notification: true,
      notificationPause: LyricsPauseBehavior.keep,
    );
    expect(
      composer
          .compose(
            presentation: presentation(isPlaying: false),
            settings: keep,
            a2dpConnected: false,
          )!
          .displaySubtitle,
      '歌词行',
    );

    final showTitle = await settings(notification: true);
    expect(
      composer
          .compose(
            presentation: presentation(isPlaying: false),
            settings: showTitle,
            a2dpConnected: false,
          )!
          .displaySubtitle,
      '歌名',
    );

    final clear = await settings(
      notification: true,
      notificationPause: LyricsPauseBehavior.clear,
    );
    expect(
      composer.compose(
        presentation: presentation(isPlaying: false),
        settings: clear,
        a2dpConnected: false,
      ),
      isNull,
    );
  });

  test('无歌词 / 前奏空行不写覆盖（保持原始元数据）', () async {
    final s = await settings(notification: true);
    expect(
      composer.compose(
        presentation: presentation(hasLyrics: false),
        settings: s,
        a2dpConnected: false,
      ),
      isNull,
    );
    expect(
      composer.compose(
        presentation: presentation(line: ''),
        settings: s,
        a2dpConnected: false,
      ),
      isNull,
    );
  });
}
