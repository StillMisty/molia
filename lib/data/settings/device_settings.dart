/// 设备本地设置存储：所有不跟人走的键共用一套键表、JSON 编解码、
/// 按偏好文件串行写与失败策略。
///
/// **边界**：登记键（`settings_keys.dart`）按「换设备后是否期望看到同一份」
/// 收集并参与同步；本模块只服务显式留在设备本地的状态（音量、播放手感、
/// 首次引导标记…）。它不登记进 `SettingsRegistry`，也不同步 / 备份。
///
/// 当前不变式：
/// - 键名 / 默认值 / 类型（标量）或字段形状（JSON）只在键表声明一次；
/// - 写动作跨实例串行（同一 `SharedPreferences` 实例共用一条链），不会有两个
///   `set*` 交叉重写整个偏好文件；
/// - 读失败回键默认并记日志；写失败只记日志，不向调用方抛错。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// 设备本地设置条目的公共身份：键名（键表与键名扫描测试用）。
abstract interface class DeviceSettingEntry {
  /// 持久化键名。
  String get name;
}

/// 一个设备本地标量键：名字、缺键默认值、值的静态类型。
///
/// 值类型由泛型 [T] 唯一决定（`bool` / `int` / `double` / `String` /
/// `List<String>`），没有额外的 kind 字段：声明与读写不会出现「键说是
/// double、实际按 String 读」的静默错配。
class DeviceSettingKey<T extends Object> implements DeviceSettingEntry {
  const DeviceSettingKey(this.name, this.defaultValue);

  @override
  final String name;

  /// 缺键 / 读取失败时的回退值。
  final T defaultValue;

  @override
  String toString() => 'DeviceSettingKey($name)';
}

/// 一个 JSON 对象键：键名、缺键默认值，以及该键自己的编解码。
///
/// 多个标量合并进同一个键时，字段形状由键表定义一次，store 不再各自解析
/// `Map<String, dynamic>`。解码返回 `null` 表示字段缺失 / 类型不符 /
/// 非有限数值；读取入口按「缺键」处理，调用方可据此走旧版兜底。
class DeviceJsonSettingKey<T extends Object> implements DeviceSettingEntry {
  const DeviceJsonSettingKey(
    this.name,
    this.defaultValue, {
    required this.decode,
    required this.encode,
  });

  @override
  final String name;

  /// 缺键 / JSON 损坏时的回退值。
  final T defaultValue;

  /// 把已解析的 JSON 对象还原为值；字段损坏返回 `null`。
  final T? Function(Map<String, dynamic> json) decode;

  /// 把值编码为 JSON 对象。
  final Map<String, Object?> Function(T value) encode;

  @override
  String toString() => 'DeviceJsonSettingKey($name)';
}

/// 设备本地设置的唯一读写入口。
///
/// 生产路径懒取 `SharedPreferences.getInstance()`（它自身已缓存实例）；测试
/// 可直接注入 prefs 实例，或用 `SharedPreferences.setMockInitialValues` 换掉
/// 存储后再构造。
///
/// **失败策略（唯一一份）**：
/// - 读：存储不可用 / 值类型不符 → 键默认值，并记一条日志；
/// - 写：不向调用方抛错（只记日志），本次会话的内存值由调用方保留。
///
/// 本类不缓存打开结果：注入的实例直接使用；未注入时每次都向
/// `SharedPreferences.getInstance()` 取（缓存由它自己负责），这样测试在
/// 构造后替换 mock 存储不会被旧实例挡住。
///
/// 写动作按偏好文件（`SharedPreferences` 实例）共享一条链：迁移后的 store
/// 各自构造 `DeviceSettings`，每个实例一条链仍会让不同 store 的写交叉重写
/// 同一个偏好文件。按实例分链而不是全局单链，还能让测试替换 mock 存储后
/// 不被上一实例里未完成的写拖住。
class DeviceSettings {
  /// 生产 / 测试共用构造：`preferences` 为空时走 SharedPreferences 单例。
  DeviceSettings({this._preferences}) : _open = SharedPreferences.getInstance;

  /// 测试注入打开失败 / 延迟的存储；生产不要使用。
  @visibleForTesting
  DeviceSettings.withOpener(Future<SharedPreferences> Function() opener)
    : _preferences = null,
      _open = opener;

  final SharedPreferences? _preferences;
  final Future<SharedPreferences> Function() _open;

  /// 每个偏好文件实例一条串行写链：上一个动作结束后才启动下一个。
  static final Expando<Future<void>> _writeChains = Expando(
    'device-settings-writes',
  );

  Future<SharedPreferences> _openPreferences() {
    final injected = _preferences;
    return injected == null ? _open() : Future.value(injected);
  }

  /// 值的存储类型由泛型唯一决定。
  static _ValueKind _kindOf<T extends Object>(DeviceSettingKey<T> key) {
    if (key is DeviceSettingKey<bool>) return _ValueKind.boolean;
    if (key is DeviceSettingKey<int>) return _ValueKind.integer;
    if (key is DeviceSettingKey<double>) return _ValueKind.decimal;
    if (key is DeviceSettingKey<List<String>>) return _ValueKind.stringList;
    return _ValueKind.text;
  }

