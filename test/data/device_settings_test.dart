import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/device_settings.dart';
import 'package:molia/data/settings/device_settings_keys.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _boolKey = DeviceSettingKey<bool>(
  'ds_test_bool',
  true,
  kind: DeviceSettingKind.boolean,
);
const _intKey = DeviceSettingKey<int>(
  'ds_test_int',
  7,
  kind: DeviceSettingKind.integer,
);
const _decimalKey = DeviceSettingKey<double>(
  'ds_test_decimal',
  0.5,
  kind: DeviceSettingKind.decimal,
);
const _textKey = DeviceSettingKey<String>(
  'ds_test_text',
  'fallback',
  kind: DeviceSettingKind.text,
);
const _listKey = DeviceSettingKey<List<String>>(
  'ds_test_list',
  <String>[],
  kind: DeviceSettingKind.stringList,
);
const _jsonKey = DeviceSettingKey<String>(
  'ds_test_json',
  '',
  kind: DeviceSettingKind.text,
);

/// 设置模块接口契约：标量读写 / JSON 往返 / 失败策略 / 串行写 / 键表。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('缺键时每种标量都回退键默认值', () async {
    final settings = DeviceSettings();

    expect(await settings.read(_boolKey), isTrue);
    expect(await settings.read(_intKey), 7);
    expect(await settings.read(_decimalKey), 0.5);
    expect(await settings.read(_textKey), 'fallback');
    expect(await settings.read(_listKey), isEmpty);
  });

  test('标量写入后按原类型往返，键名不变', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    await settings.write(_boolKey, false);
    await settings.write(_intKey, 42);
    await settings.write(_decimalKey, 0.35);
    await settings.write(_textKey, 'kept');
    await settings.write(_listKey, ['a', 'b']);

    expect(await settings.read(_boolKey), isFalse);
    expect(await settings.read(_intKey), 42);
    expect(await settings.read(_decimalKey), closeTo(0.35, 1e-9));
    expect(await settings.read(_textKey), 'kept');
    expect(await settings.read(_listKey), ['a', 'b']);
    expect(
      prefs.getKeys(),
      containsAll(<String>[
        _boolKey.name,
        _intKey.name,
        _decimalKey.name,
        _textKey.name,
        _listKey.name,
      ]),
    );
  });

  test('remove 后读回默认值', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    await settings.write(_textKey, 'temporary');
    await settings.remove(_textKey);

    expect(prefs.containsKey(_textKey.name), isFalse);
    expect(await settings.read(_textKey), 'fallback');
  });

  test('JSON 往返；缺键 / 损坏 / 非对象都回 null', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    expect(await settings.readJson(_jsonKey), isNull);

    await settings.writeJson(_jsonKey, {'fadeMs': 300, 'smartShuffle': false});
    expect(await settings.readJson(_jsonKey), {
      'fadeMs': 300,
      'smartShuffle': false,
    });
    expect(jsonDecode(prefs.getString(_jsonKey.name)!), {
      'fadeMs': 300,
      'smartShuffle': false,
    });

    await prefs.setString(_jsonKey.name, '{broken');
    expect(await settings.readJson(_jsonKey), isNull, reason: '损坏 JSON 回默认');

    await prefs.setString(_jsonKey.name, '[1, 2]');
    expect(await settings.readJson(_jsonKey), isNull, reason: '非对象回默认');
  });

  test('写动作串行：前一次落盘完才开始下一次', () async {
    final store = _RecordingStore();
    SharedPreferencesStorePlatform.instance = store;
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    // 不 await：两次写必须排进同一条链，而不是同时打到存储。
    final first = settings.write(_textKey, 'one');
    final second = settings.write(_intKey, 2);
    await Future.wait([first, second]);

    expect(store.events, [
      'start:${_textKey.name}',
      'end:${_textKey.name}',
      'start:${_intKey.name}',
      'end:${_intKey.name}',
    ]);
    expect(await settings.read(_textKey), 'one');
    expect(await settings.read(_intKey), 2);
  });

  test('写失败不抛出，内存值仍可读；后续写继续执行', () async {
    SharedPreferencesStorePlatform.instance = _FailingWriteStore();
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    await expectLater(settings.write(_textKey, 'session'), completes);
    await expectLater(settings.writeJson(_jsonKey, {'a': 1}), completes);

    // shared_preferences 先更新内存缓存再落盘，写失败不回滚本次会话值。
    expect(await settings.read(_textKey), 'session');
    expect(await settings.readJson(_jsonKey), {'a': 1});
  });

  test('存储打不开时读取回默认、写入不抛出', () async {
    final settings = DeviceSettings.withOpener(
      () async => throw StateError('prefs unavailable'),
    );

    expect(await settings.read(_intKey), 7);
    expect(await settings.readJson(_jsonKey), isNull);
    await expectLater(settings.write(_textKey, 'value'), completes);
    await expectLater(settings.remove(_textKey), completes);
  });

  test('迁移键表：名字逐字保持、唯一且不登记进同步表', () {
    expect(kDeviceSettingsKeys.map((key) => key.name), [
      'playback_feel_state_v1',
      'playback_volume_state_v1',
      'playback_volume',
      'playback_muted',
      'onboarding_completed_v1',
    ]);
    final names = kDeviceSettingsKeys.map((key) => key.name).toSet();
    expect(names.length, kDeviceSettingsKeys.length, reason: '键名必须唯一');

    final registered = kAllSettingsKeys.map((key) => key.name).toSet();
    expect(names.intersection(registered), isEmpty, reason: '设备本地键不能进入同步 / 备份');

    for (final key in kDeviceSettingsKeys) {
      final matchesKind = switch (key.kind) {
        DeviceSettingKind.boolean => key.defaultValue is bool,
        DeviceSettingKind.integer => key.defaultValue is int,
        DeviceSettingKind.decimal => key.defaultValue is double,
        DeviceSettingKind.text => key.defaultValue is String,
        DeviceSettingKind.stringList => key.defaultValue is List<String>,
      };
      expect(matchesKind, isTrue, reason: '${key.name} 的默认值类型与 kind 不符');
    }
  });
}

/// 记录 setValue 先后；带一点延迟让「并发写」若存在就会交错。
class _RecordingStore extends InMemorySharedPreferencesStore {
  _RecordingStore() : super.empty();

  final List<String> events = [];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final name = key.replaceFirst('flutter.', '');
    events.add('start:$name');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final result = await super.setValue(valueType, key, value);
    events.add('end:$name');
    return result;
  }
}

/// 所有写入都失败，模拟磁盘不可用 / 平台异常。
class _FailingWriteStore extends InMemorySharedPreferencesStore {
  _FailingWriteStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    throw StateError('disk unavailable');
  }
}
