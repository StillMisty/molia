import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
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
    expect(s.offsetMs, 0);
    expect(s.desktopMaxLines, 3);
    expect(s.desktopFontSize, 22);
    expect(s.notificationTarget, LyricsMetadataTarget.subtitle);
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
    await source.setDesktopEnabled(true);
    await source.setDesktopFontSize(31);
    await source.setDesktopOpacity(0.5);
    await source.setDesktopPlayedColor(0xFF00FF00);
    await source.setDesktopShadowColor(0xFF123456);
    await source.setDesktopWidthPercent(80);
    await source.setDesktopSingleLine(true);
    await source.setDesktopTextAlignX(DesktopTextAlignX.left);
    await source.setDesktopTextAlignY(DesktopTextAlignY.bottom);
    await source.setDesktopLock(true);
    await source.setDesktopFreezeOnScreenOff(false);
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
      LyricsDisplaySettings.storageKey: jsonEncode(source.toJson()),
    });
    final restored = LyricsDisplaySettings();
    await restored.init();

    expect(restored.offsetMs, -150);
    expect(restored.translationEnabled, isFalse);
    expect(restored.romaEnabled, isTrue);
    expect(restored.unsyncedBehavior, UnsyncedBehavior.firstLine);
    expect(restored.desktopEnabled, isTrue);
    expect(restored.desktopFontSize, 31);
    expect(restored.desktopOpacity, 0.5);
    expect(restored.desktopPlayedColor, 0xFF00FF00);
    expect(restored.desktopShadowColor, 0xFF123456);
    expect(restored.desktopWidthPercent, 80);
    expect(restored.desktopSingleLine, isTrue);
    expect(restored.desktopTextAlignX, DesktopTextAlignX.left);
    expect(restored.desktopTextAlignY, DesktopTextAlignY.bottom);
    expect(restored.desktopLock, isTrue);
    expect(restored.desktopFreezeOnScreenOff, isFalse);
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
      LyricsDisplaySettings.storageKey: jsonEncode({
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
