import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/device_settings.dart';
import 'package:molia/data/settings/device_settings_keys.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/playback_feel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _boolKey = DeviceSettingKey<bool>('ds_test_bool', true);
const _intKey = DeviceSettingKey<int>('ds_test_int', 7);
const _decimalKey = DeviceSettingKey<double>('ds_test_decimal', 0.5);
const _textKey = DeviceSettingKey<String>('ds_test_text', 'fallback');
const _listKey = DeviceSettingKey<List<String>>('ds_test_list', <String>[]);
const _unsupportedNumKey = DeviceSettingKey<num>('ds_test_num', 0);

/// 设置模块接口契约：标量读写 / JSON 键 / 失败策略 / 模块级串行写 / 键表。
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

  test('标量写入后按原类型往返，remove 后读回默认值', () async {
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

    await settings.remove(_textKey);
    expect(prefs.containsKey(_textKey.name), isFalse);
    expect(await settings.read(_textKey), 'fallback');
  });

  test('不受支持的键类型读取直接失败，不回默认值', () async {
    final settings = DeviceSettings();

    await expectLater(
      settings.read(_unsupportedNumKey),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', _unsupportedNumKey.name)
            .having(
              (error) => error.message,
              'message',
              contains('DeviceSettingKey<num>'),
            ),
      ),
    );

    await expectLater(
      settings.read(DeviceSettingKey<DateTime>('ds_test_date', DateTime(2020))),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'ds_test_date')
            .having(
              (error) => error.message,
              'message',
              contains('DeviceSettingKey<DateTime>'),
            ),
      ),
    );
  });

  test('不受支持的键类型写入直接失败，不进写失败策略', () {
    final settings = DeviceSettings();

    expect(
      () => settings.write(_unsupportedNumKey, 1),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          _unsupportedNumKey.name,
        ),
      ),
    );
    expect(
      () => settings.write(
        DeviceSettingKey<DateTime>('ds_test_date', DateTime(2020)),
        DateTime(2021),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'ds_test_date',
        ),
      ),
    );
  });

  test('tryRead 区分缺键与读取失败', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    final missing = await settings.tryRead(_intKey);
    expect(missing.ok, isTrue, reason: '缺键不是失败：值取默认');
    expect(missing.value, 7);

    // 存储里的类型与键声明不符：getInt 会抛 TypeError，整组回退的调用方
    // 需要 ok=false 才能把同一键组的其它值一起回默认。
    await prefs.setString(_intKey.name, 'not-an-int');
    final mismatch = await settings.tryRead(_intKey);
    expect(mismatch.ok, isFalse);
    expect(mismatch.value, 7);
  });

  test('JSON 键自带字段形状：往返、缺键、损坏与非有限值都回 null', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    expect(await settings.readJson(kPlaybackFeelStateKey), isNull);
    await settings.writeJson(kPlaybackFeelStateKey, (
      fade: PlaybackFadePreset.ms300,
      smartShuffle: false,
    ));
    final feel = await settings.readJson(kPlaybackFeelStateKey);
    expect(feel?.fade, PlaybackFadePreset.ms300);
    expect(feel?.smartShuffle, isFalse);

    await settings.writeJson(kPlaybackVolumeStateKey, (
      volume: 0.35,
      muted: true,
    ));
    final volume = await settings.readJson(kPlaybackVolumeStateKey);
    expect(volume?.volume, closeTo(0.35, 1e-9));
    expect(volume?.muted, isTrue);

    await prefs.setString(kPlaybackFeelStateKey.name, '{broken');
    expect(await settings.readJson(kPlaybackFeelStateKey), isNull);

    await prefs.setString(
      kPlaybackFeelStateKey.name,
      '{"fadeMs":1e999,"smartShuffle":true}',
    );
    expect(
      await settings.readJson(kPlaybackFeelStateKey),
      isNull,
      reason: '非有限毫秒值不能走到 toInt()',
    );

    await prefs.setString(
      kPlaybackVolumeStateKey.name,
      '{"volume":1e999,"muted":true}',
    );
    expect(
      await settings.readJson(kPlaybackVolumeStateKey),
      isNull,
      reason: '非有限音量不能污染滑块',
    );
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

  test('不同 DeviceSettings 实例共用同一条写链', () async {
    final store = _RecordingStore();
    SharedPreferencesStorePlatform.instance = store;
    final prefs = await SharedPreferences.getInstance();
    final first = DeviceSettings(preferences: prefs);
    final second = DeviceSettings(preferences: prefs);

    // 迁移后的 store 各自构造自己的 DeviceSettings；串行必须跨实例成立。
    final writeA = first.write(_textKey, 'a');
    final writeB = second.write(_intKey, 3);
    await Future.wait([writeA, writeB]);

    expect(store.events, [
      'start:${_textKey.name}',
      'end:${_textKey.name}',
      'start:${_intKey.name}',
      'end:${_intKey.name}',
    ]);
  });

  test('写失败不抛出，内存值仍可读；后续写继续执行', () async {
    SharedPreferencesStorePlatform.instance = _FailingWriteStore();
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    await expectLater(settings.write(_textKey, 'session'), completes);
    await expectLater(
      settings.writeJson(kPlaybackVolumeStateKey, (volume: 0.5, muted: true)),
      completes,
    );

    // shared_preferences 先更新内存缓存再落盘，写失败不回滚本次会话值。
    expect(await settings.read(_textKey), 'session');
    expect((await settings.readJson(kPlaybackVolumeStateKey))?.volume, 0.5);
  });

  test('无法编码的 JSON 值不抛出', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = DeviceSettings(preferences: prefs);

    // NaN / Infinity 不能写进 JSON；失败策略是只记日志，不打断会话。
    await expectLater(
      settings.writeJson(kPlaybackVolumeStateKey, (
        volume: double.nan,
        muted: false,
      )),
      completes,
    );
  });

  test('存储打不开时读取回默认、写入不抛出', () async {
    final settings = DeviceSettings.withOpener(
      () async => throw StateError('prefs unavailable'),
    );

    expect(await settings.read(_intKey), 7);
    expect((await settings.tryRead(_intKey)).ok, isFalse);
    expect(await settings.readJson(kPlaybackFeelStateKey), isNull);
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

    expect(kPlaybackFeelStateKey.defaultValue.fade, PlaybackFadePreset.ms200);
    expect(kPlaybackFeelStateKey.defaultValue.smartShuffle, isTrue);
    expect(kPlaybackVolumeStateKey.defaultValue.volume, 1.0);
    expect(kPlaybackVolumeStateKey.defaultValue.muted, isFalse);
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