  /// 读取标量；缺键 / 读取失败回退 [DeviceSettingKey.defaultValue]。
  Future<T> read<T extends Object>(DeviceSettingKey<T> key) async =>
      (await tryRead(key)).value;

  /// 读取标量并保留失败状态。
  ///
  /// `ok == false` 表示打开存储或读取抛错（含存储里的值类型不符）；
  /// `ok == true` 且值为默认值只表示缺键。需要「整组回退」的调用方
  /// （如旧版音量两键）据此决定是否把整组值一起回默认。
  Future<({bool ok, T value})> tryRead<T extends Object>(
    DeviceSettingKey<T> key,
  ) async {
    try {
      final prefs = await _openPreferences();
      final stored = switch (_kindOf(key)) {
        _ValueKind.boolean => prefs.getBool(key.name),
        _ValueKind.integer => prefs.getInt(key.name),
        _ValueKind.decimal => prefs.getDouble(key.name),
        _ValueKind.text => prefs.getString(key.name),
        _ValueKind.stringList => prefs.getStringList(key.name),
      };
      if (stored == null) return (ok: true, value: key.defaultValue);
      if (stored is T) return (ok: true, value: stored);
      // 存储里的类型与键声明不一致（手工改偏好 / 旧版本残留）。
      _log('读取 ${key.name} 的类型是 ${stored.runtimeType}，回退默认值');
      return (ok: false, value: key.defaultValue);
    } catch (error) {
      _log('读取 ${key.name} 失败，回退默认值：$error');
      return (ok: false, value: key.defaultValue);
    }
  }

  /// 写入标量；失败只记日志，不向调用方抛错。
  Future<void> write<T extends Object>(DeviceSettingKey<T> key, T value) =>
      _enqueueWrite(key.name, (prefs) async {
        switch (_kindOf(key)) {
          case _ValueKind.boolean:
            await prefs.setBool(key.name, value as bool);
          case _ValueKind.integer:
            await prefs.setInt(key.name, value as int);
          case _ValueKind.decimal:
            await prefs.setDouble(key.name, value as double);
          case _ValueKind.text:
            await prefs.setString(key.name, value as String);
          case _ValueKind.stringList:
            await prefs.setStringList(key.name, (value as List).cast<String>());
        }
      });

  /// 删除键（读回默认值）；失败只记日志。
  ///
  /// 读写接口成对保留：调用方需要显式清掉设备本地事实时走这里，而不是
  /// 自己持有 prefs 直连删除。当前生产路径没有调用，接口由模块测试覆盖。
  Future<void> remove(DeviceSettingEntry key) =>
      _enqueueWrite(key.name, (prefs) async {
        await prefs.remove(key.name);
      });

  /// 读取 JSON 键；缺键、非对象、字段损坏都回 `null`。
  ///
  /// 字段形状由 [DeviceJsonSettingKey.decode] 定义；返回 `null` 而不是默认
  /// 值，让需要旧版兜底的调用方（如音量两键）能区分「没有新键」与「新键
  /// 有效」。
  Future<T?> readJson<T extends Object>(DeviceJsonSettingKey<T> key) async {
    try {
      final prefs = await _openPreferences();
      final raw = prefs.getString(key.name);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        _log('读取 ${key.name} 不是 JSON 对象，回退默认值');
        return null;
      }
      final value = key.decode(decoded);
      if (value == null) {
        _log('读取 ${key.name} 的字段损坏，回退默认值');
        return null;
      }
      return value;
    } catch (error) {
      _log('读取 ${key.name} 失败，回退默认值：$error');
      return null;
    }
  }

  /// 写入 JSON 键；编码 / 写盘失败只记日志。
  Future<void> writeJson<T extends Object>(
    DeviceJsonSettingKey<T> key,
    T value,
  ) => _enqueueWrite(key.name, (prefs) async {
    await prefs.setString(key.name, jsonEncode(key.encode(value)));
  });

  /// 排队执行一次写动作：同一偏好文件的前一次完成后才开始。
  Future<void> _enqueueWrite(
    String name,
    Future<void> Function(SharedPreferences prefs) action,
  ) async {
    final SharedPreferences prefs;
    try {
      prefs = await _openPreferences();
    } catch (error) {
      // 静默：持久化失败不值得打断用户操作，本次会话值由调用方保留。
      _log('写入 $name 失败（保留本次会话值）：$error');
      return;
    }

    final previous = _writeChains[prefs] ?? Future<void>.value();
    final next = previous.then((_) async {
      try {
        await action(prefs);
      } catch (error) {
        _log('写入 $name 失败（保留本次会话值）：$error');
      }
    });
    _writeChains[prefs] = next;
    await next;
  }
}

/// 标量值的存储类型（只在本文件内使用，外部由泛型约束）。
enum _ValueKind { boolean, integer, decimal, text, stringList }

void _log(String message) => debugPrint('[Molia] 设备本地设置：$message');
