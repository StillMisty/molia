/// SettingsRegistry.scope：模块按键视图的契约。
///
/// 覆盖：作用域内读写 / 重载绑定、作用域外拒绝（debug 断言）、默认值来自键、
/// 作用域隔离与「不是第二份存储」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('作用域内：读写 / 删除 / reload 都落到同一份注册表', () async {
    final registry = testSettingsRegistry();
    final scope = registry.scope([kThemeMode, kSeedColor]);

    // 缺键回退键默认值，且不写回 prefs。
    expect(await scope.read(kThemeMode), kThemeMode.defaultValue);
    expect(await scope.read(kSeedColor), kSeedColor.defaultValue);

    await scope.write(kThemeMode, 'dark');
    expect(await registry.read(kThemeMode), 'dark');

    // 另一个作用域（同一注册表）看到相同的底层值。
    final reader = registry.scope([kThemeMode]);
    expect(await reader.read(kThemeMode), 'dark');

    var reloads = 0;
    scope.bindReload(kThemeMode, () async => reloads++);
    await registry.reloadKeys([kThemeMode.name]);
    expect(reloads, 1);

    await scope.clear(kThemeMode);
    expect(await registry.read(kThemeMode), kThemeMode.defaultValue);
  });

  test('作用域外：读 / 写 / 删除 / 绑重载一律拒绝', () async {
    final registry = testSettingsRegistry();
    final scope = registry.scope([kThemeMode]);

    Matcher rejected() => throwsA(
          anyOf(isA<AssertionError>(), isA<StateError>()),
        );

    expect(() => scope.read(kPureBlackEnabled), rejected());
    expect(() => scope.write(kPureBlackEnabled, true), rejected());
    expect(() => scope.clear(kPureBlackEnabled), rejected());
    expect(() => scope.bindReload(kPureBlackEnabled, () async {}), rejected());

    // 越界调用没有产生任何写入 / 钩子。
    expect(await registry.read(kPureBlackEnabled), isFalse);
    var reloads = 0;
    scope.bindReload(kThemeMode, () async => reloads++);
    registry.bindReload(kPureBlackEnabled, () async => reloads++);
    await registry.reloadKeys([kPureBlackEnabled.name]);
    expect(reloads, 1, reason: '越界 bindReload 被拒后只剩注册表自己的钩子');
  });

  test('作用域只暴露声明的键', () {
    final registry = testSettingsRegistry();
    final scope = registry.scope([kThemeMode, kShellNavHidden]);

    expect(scope.keys.map((key) => key.name), [
      kThemeMode.name,
      kShellNavHidden.name,
    ]);
  });

  test('作用域可收窄已登记快捷键组；读写在注册表上照旧', () async {
    final registry = testSettingsRegistry();
    // 快捷键四键已登记为「跟人走」；作用域只决定本模块能碰哪些键，
    // 不改变读写落在同一份注册表 / 同一份存储上。
    final scope = registry.scope([
      kShortcutsEnabled,
      kGlobalShortcutsEnabled,
      kShortcutBindings,
      kGlobalShortcutBindings,
    ]);

    expect(await scope.read(kShortcutsEnabled), kShortcutsEnabled.defaultValue);
    await scope.write(kShortcutsEnabled, false);
    expect(await registry.read(kShortcutsEnabled), isFalse);
  });

  test('作用域写入同样触发注册表的本地写入钩子（同步标记不丢）', () async {
    final registry = testSettingsRegistry();
    final written = <String>[];
    registry.onWrite = (key) => written.add(key.name);
    final scope = registry.scope([kSeedColor]);

    await scope.write(kSeedColor, 0xFF112233);
    await scope.clear(kSeedColor);

    expect(written, [kSeedColor.name, kSeedColor.name]);
  });
}
