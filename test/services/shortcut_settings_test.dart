import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/services/shortcut_bindings.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:molia/services/shortcuts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/settings_test_support.dart';

/// 快捷键设置服务：默认值、持久化往返、校验与冲突拒绝、整组恢复默认。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    ShortcutSettings.attachSettings(testSettingsRegistry(preferences: prefs));
    await ShortcutSettings.load();
  });

  test('默认值：软件内开、全局关、无覆盖', () {
    final settings = ShortcutSettings.instance;
    expect(settings.inAppEnabled, isTrue);
    expect(settings.globalEnabled, isFalse);
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );
    expect(settings.inAppBindings.encode(), '');
    expect(settings.globalBindings.encode(), '');
  });

  test('全局默认键全部落在平台可注册的键集内', () {
    // system_hotkeys 只接受字母 / 数字 / F1–F12 / 空格（macOS 与 Windows 的
    // 系统 API 限制）：默认值里混入方向键这类键，会让用户一开启全局热键
    // 就整组 unsupported。默认值随模型改，这条测试跟着兜底。
    for (final entry in ShortcutBindings.globalDefaults.entries) {
      expect(
        ShortcutSettings.isComboSupported(ShortcutScope.global, entry.value),
        isTrue,
        reason: '${entry.key.name} 的默认组合不可注册',
      );
    }
  });

  test('setInAppEnabled：写登记键并可重新载入读回', () async {
    await ShortcutSettings.instance.setInAppEnabled(false);

    expect(ShortcutSettings.instance.inAppEnabled, isFalse);
    expect(prefs.getBool(kShortcutsEnabled.name), isFalse);

    // 重新载入（等价重启 / 应用远端值）：读到持久化的关闭态。
    await ShortcutSettings.reload();
    expect(ShortcutSettings.instance.inAppEnabled, isFalse);
  });

  test('setBinding：写入覆盖、序列化到设置，reload 读回', () async {
    const combo = ShortcutCombo(key: LogicalKeyboardKey.keyP, ctrl: true);
    final accepted = await ShortcutSettings.instance.setBinding(
      ShortcutScope.inApp,
      ShortcutCommand.togglePlayPause,
      combo,
    );

    expect(accepted, isTrue);
    expect(
      ShortcutSettings.instance.inAppBindings
          .comboFor(ShortcutCommand.togglePlayPause),
      combo,
    );
    expect(
      ShortcutSettings.instance.inAppBindings
          .isOverridden(ShortcutCommand.togglePlayPause),
      isTrue,
    );
    // 存储里是「覆盖表 JSON」，读回经同一解码路径仍得同一组合。
    expect(
      ShortcutBindings.decode(
        ShortcutScope.inApp,
        prefs.getString(kShortcutBindings.name),
      ).comboFor(ShortcutCommand.togglePlayPause),
      combo,
    );

    await ShortcutSettings.reload();
    expect(
      ShortcutSettings.instance.inAppBindings
          .comboFor(ShortcutCommand.togglePlayPause),
      combo,
    );
  });

  test('setBinding：全局缺修饰键 / 同组冲突 / 跨分组动作都拒绝且不写入', () async {
    final settings = ShortcutSettings.instance;

    // 全局必须带修饰键：纯 Space 拒绝。
    expect(
      await settings.setBinding(
        ShortcutScope.global,
        ShortcutCommand.togglePlayPause,
        const ShortcutCombo(key: LogicalKeyboardKey.space),
      ),
      isFalse,
    );
    // 同组冲突：Space 已是软件内「播放 / 暂停」的默认键。
    expect(
      await settings.setBinding(
        ShortcutScope.inApp,
        ShortcutCommand.volumeUp,
        const ShortcutCombo(key: LogicalKeyboardKey.space),
      ),
      isFalse,
    );
    // 动作不属于该分组（全局表没有快进）：拒绝。
    expect(
      await settings.setBinding(
        ShortcutScope.global,
        ShortcutCommand.seekForward,
        const ShortcutCombo(key: LogicalKeyboardKey.keyF, ctrl: true),
      ),
      isFalse,
    );

    // 全部拒绝：状态与存储都保持无覆盖。
    expect(settings.inAppBindings.encode(), '');
    expect(settings.globalBindings.encode(), '');
    expect(prefs.getString(kShortcutBindings.name), isNull);
    expect(prefs.getString(kGlobalShortcutBindings.name), isNull);
  });

  test('resetScope：清空覆盖、回默认并落盘空串', () async {
    final settings = ShortcutSettings.instance;
    await settings.setBinding(
      ShortcutScope.inApp,
      ShortcutCommand.togglePlayPause,
      const ShortcutCombo(key: LogicalKeyboardKey.keyP, ctrl: true),
    );
    await settings.setBinding(
      ShortcutScope.inApp,
      ShortcutCommand.toggleMute,
      const ShortcutCombo(key: LogicalKeyboardKey.keyJ),
    );
    expect(
      settings.inAppBindings.isOverridden(ShortcutCommand.toggleMute),
      isTrue,
    );

    await settings.resetScope(ShortcutScope.inApp);

    expect(settings.inAppBindings.encode(), '');
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );
    expect(prefs.getString(kShortcutBindings.name), '');

    // 重新载入仍是全默认。
    await ShortcutSettings.reload();
    expect(ShortcutSettings.instance.inAppBindings.encode(), '');
  });
}
