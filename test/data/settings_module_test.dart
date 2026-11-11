import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_module.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/settings_test_support.dart';

/// 设置模块挂载契约：作用域收窄、远端应用后的重载、漏绑 reload 的构造期
/// 失败。行为与 `SettingsRegistry` 的后置绑定一致，但声明与重载不再分家。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('mount：整批远端应用后同一模块只重载一次，scope 读到新值', () async {
    final registry = testSettingsRegistry(
      keys: const [kThemeMode, kColorBase, kSeedColor],
    );
    var reloads = 0;
    final scope = registry.mount(
      SettingsModule(
        keys: const [kThemeMode, kColorBase],
        reload: () async => reloads++,
      ),
    );

    await registry.applyRemote(kThemeMode, 'dark');
    await registry.applyRemote(kColorBase, 'custom');
    expect(reloads, 0, reason: 'applyRemote 只登记，批量应用完才统一重载');

    await registry.reloadApplied();
    expect(reloads, 1, reason: '同一钩子绑多个键只执行一次');
    expect(await scope.read(kThemeMode), 'dark');
    expect(await scope.read(kColorBase), 'custom');

    await registry.reloadApplied();
    expect(reloads, 1, reason: '没有新的远端应用时重载是空操作');
  });

  test('scope 之外的键不可读写', () async {
    final registry = testSettingsRegistry(keys: const [kThemeMode, kSeedColor]);
    final scope = registry.mount(
      SettingsModule(keys: const [kThemeMode], reload: () async {}),
    );

    expect(
      () => scope.read(kSeedColor),
      throwsA(anyOf(isA<AssertionError>(), isA<StateError>())),
    );
    expect(
      () => scope.write(kSeedColor, 0xFF000000),
      throwsA(anyOf(isA<AssertionError>(), isA<StateError>())),
    );
    expect(scope.keys, [kThemeMode]);
  });

  test('分组重载：各组只响应对应键，互不串台', () async {
    final registry = testSettingsRegistry(
      keys: const [kAiDjPreferences, kAiDjFeedbackMemory, kAiDjEnabled],
    );
    var preferenceReloads = 0;
    var accessReloads = 0;
    registry.mount(
      SettingsModule.withReloads(
        keys: const [kAiDjPreferences, kAiDjFeedbackMemory, kAiDjEnabled],
        reloads: [
          (
            keys: const [kAiDjPreferences, kAiDjFeedbackMemory],
            reload: () async => preferenceReloads++,
          ),
          (keys: const [kAiDjEnabled], reload: () async => accessReloads++),
        ],
      ),
    );

    await registry.applyRemote(kAiDjEnabled, true);
    await registry.reloadApplied();
    expect(accessReloads, 1);
    expect(preferenceReloads, 0);

    await registry.applyRemote(kAiDjFeedbackMemory, '{}');
    await registry.applyRemote(kAiDjPreferences, '{}');
    await registry.reloadApplied();
    expect(accessReloads, 1);
    expect(preferenceReloads, 1);
  });

  test('声明了键却没有 reload：模块构造即失败', () {
    expect(
      () => SettingsModule.withReloads(
        keys: const [kThemeMode, kColorBase],
        reloads: [
          (keys: const [kThemeMode], reload: () async {}),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('reload 键必须落在模块作用域内', () {
    expect(
      () => SettingsModule.withReloads(
        keys: const [kThemeMode],
        reloads: [
          (keys: const [kThemeMode, kColorBase], reload: () async {}),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('mount 拒绝未登记进注册表的键', () {
    final registry = testSettingsRegistry(keys: const [kThemeMode]);
    expect(
      () => registry.mount(
        SettingsModule(keys: const [kColorBase], reload: () async {}),
      ),
      throwsArgumentError,
    );
  });

  test('同一个键不能被两个模块重复挂载；不同键正常', () {
    final registry = testSettingsRegistry(keys: const [kThemeMode, kColorBase]);
    final first = registry.mount(
      SettingsModule(keys: const [kThemeMode], reload: () async {}),
    );

    expect(
      () => registry.mount(
        SettingsModule(keys: const [kThemeMode], reload: () async {}),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('设置键已被其它模块挂载'),
        ),
      ),
    );
    // 只读视图不参与挂载校验：同一个键仍可用于 scope（测试 / 边缘装配）。
    expect(registry.scope(const [kThemeMode]).keys, first.keys);

    final second = registry.mount(
      SettingsModule(keys: const [kColorBase], reload: () async {}),
    );
    expect(second.keys, [kColorBase]);
  });
}
