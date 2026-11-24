import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_access.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/theme/scheme_builder.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/settings_test_support.dart';

/// 配置模型：默认值 / JSON 往返 / 缺键合并 / 取值夹取 / 非法枚举回落。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认值：三个输出默认全关，共享开关默认合理', () {
    final s = LyricsDisplaySettings(settings: testSettingsRegistry());
    expect(s.state.desktopEnabled, isFalse);
    expect(s.state.notificationEnabled, isFalse);
    expect(s.state.bluetoothEnabled, isFalse);
    expect(s.state.translationEnabled, isTrue);
    expect(s.state.romaEnabled, isFalse);
    expect(s.state.pageTranslationEnabled, isTrue);
    expect(s.state.pageRomaEnabled, isFalse);
    expect(s.state.offsetMs, 0);
    // 默认只显示当前行（单行）。
    expect(s.state.desktopMaxLines, 1);
    expect(s.state.desktopFontSize, 22);
    // 默认暂停即整窗隐藏（恢复播放再显示）。
    expect(s.state.desktopHideOnPause, isTrue);
    // 默认跟随演唱（长行横向滚动的历史行为）。
    expect(s.state.desktopScrollMode, DesktopScrollMode.followSinging);
    // 默认直接跟随应用主题角色：当前行主色 / 其余行次要文本色 / 描边表面色。
    expect(s.state.desktopPlayedColorSource, LyricColorSource.primary);
    expect(
      s.state.desktopUnplayedColorSource,
      LyricColorSource.onSurfaceVariant,
    );
    expect(s.state.desktopShadowColorSource, LyricColorSource.surface);
    expect(s.state.notificationTarget, LyricsMetadataTarget.artist);
    expect(s.state.bluetoothTarget, LyricsMetadataTarget.artist);
    expect(s.state.bluetoothOnlyWhenA2dp, isTrue);
    expect(s.state.desktopControls.values.every((v) => v), isTrue);
  });

  test('toJson → init 往返保持全部配置', () async {
    final source = LyricsDisplaySettings(settings: testSettingsRegistry());
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
      LyricColorSource.onSurfaceVariant,
    );
    await source.setDesktopShadowColorSource(LyricColorSource.tertiary);
    await source.setDesktopSchemeSource(SurfaceColorSource.artwork);
    await source.setDesktopWidthPercent(80);
    await source.setDesktopMaxLines(4);
    await source.setDesktopTextAlignX(DesktopTextAlignX.left);
    await source.setDesktopLock(true);
    await source.setDesktopFreezeOnScreenOff(false);
    await source.setDesktopHideOnPause(false);
    await source.setDesktopPauseBehavior(LyricsPauseBehavior.clear);
    await source.setDesktopNoLyricsBehavior(DesktopNoLyricsBehavior.hide);
    await source.setDesktopShowToggleAnimation(false);
    await source.setDesktopScrollMode(DesktopScrollMode.constant);
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
    final restored = LyricsDisplaySettings(settings: testSettingsRegistry());
    await restored.init();

    expect(restored.state.offsetMs, -150);
    expect(restored.state.translationEnabled, isFalse);
    expect(restored.state.romaEnabled, isTrue);
    expect(restored.state.unsyncedBehavior, UnsyncedBehavior.firstLine);
    expect(restored.state.pageTranslationEnabled, isFalse);
    expect(restored.state.pageRomaEnabled, isTrue);
    expect(restored.state.desktopEnabled, isTrue);
    expect(restored.state.desktopFontSize, 31);
    expect(restored.state.desktopOpacity, 0.5);
    expect(restored.state.desktopPlayedColor, 0xFF00FF00);
    expect(restored.state.desktopShadowColor, 0xFF123456);
    expect(restored.state.desktopPlayedColorSource, LyricColorSource.primary);
    expect(
      restored.state.desktopUnplayedColorSource,
      LyricColorSource.onSurfaceVariant,
    );
    expect(restored.state.desktopShadowColorSource, LyricColorSource.tertiary);
    expect(restored.state.desktopSchemeSource, SurfaceColorSource.artwork);
    expect(restored.state.desktopWidthPercent, 80);
    expect(restored.state.desktopMaxLines, 4);
    expect(restored.state.desktopTextAlignX, DesktopTextAlignX.left);
    expect(restored.state.desktopLock, isTrue);
    expect(restored.state.desktopFreezeOnScreenOff, isFalse);
    expect(restored.state.desktopHideOnPause, isFalse);
    expect(restored.state.desktopPauseBehavior, LyricsPauseBehavior.clear);
    expect(
      restored.state.desktopNoLyricsBehavior,
      DesktopNoLyricsBehavior.hide,
    );
    expect(restored.state.desktopShowToggleAnimation, isFalse);
    expect(restored.state.desktopScrollMode, DesktopScrollMode.constant);
    expect(restored.state.desktopControls[DesktopControlKeys.next], isFalse);
    expect(restored.state.notificationEnabled, isTrue);
    expect(restored.state.notificationTarget, LyricsMetadataTarget.artist);
    expect(restored.state.notificationFormat, LyricsMetadataFormat.titleLyric);
    expect(restored.state.notificationIncludeTranslation, isFalse);
    expect(restored.state.notificationPauseBehavior, LyricsPauseBehavior.keep);
    expect(restored.state.bluetoothEnabled, isTrue);
    expect(restored.state.bluetoothOnlyWhenA2dp, isFalse);
    expect(restored.state.bluetoothTarget, LyricsMetadataTarget.title);
    expect(restored.state.bluetoothFormat, LyricsMetadataFormat.lyricTitle);
    expect(restored.state.bluetoothIncludeTranslation, isTrue);
    expect(restored.state.bluetoothUpdateIntervalMs, 1000);
    expect(restored.state.bluetoothPauseBehavior, LyricsPauseBehavior.keep);
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
    final s = LyricsDisplaySettings(settings: testSettingsRegistry());
    await s.init();
    expect(s.state.offsetMs, 100);
    expect(
      s.state.unsyncedBehavior,
      LyricsDisplaySettings.defaultUnsyncedBehavior,
    );
    expect(s.state.desktopMaxLines, LyricsDisplaySettings.maxLinesRange.last);
    expect(s.state.desktopEnabled, isFalse);
    // 旧数据没有 page.* 键：歌词页开关回落默认。
    expect(
      s.state.pageTranslationEnabled,
      LyricsDisplaySettings.defaultPageTranslationEnabled,
    );
    expect(
      s.state.pageRomaEnabled,
      LyricsDisplaySettings.defaultPageRomaEnabled,
    );
    // 旧数据没有 desktop.hideOnPause：回落默认（暂停即整窗隐藏）。
    expect(
      s.state.desktopHideOnPause,
      LyricsDisplaySettings.defaultDesktopHideOnPause,
    );
    // 旧数据没有 desktop.scrollMode：回落默认（跟随演唱）。
    expect(
      s.state.desktopScrollMode,
      LyricsDisplaySettings.defaultDesktopScrollMode,
    );
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
    final s = LyricsDisplaySettings(settings: testSettingsRegistry());
    await s.init();
    expect(s.state.translationEnabled, isFalse);
    expect(s.state.romaEnabled, isTrue);
    expect(s.state.pageTranslationEnabled, isTrue);
    expect(s.state.pageRomaEnabled, isFalse);

    await s.setPageTranslationEnabled(false);
    expect(s.state.translationEnabled, isFalse);
    await s.setPageRomaEnabled(true);
    expect(s.state.romaEnabled, isTrue);
  });

  test('范围夹取', () async {
    final s = LyricsDisplaySettings(settings: testSettingsRegistry());
    await s.setOffsetMs(9999);
    expect(s.state.offsetMs, LyricsDisplaySettings.offsetRange.last);
    await s.setDesktopFontSize(1);
    expect(s.state.desktopFontSize, LyricsDisplaySettings.fontSizeRange.first);
    await s.setDesktopOpacity(0.01);
    expect(s.state.desktopOpacity, LyricsDisplaySettings.opacityRange.first);
    await s.setBluetoothUpdateIntervalMs(123);
    expect(
      s.state.bluetoothUpdateIntervalMs,
      LyricsDisplaySettings.defaultBluetoothUpdateIntervalMs,
    );
  });

  group('连续滑杆防抖落盘', () {
    test('persist: false 的连续更新合并为一次 flush 写入，且写最新状态', () async {
      final access = _RecordingSettingsAccess();
      final s = LyricsDisplaySettings(settings: access);

      await s.setOffsetMs(50, persist: false);
      await s.setOffsetMs(150, persist: false);
      await s.setDesktopFontSize(30, persist: false);
      await s.setDesktopOpacity(0.6, persist: false);
      await s.setDesktopWidthPercent(70, persist: false);

      expect(access.writes, isEmpty, reason: '防抖窗口内不落盘');
      expect(s.state.offsetMs, 150);

      await s.flushPersistence();

      expect(access.writes, [kLyricsDisplaySettings.name]);
      final json = jsonDecode(
        access.raw(kLyricsDisplaySettings.name)!,
      ) as Map<String, dynamic>;
      expect(json['offsetMs'], 150);
      expect(json['desktop.fontSize'], 30);
      expect(json['desktop.opacity'], 0.6);
      expect(json['desktop.widthPercent'], 70);
    });

    test('没有待写状态时 flush 不重复整文件写入', () async {
      final access = _RecordingSettingsAccess();
      final s = LyricsDisplaySettings(settings: access);

      await s.setOffsetMs(50);
      expect(access.writes, [kLyricsDisplaySettings.name]);

      await s.flushPersistence();
      expect(access.writes, hasLength(1), reason: '已落盘状态不应再次写入');
      s.dispose();
    });

    test('防抖计时到点只写一次；dispose 不重复写已落盘状态', () {
      fakeAsync((async) {
        final access = _RecordingSettingsAccess();
        final s = LyricsDisplaySettings(settings: access);

        unawaited(s.setOffsetMs(50, persist: false));
        unawaited(s.setOffsetMs(100, persist: false));
        async.flushMicrotasks();
        expect(access.writes, isEmpty);

        async.elapse(LyricsDisplaySettings.persistenceDebounce);
        async.flushMicrotasks();

        expect(access.writes, [kLyricsDisplaySettings.name]);
        final json = jsonDecode(
          access.raw(kLyricsDisplaySettings.name)!,
        ) as Map<String, dynamic>;
        expect(json['offsetMs'], 100);

        s.dispose();
        async.flushMicrotasks();
        expect(access.writes, hasLength(1));
      });
    });

    test('离散设置仍立即落盘，并覆盖滑杆留下的防抖计时', () {
      fakeAsync((async) {
        final access = _RecordingSettingsAccess();
        final s = LyricsDisplaySettings(settings: access);

        unawaited(s.setOffsetMs(50, persist: false));
        unawaited(s.setTranslationEnabled(false));
        async.flushMicrotasks();

        expect(access.writes, [kLyricsDisplaySettings.name]);
        final json = jsonDecode(
          access.raw(kLyricsDisplaySettings.name)!,
        ) as Map<String, dynamic>;
        expect(json['translationEnabled'], isFalse);
        expect(json['offsetMs'], 50, reason: '立即写包含尚未落盘的滑杆状态');

        // 已取消的防抖计时不应再追加一次整文件写入。
        async.elapse(LyricsDisplaySettings.persistenceDebounce * 2);
        async.flushMicrotasks();
        expect(access.writes, hasLength(1));

        s.dispose();
        async.flushMicrotasks();
      });
    });

    test('dispose 取消未到期的防抖计时并补写 pending 状态', () {
      fakeAsync((async) {
        final access = _RecordingSettingsAccess();
        final s = LyricsDisplaySettings(settings: access);

        unawaited(s.setOffsetMs(75, persist: false));
        async.flushMicrotasks();
        expect(access.writes, isEmpty);

        s.dispose();
        async.flushMicrotasks();

        expect(access.writes, [kLyricsDisplaySettings.name]);
        final json = jsonDecode(
          access.raw(kLyricsDisplaySettings.name)!,
        ) as Map<String, dynamic>;
        expect(json['offsetMs'], 75);

        async.elapse(LyricsDisplaySettings.persistenceDebounce * 2);
        async.flushMicrotasks();
        expect(access.writes, hasLength(1), reason: '释放后计时已取消');
      });
    });
  });
}

/// 记录写入次数与最新 JSON 的设置访问面（不触碰 SharedPreferences）。
class _RecordingSettingsAccess implements SettingsAccess {
  final Map<String, Object?> values = {};
  final List<String> writes = [];

  String? raw(String key) => values[key] as String?;

  @override
  Future<T> read<T extends Object?>(SettingsKey<T> key) async =>
      (values[key.name] as T?) ?? key.defaultValue;

  @override
  Future<bool> contains(SettingsKey<Object?> key) async =>
      values.containsKey(key.name);

  @override
  Future<void> write<T extends Object?>(SettingsKey<T> key, T value) {
    writes.add(key.name);
    values[key.name] = value;
    return Future.value();
  }

  @override
  Future<void> clear(SettingsKey<Object?> key) async {
    values.remove(key.name);
  }
}
