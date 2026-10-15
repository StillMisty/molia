import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/theme/scheme_builder.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配置模型：默认值 / JSON 往返 / 缺键合并 / 取值夹取 / 非法枚举回落。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认值：三个输出默认全关，共享开关默认合理', () {
    final s = LyricsDisplaySettings();
    expect(s.desktopEnabled, isFalse);
    expect(s.notificationEnabled, isFalse);
    expect(s.bluetoothEnabled, isFalse);
    expect(s.translationEnabled, isTrue);
    expect(s.romaEnabled, isFalse);
    expect(s.pageTranslationEnabled, isTrue);
    expect(s.pageRomaEnabled, isFalse);
    expect(s.offsetMs, 0);
    // 默认只显示当前行（旧的「仅显示当前行」开关已并入显示行数）。
    expect(s.desktopMaxLines, 1);
    expect(s.desktopFontSize, 22);
    // 默认暂停即整窗隐藏（恢复播放再显示）。
    expect(s.desktopHideOnPause, isTrue);
    // 默认直接跟随应用主题角色：当前行主色 / 其余行次要文本色 / 描边表面色。
    expect(s.desktopPlayedColorSource, LyricColorSource.primary);
    expect(s.desktopUnplayedColorSource, LyricColorSource.onSurfaceVariant);
    expect(s.desktopShadowColorSource, LyricColorSource.surface);
    expect(s.notificationTarget, LyricsMetadataTarget.artist);
    expect(s.bluetoothTarget, LyricsMetadataTarget.artist);
    expect(s.bluetoothOnlyWhenA2dp, isTrue);
    expect(s.desktopControls.values.every((v) => v), isTrue);
  });

  test('toJson → init 往返保持全部配置', () async {
    final source = LyricsDisplaySettings();
    await source.setOffsetMs(-150);
    await source.setTranslationEnabled(false);
    await source.setRomaEnabled(true);
    await source.setUnsyncedBehavior(UnsyncedBehavior.firstLine);
    await source.setPageTranslationEnabled(false);
    await source.setPageRomaEnabled(true);
    await source.setDesktopEnabled(true);
    await source.setDesktopFontSize(31);
    await source.setDesktopOpacity(0.5);
    await source.setDesktopPlayedColor(0xFF00FF00);
    await source.setDesktopShadowColor(0xFF123456);
    await source.setDesktopPlayedColorSource(LyricColorSource.primary);
    await source.setDesktopUnplayedColorSource(
        LyricColorSource.onSurfaceVariant);
    await source.setDesktopShadowColorSource(LyricColorSource.tertiary);
    await source.setDesktopSchemeSource(SurfaceColorSource.artwork);
    await source.setDesktopWidthPercent(80);
    await source.setDesktopMaxLines(4);
    await source.setDesktopTextAlignX(DesktopTextAlignX.left);
    await source.setDesktopTextAlignY(DesktopTextAlignY.bottom);
    await source.setDesktopLock(true);
    await source.setDesktopFreezeOnScreenOff(false);
    await source.setDesktopHideOnPause(false);
    await source.setDesktopPauseBehavior(LyricsPauseBehavior.clear);
    await source.setDesktopNoLyricsBehavior(DesktopNoLyricsBehavior.hide);
    await source.setDesktopShowToggleAnimation(false);
    await source.setDesktopControlVisible(DesktopControlKeys.next, false);
    await source.setNotificationEnabled(true);
    await source.setNotificationTarget(LyricsMetadataTarget.artist);
    await source.setNotificationFormat(LyricsMetadataFormat.titleLyric);
    await source.setNotificationIncludeTranslation(false);
    await source.setNotificationPauseBehavior(LyricsPauseBehavior.keep);
    await source.setBluetoothEnabled(true);
    await source.setBluetoothOnlyWhenA2dp(false);
    await source.setBluetoothTarget(LyricsMetadataTarget.title);
    await source.setBluetoothFormat(LyricsMetadataFormat.lyricTitle);
    await source.setBluetoothIncludeTranslation(true);
    await source.setBluetoothUpdateIntervalMs(1000);
    await source.setBluetoothPauseBehavior(LyricsPauseBehavior.keep);

    SharedPreferences.setMockInitialValues({
      kLyricsDisplaySettings.name: jsonEncode(source.toJson()),
    });
    final restored = LyricsDisplaySettings();
    await restored.init();

    expect(restored.offsetMs, -150);
    expect(restored.translationEnabled, isFalse);
    expect(restored.romaEnabled, isTrue);
    expect(restored.unsyncedBehavior, UnsyncedBehavior.firstLine);
    expect(restored.pageTranslationEnabled, isFalse);
    expect(restored.pageRomaEnabled, isTrue);
    expect(restored.desktopEnabled, isTrue);
    expect(restored.desktopFontSize, 31);
    expect(restored.desktopOpacity, 0.5);
    expect(restored.desktopPlayedColor, 0xFF00FF00);
    expect(restored.desktopShadowColor, 0xFF123456);
    expect(restored.desktopPlayedColorSource, LyricColorSource.primary);
    expect(restored.desktopUnplayedColorSource,
        LyricColorSource.onSurfaceVariant);
    expect(restored.desktopShadowColorSource, LyricColorSource.tertiary);
    expect(restored.desktopSchemeSource, SurfaceColorSource.artwork);
    expect(restored.desktopWidthPercent, 80);
    expect(restored.desktopMaxLines, 4);
    expect(restored.desktopTextAlignX, DesktopTextAlignX.left);
    expect(restored.desktopTextAlignY, DesktopTextAlignY.bottom);
    expect(restored.desktopLock, isTrue);
    expect(restored.desktopFreezeOnScreenOff, isFalse);
    expect(restored.desktopHideOnPause, isFalse);
    expect(restored.desktopPauseBehavior, LyricsPauseBehavior.clear);
    expect(restored.desktopNoLyricsBehavior, DesktopNoLyricsBehavior.hide);
    expect(restored.desktopShowToggleAnimation, isFalse);
    expect(restored.desktopControls[DesktopControlKeys.next], isFalse);
    expect(restored.notificationEnabled, isTrue);
    expect(restored.notificationTarget, LyricsMetadataTarget.artist);
    expect(restored.notificationFormat, LyricsMetadataFormat.titleLyric);
    expect(restored.notificationIncludeTranslation, isFalse);
    expect(restored.notificationPauseBehavior, LyricsPauseBehavior.keep);
    expect(restored.bluetoothEnabled, isTrue);
    expect(restored.bluetoothOnlyWhenA2dp, isFalse);
    expect(restored.bluetoothTarget, LyricsMetadataTarget.title);
    expect(restored.bluetoothFormat, LyricsMetadataFormat.lyricTitle);
    expect(restored.bluetoothIncludeTranslation, isTrue);
    expect(restored.bluetoothUpdateIntervalMs, 1000);
    expect(restored.bluetoothPauseBehavior, LyricsPauseBehavior.keep);
  });

  test('缺键 / 非法值回落默认值（版本向前兼容）', () async {
    SharedPreferences.setMockInitialValues({
      kLyricsDisplaySettings.name: jsonEncode({
        'version': 1,
        'offsetMs': 100,
        'unsyncedBehavior': 'not-a-real-value',
        'desktop.maxLines': 99,
      }),
    });
    final s = LyricsDisplaySettings();
    await s.init();
    expect(s.offsetMs, 100);
    expect(s.unsyncedBehavior, LyricsDisplaySettings.defaultUnsyncedBehavior);
    expect(s.desktopMaxLines, LyricsDisplaySettings.maxLinesRange.last);
    expect(s.desktopEnabled, isFalse);
    // 旧数据没有 page.* 键：歌词页开关回落默认。
    expect(s.pageTranslationEnabled,
        LyricsDisplaySettings.defaultPageTranslationEnabled);
    expect(s.pageRomaEnabled, LyricsDisplaySettings.defaultPageRomaEnabled);
    // 旧数据没有 desktop.hideOnPause：回落默认（暂停即整窗隐藏）。
    expect(s.desktopHideOnPause,
        LyricsDisplaySettings.defaultDesktopHideOnPause);
  });

  test('旧配置兼容：singleLine=true 一次性映射为显示行数 1', () async {
    SharedPreferences.setMockInitialValues({
      kLyricsDisplaySettings.name: jsonEncode({
        'version': 1,
        'desktop.singleLine': true,
        'desktop.maxLines': 3,
      }),
    });
    final s = LyricsDisplaySettings();
    await s.init();
    expect(s.desktopMaxLines, 1);

    // singleLine=false 的旧配置保持原显示行数（只改默认、不做其它迁移）。
    SharedPreferences.setMockInitialValues({
      kLyricsDisplaySettings.name: jsonEncode({
        'version': 1,
        'desktop.singleLine': false,
        'desktop.maxLines': 3,
      }),
    });
    final kept = LyricsDisplaySettings();
    await kept.init();
    expect(kept.desktopMaxLines, 3);
  });

  test('歌词页开关与输出侧开关相互独立', () async {
    SharedPreferences.setMockInitialValues({
      kLyricsDisplaySettings.name: jsonEncode({
        'version': 1,
        'translationEnabled': false,
        'romaEnabled': true,
        'page.translationEnabled': true,
        'page.romaEnabled': false,
      }),
    });
    final s = LyricsDisplaySettings();
    await s.init();
    expect(s.translationEnabled, isFalse);
    expect(s.romaEnabled, isTrue);
    expect(s.pageTranslationEnabled, isTrue);
    expect(s.pageRomaEnabled, isFalse);

    await s.setPageTranslationEnabled(false);
    expect(s.translationEnabled, isFalse);
    await s.setPageRomaEnabled(true);
    expect(s.romaEnabled, isTrue);
  });

  test('范围夹取', () async {
    final s = LyricsDisplaySettings();
    await s.setOffsetMs(9999);
    expect(s.offsetMs, LyricsDisplaySettings.offsetRange.last);
    await s.setDesktopFontSize(1);
    expect(s.desktopFontSize, LyricsDisplaySettings.fontSizeRange.first);
    await s.setDesktopOpacity(0.01);
    expect(s.desktopOpacity, LyricsDisplaySettings.opacityRange.first);
    await s.setBluetoothUpdateIntervalMs(123);
    expect(
      s.bluetoothUpdateIntervalMs,
      LyricsDisplaySettings.defaultBluetoothUpdateIntervalMs,
    );
  });
}
