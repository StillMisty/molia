import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_module.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settings_test_support.dart';

Future<void> _waitForKey(
  ChannelSelection selection,
  String expected, {
  String reason = '',
}) async {
  for (var i = 0; i < 100 && selection.key != expected; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(selection.key, expected, reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('持久化用户选择，并在新实例中恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = testSettingsRegistry();
    final first = ChannelSelection(
      settings: settings,
      validKeys: () => const ['wy', 'kg'],
      defaultKey: () => 'wy',
    );
    addTearDown(first.dispose);

    first.select('kg');
    await _waitForKey(first, 'kg');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kDiscoverChannelKey.name), 'kg');

    final second = ChannelSelection(
      settings: settings,
      validKeys: () => const ['wy', 'kg'],
      defaultKey: () => 'wy',
    );
    addTearDown(second.dispose);
    await _waitForKey(second, 'kg', reason: '跨重启恢复渠道偏好');
  });

  test('在途恢复不能覆盖用户刚做出的选择', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = testSettingsRegistry();
    await settings.write(kDiscoverChannelKey, 'wy');

    final selection = ChannelSelection(
      settings: settings,
      validKeys: () => const ['wy', 'kg', 'tx'],
      defaultKey: () => 'wy',
    );
    addTearDown(selection.dispose);
    selection.select('kg');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(selection.key, 'kg', reason: '晚到的恢复不得覆盖用户选择');
  });

  test('在途跨设备 reload 不能覆盖用户刚做出的选择', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = testSettingsRegistry();
    await settings.write(kDiscoverChannelKey, 'wy');

    final selection = ChannelSelection(
      settings: settings,
      validKeys: () => const ['wy', 'kg', 'tx'],
      defaultKey: () => 'wy',
    );
    addTearDown(selection.dispose);
    await _waitForKey(selection, 'wy');
    // 与生产组合根一致：键声明 + 远端应用后的 reload 在同一个挂载点。
    settings.mount(
      SettingsModule(
        keys: [kDiscoverChannelKey],
        reload: selection.reloadFromPreferences,
      ),
    );

    await settings.applyRemote(kDiscoverChannelKey, 'kg');
    final pendingReload = settings.reloadApplied();
    selection.select('tx');
    await pendingReload;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(selection.key, 'tx', reason: '在途 reload 不覆盖刚做出的选择');
  });

  test('ensureValid：有效集合为空时不回退，失效后回退到第一个有效项', () async {
    var keys = <String>[];
    final selection = ChannelSelection(
      validKeys: () => keys,
      defaultKey: () => 'wy',
    );
    addTearDown(selection.dispose);

    selection.ensureValid();
    expect(selection.key, 'wy', reason: '音源未就绪 / 脚本激活中不能回退');

    keys = ['wy', 'kg'];
    selection.ensureValid();
    expect(selection.key, 'wy', reason: '当前 key 仍有效时不切换');

    keys = ['kg', 'tx'];
    await Future<void>.delayed(Duration.zero);
    expect(selection.key, 'wy', reason: '有效集合变化不会自动触发回退');

    selection.ensureValid();
    expect(selection.key, 'kg', reason: '触发后回退到第一个有效项');
  });

  test('显式 initialKey 优先于异步恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = testSettingsRegistry();
    await settings.write(kDiscoverChannelKey, 'kg');

    final selection = ChannelSelection(
      settings: settings,
      validKeys: () => const ['wy', 'kg'],
      defaultKey: () => 'kg',
      initialKey: 'wy',
    );
    addTearDown(selection.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(selection.key, 'wy');
  });

  test('无持久化值时默认 key 来自 defaultKey', () {
    var defaultCalls = 0;
    final selection = ChannelSelection(
      validKeys: () => const ['wy', 'kg'],
      defaultKey: () {
        defaultCalls++;
        return 'wy';
      },
    );
    addTearDown(selection.dispose);

    expect(selection.key, 'wy');
    expect(defaultCalls, 1);
  });

  test('dispose 后不接受在途异步恢复', () async {
    SharedPreferences.setMockInitialValues({kDiscoverChannelKey.name: 'kg'});
    final settings = testSettingsRegistry();
    final selection = ChannelSelection(
      settings: settings,
      validKeys: () => const ['wy', 'kg'],
      defaultKey: () => 'wy',
    );

    selection.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(selection.key, 'wy', reason: 'dispose 后的读盘结果必须丢弃');
  });
}
