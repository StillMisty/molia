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
    final result = await ShortcutSettings.instance.setBinding(
      ShortcutScope.inApp,
      ShortcutCommand.togglePlayPause,
      combo,
    );

    expect(result, isA<ShortcutBindingAccepted>());
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

  test('setBinding：缺修饰键 / 不支持键 / 同组冲突 / 跨分组动作都拒绝且不写入', () async {
    final settings = ShortcutSettings.instance;

    // 全局必须带修饰键：纯 Space 拒绝。
    expect(
      await settings.setBinding(
        ShortcutScope.global,
        ShortcutCommand.togglePlayPause,
        const ShortcutCombo(key: LogicalKeyboardKey.space),
      ),
      isA<ShortcutBindingRejected>().having(
        (result) => result.reason,
        'reason',
        ShortcutBindingRejection.missingModifier,
      ),
    );
    // 平台只收字母 / 数字 / F1–F12 / 空格：带修饰键的方向键也拒绝。
    expect(
      await settings.setBinding(
        ShortcutScope.global,
        ShortcutCommand.togglePlayPause,
        const ShortcutCombo(
          key: LogicalKeyboardKey.arrowLeft,
          ctrl: true,
          alt: true,
        ),
      ),
      isA<ShortcutBindingRejected>().having(
        (result) => result.reason,
        'reason',
        ShortcutBindingRejection.unsupportedKey,
      ),
    );
    // 同组冲突：Space 已是软件内「播放 / 暂停」的默认键。
    expect(
      await settings.setBinding(
        ShortcutScope.inApp,
        ShortcutCommand.volumeUp,
        const ShortcutCombo(key: LogicalKeyboardKey.space),
      ),
      isA<ShortcutBindingConflict>().having(
        (result) => result.other,
        'other',
        ShortcutCommand.togglePlayPause,
      ),
    );
    // 动作不属于该分组（全局表没有快进）：拒绝。
    expect(
      await settings.setBinding(
        ShortcutScope.global,
        ShortcutCommand.seekForward,
        const ShortcutCombo(key: LogicalKeyboardKey.keyF, ctrl: true),
      ),
      isA<ShortcutBindingRejected>().having(
        (result) => result.reason,
        'reason',
        ShortcutBindingRejection.unknownAction,
      ),
    );

    // 全部拒绝：状态与存储都保持无覆盖。
    expect(settings.inAppBindings.encode(), '');
    expect(settings.globalBindings.encode(), '');
    expect(prefs.getString(kShortcutBindings.name), isNull);
    expect(prefs.getString(kGlobalShortcutBindings.name), isNull);
  });

  test('setBinding：回默认目标被占时拒绝（不造重复绑定）', () async {
    final settings = ShortcutSettings.instance;
    // 先制造「互换后」的交叉状态：Space ⇄ ↑ 已对调。
    expect(
      await settings.swapBindings(
        ShortcutScope.inApp,
        ShortcutCommand.togglePlayPause,
        ShortcutCommand.volumeUp,
      ),
      isTrue,
    );

    // 任一侧回默认都会撞上另一侧：拒绝并指出占用者与目标组合。
    expect(
      await settings.setBinding(
        ShortcutScope.inApp,
        ShortcutCommand.togglePlayPause,
        null,
      ),
      isA<ShortcutBindingConflict>()
          .having((result) => result.other, 'other', ShortcutCommand.volumeUp)
          .having(
            (result) => result.target,
            'target',
            const ShortcutCombo(key: LogicalKeyboardKey.space),
          ),
    );
    expect(
      await settings.setBinding(
        ShortcutScope.inApp,
        ShortcutCommand.volumeUp,
        null,
      ),
      isA<ShortcutBindingConflict>()
          .having(
            (result) => result.other,
            'other',
            ShortcutCommand.togglePlayPause,
          )
          .having(
            (result) => result.target,
            'target',
            const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
          ),
    );

    // 两次拒绝都不写入：仍是交叉状态，组内无重复。
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.volumeUp),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );
    final combos = settings.inAppBindings.effective.values.toList();
    expect(combos.toSet().length, combos.length);
  });

  test('setBinding：回默认在默认组合空闲时清掉覆盖', () async {
    final settings = ShortcutSettings.instance;
    await settings.setBinding(
      ShortcutScope.inApp,
      ShortcutCommand.toggleMute,
      const ShortcutCombo(key: LogicalKeyboardKey.keyJ),
    );

    expect(
      await settings.setBinding(
        ShortcutScope.inApp,
        ShortcutCommand.toggleMute,
        null,
      ),
      isA<ShortcutBindingAccepted>(),
    );
    expect(
      settings.inAppBindings.isOverridden(ShortcutCommand.toggleMute),
      isFalse,
    );
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.toggleMute),
      const ShortcutCombo(key: LogicalKeyboardKey.keyM),
    );
  });

  test('swapBindings：互换生效组合、按默认归一化、一次落盘并可读回', () async {
    final settings = ShortcutSettings.instance;

    // 全默认下互换「播放 / 暂停」（Space）与「音量 +」（↑）。
    expect(
      await settings.swapBindings(
        ShortcutScope.inApp,
        ShortcutCommand.togglePlayPause,
        ShortcutCommand.volumeUp,
      ),
      isTrue,
    );
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.volumeUp),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );
    expect(
      settings.inAppBindings.isOverridden(ShortcutCommand.togglePlayPause),
      isTrue,
    );
    expect(
      settings.inAppBindings.isOverridden(ShortcutCommand.volumeUp),
      isTrue,
    );

    // 互换不破坏「同组无重复」：全部生效组合两两不同（conflictWith 的判定源）。
    final combos = settings.inAppBindings.effective.values.toList();
    expect(combos.toSet().length, combos.length);

    // 一次落盘：存储里两边都是覆盖，读回经同一解码路径仍得互换结果。
    final decoded = ShortcutBindings.decode(
      ShortcutScope.inApp,
      prefs.getString(kShortcutBindings.name),
    );
    expect(
      decoded.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );
    expect(
      decoded.comboFor(ShortcutCommand.volumeUp),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );

    await ShortcutSettings.reload();
    expect(
      ShortcutSettings.instance.inAppBindings
          .comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );

    // 再互换一次回到全默认：归一化把两边的覆盖都清掉。
    expect(
      await settings.swapBindings(
        ShortcutScope.inApp,
        ShortcutCommand.togglePlayPause,
        ShortcutCommand.volumeUp,
      ),
      isTrue,
    );
    expect(settings.inAppBindings.encode(), '');
    expect(prefs.getString(kShortcutBindings.name), '');
  });

  test('swapBindings：拿到对方默认值的一侧清掉覆盖', () async {
    final settings = ShortcutSettings.instance;
    // 先把「播放 / 暂停」改到 Ctrl+P，Space 空出；再把「音量 +」改到 Space。
    await settings.setBinding(
      ShortcutScope.inApp,
      ShortcutCommand.togglePlayPause,
      const ShortcutCombo(key: LogicalKeyboardKey.keyP, ctrl: true),
    );
    await settings.setBinding(
      ShortcutScope.inApp,
      ShortcutCommand.volumeUp,
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );

    expect(
      await settings.swapBindings(
        ShortcutScope.inApp,
        ShortcutCommand.togglePlayPause,
        ShortcutCommand.volumeUp,
      ),
      isTrue,
    );
    // 「播放 / 暂停」拿回 Space（= 自身默认）→ 清覆盖；「音量 +」拿到 Ctrl+P。
    expect(
      settings.inAppBindings.isOverridden(ShortcutCommand.togglePlayPause),
      isFalse,
    );
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );
    expect(
      settings.inAppBindings.isOverridden(ShortcutCommand.volumeUp),
      isTrue,
    );
    expect(
      settings.inAppBindings.comboFor(ShortcutCommand.volumeUp),
      const ShortcutCombo(key: LogicalKeyboardKey.keyP, ctrl: true),
    );
    // 存储里只剩「音量 +」一条覆盖。
    final raw = prefs.getString(kShortcutBindings.name);
    expect(raw, contains('volumeUp'));
    expect(raw, isNot(contains('togglePlayPause')));
  });

  test('swapBindings：全局分组同语义，互换后仍全部可注册', () async {
    final settings = ShortcutSettings.instance;
    expect(
      await settings.swapBindings(
        ShortcutScope.global,
        ShortcutCommand.togglePlayPause,
        ShortcutCommand.nextTrack,
      ),
      isTrue,
    );
    expect(
      settings.globalBindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(
        key: LogicalKeyboardKey.keyN,
        ctrl: true,
        alt: true,
      ),
    );
    expect(
      settings.globalBindings.comboFor(ShortcutCommand.nextTrack),
      const ShortcutCombo(
        key: LogicalKeyboardKey.space,
        ctrl: true,
        alt: true,
      ),
    );
    for (final combo in settings.globalBindings.effective.values) {
      expect(
        ShortcutSettings.isComboSupported(ShortcutScope.global, combo),
        isTrue,
      );
    }
  });

  test('swapBindings：自身 / 跨分组动作拒绝且不写入', () async {
    final settings = ShortcutSettings.instance;

    expect(
      await settings.swapBindings(
        ShortcutScope.inApp,
        ShortcutCommand.togglePlayPause,
        ShortcutCommand.togglePlayPause,
      ),
      isFalse,
    );
    // 全局默认表没有快进：无论出现在哪一侧都拒绝。
    expect(
      await settings.swapBindings(
        ShortcutScope.global,
        ShortcutCommand.seekForward,
        ShortcutCommand.togglePlayPause,
      ),
      isFalse,
    );
    expect(
      await settings.swapBindings(
        ShortcutScope.global,
        ShortcutCommand.togglePlayPause,
        ShortcutCommand.seekForward,
      ),
      isFalse,
    );

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
