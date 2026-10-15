import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/sources/source_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settings_test_support.dart';

/// 渠道偏好模块（SourcePreferences）契约：读写 / 顺序 / 停用 / 重置 /
/// 写失败吞错，以及 SourceManager 的同名委托与通知转发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  SourcePreferences module({SettingsRegistry? settings}) {
    final preferences = SourcePreferences(settings ?? testSettingsRegistry());
    addTearDown(preferences.dispose);
    return preferences;
  }

  test('load：读取持久化的音质 / 顺序 / 停用', () async {
    SharedPreferences.setMockInitialValues({
      kLxDefaultQuality.name: 'flac',
      kLxSourceOrder.name: ['wy', 'kw'],
      kLxChannelDisabled.name: ['mg'],
    });
    final preferences = module();
    var notifications = 0;
    preferences.addListener(() => notifications++);

    await preferences.load();
    expect(preferences.preferredQuality, 'flac');
    expect(preferences.sourceOrder, ['wy', 'kw']);
    expect(preferences.disabledChannels, {'mg'});
    expect(notifications, 0, reason: '启动加载不通知（刷新时机由调用方决定）');
  });

  test('load：非法音质回默认；重读是合并式（不抹掉已有值，重置只在 reload）', () async {
    SharedPreferences.setMockInitialValues({
      kLxDefaultQuality.name: '999k',
      kLxSourceOrder.name: <String>[],
      kLxChannelDisabled.name: <String>[],
    });
    final preferences = module();
    await preferences.load();
    expect(preferences.preferredQuality, '320k', reason: '非法音质不进入内存');
    expect(preferences.sourceOrder, isEmpty);
    expect(preferences.disabledChannels, isEmpty);

    await preferences.setPreferredQuality('flac');
    await preferences.setSourceOrder(['wy']);
    await preferences.setChannelEnabled('mg', false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kLxDefaultQuality.name);
    await prefs.remove(kLxSourceOrder.name);
    await prefs.remove(kLxChannelDisabled.name);
    await preferences.load();
    expect(preferences.preferredQuality, '320k',
        reason: '音质键缺失回落到键默认值（合法值，与迁移前一致）');
    expect(preferences.sourceOrder, ['wy'], reason: '空顺序表按「保留已有」处理');
    expect(preferences.disabledChannels, {'mg'}, reason: '空停用表按「保留已有」处理');
  });

  test('setPreferredQuality：合法值生效并持久化；非法值忽略且不通知', () async {
    final preferences = module();
    var notifications = 0;
    preferences.addListener(() => notifications++);

    await preferences.setPreferredQuality('flac');
    expect(preferences.preferredQuality, 'flac');
    expect(notifications, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kLxDefaultQuality.name), 'flac');

    await preferences.setPreferredQuality('999k');
    expect(preferences.preferredQuality, 'flac');
    expect(notifications, 1);
  });

  test('setSourceOrder：去重 + 忽略空串并持久化；顺序相同不重复通知', () async {
    final preferences = module();
    var notifications = 0;
    preferences.addListener(() => notifications++);

    await preferences.setSourceOrder(['tx', 'kw', 'tx', '']);
    expect(preferences.sourceOrder, ['tx', 'kw']);
    expect(notifications, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(kLxSourceOrder.name), ['tx', 'kw']);

    await preferences.setSourceOrder(['tx', 'kw']);
    expect(notifications, 1, reason: '未变化不通知');
  });

  test('setChannelEnabled：停用 / 启用往返并持久化；无变化 / 空 key 不通知', () async {
    final preferences = module();
    var notifications = 0;
    preferences.addListener(() => notifications++);

    await preferences.setChannelEnabled('mg', false);
    expect(preferences.disabledChannels, {'mg'});
    expect(notifications, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(kLxChannelDisabled.name), ['mg']);

    await preferences.setChannelEnabled('mg', false);
    expect(notifications, 1, reason: '重复停用不通知');

    await preferences.setChannelEnabled('', false);
    expect(notifications, 1, reason: '空 key 直接忽略');

    await preferences.setChannelEnabled('mg', true);
    expect(preferences.disabledChannels, isEmpty);
    expect(notifications, 2);
    expect(prefs.getStringList(kLxChannelDisabled.name), isEmpty);
  });

  test('resetChannelOrder：清空并删除持久化键；本就为空不通知', () async {
    final preferences = module();
    var notifications = 0;
    preferences.addListener(() => notifications++);

    await preferences.resetChannelOrder();
    expect(notifications, 0, reason: '空顺序表无需重置');

    await preferences.setSourceOrder(['wy']);
    await preferences.resetChannelOrder();
    expect(preferences.sourceOrder, isEmpty);
    expect(notifications, 2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(kLxSourceOrder.name), isNull);
  });

  test('reload：先重置再加载体（远端「清空」也生效），结束通知一次', () async {
    SharedPreferences.setMockInitialValues({
      kLxDefaultQuality.name: 'flac',
      kLxSourceOrder.name: ['wy'],
      kLxChannelDisabled.name: ['mg'],
    });
    final preferences = module();
    await preferences.load();

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    var notifications = 0;
    preferences.addListener(() => notifications++);

    await preferences.reload();
    expect(preferences.preferredQuality, '320k');
    expect(preferences.sourceOrder, isEmpty);
    expect(preferences.disabledChannels, isEmpty);
    expect(notifications, 1);
  });

  test('远端设置应用后的定向重载：三个键共用同一重载钩子', () async {
    final registry = testSettingsRegistry();
    final preferences = module(settings: registry);
    await preferences.load();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLxDefaultQuality.name, '128k');
    await prefs.setStringList(kLxSourceOrder.name, ['kw', 'tx']);
    await prefs.setStringList(kLxChannelDisabled.name, ['mg']);

    await registry.reloadKeys([
      kLxDefaultQuality.name,
      kLxSourceOrder.name,
      kLxChannelDisabled.name,
    ]);
    expect(preferences.preferredQuality, '128k');
    expect(preferences.sourceOrder, ['kw', 'tx']);
    expect(preferences.disabledChannels, {'mg'});
  });

  test('getter 返回不可变视图：外部改动抛错', () async {
    final preferences = module();
    await preferences.setSourceOrder(['wy']);
    await preferences.setChannelEnabled('mg', false);

    expect(() => preferences.sourceOrder.add('tx'), throwsUnsupportedError);
    expect(
        () => preferences.disabledChannels.add('tx'), throwsUnsupportedError);
  });

  test('写失败吞错：内存状态生效、不打断交互', () async {
    final preferences = module(settings: _ThrowingSettingsRegistry());
    var notifications = 0;
    preferences.addListener(() => notifications++);

    await preferences.setPreferredQuality('flac');
    expect(preferences.preferredQuality, 'flac');
    expect(notifications, 1);

    await preferences.setSourceOrder(['wy']);
    expect(preferences.sourceOrder, ['wy']);

    await preferences.setChannelEnabled('mg', false);
    expect(preferences.disabledChannels, {'mg'});

    await preferences.resetChannelOrder();
    expect(preferences.sourceOrder, isEmpty);
    expect(notifications, 4);
  });

  test('SourceManager 委托：同名 API 直达偏好模块并转发通知', () async {
    final manager = SourceManager();
    addTearDown(manager.dispose);
    var notifications = 0;
    manager.addListener(() => notifications++);

    await manager.setPreferredQuality('flac');
    expect(manager.preferredQuality, 'flac');
    expect(notifications, 1);

    await manager.setChannelEnabled('mg', false);
    expect(manager.disabledChannels, {'mg'});
    expect(notifications, 2);

    await manager.setSourceOrder(['wy', 'kw']);
    expect(manager.sourceOrder, ['wy', 'kw']);
    expect(notifications, 3);

    await manager.resetChannelOrder();
    expect(manager.sourceOrder, isEmpty);
    expect(notifications, 4);

    await manager.setPreferredQuality('999k');
    expect(manager.preferredQuality, 'flac');
    expect(notifications, 4, reason: '非法音质与迁移前一致不通知');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kLxDefaultQuality.name), 'flac');
    expect(prefs.getStringList(kLxSourceOrder.name), isNull);
  });
}

/// 写 / 清空必失败的注册表：模拟平台存储不可用。
class _ThrowingSettingsRegistry extends SettingsRegistry {
  _ThrowingSettingsRegistry() : super(keys: kAllSettingsKeys);

  @override
  Future<void> write<T extends Object?>(SettingsKey<T> key, T value) async =>
      throw StateError('write failed: ${key.name}');

  @override
  Future<void> clear(SettingsKey<Object?> key) async =>
      throw StateError('clear failed: ${key.name}');
}
