/// 设备本地设置存储：所有不跟人走的键共用一条读写 / 失败策略。
///
/// **边界**：登记键（`settings_keys.dart`）按「换设备后是否期望看到同一份」
/// 收集并参与同步；本模块只服务显式留在设备本地的状态（音量、播放手感、
/// 首次引导标记…）。它不登记进 `SettingsRegistry`，也不同步 / 备份。
///
/// **为什么要有这一层**：设备本地键此前散落在各自模块里，每个模块自带
/// `SharedPreferences.getInstance`、JSON 编解码与静默吞错；同一个键因此可能
/// 出现第二套默认值或第二种失败口径。收拢后：
/// - 键的名字 / 默认值 / 类型只在键表声明一次；
/// - 写盘串行（不会有两个 `set*` 交叉），JSON 只有一个编解码入口；
/// - 读失败回默认、写失败只记日志，调用方不必各自重复 try/catch。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// 设备本地设置值的类型。
///
/// 命名与 `SettingsValueKind` 不同：这里的值是设备本地的完整集合
/// （含 double，音量等连续值需要），且不参与远端值的宽容转换。
enum DeviceSettingKind { boolean, integer, decimal, text, stringList }

/// 一个设备本地设置键：名字、缺键默认值、值类型。
///
/// 与 `SettingsKey` 的差别是**没有同步类别 / 存放盒**：设备本地键不参与
/// 同步与备份，也没有凭据盒。默认值同时是读取失败时的回退值。
class DeviceSettingKey<T extends Object> {
  const DeviceSettingKey(this.name, this.defaultValue, {required this.kind});

  /// 持久化键名（SharedPreferences 的键，保持既有字符串不变）。
  final String name;

  /// 缺键 / 读取失败时的回退值。
  final T defaultValue;

  /// 值的类型（决定 `get*` / `set*`）。
  final DeviceSettingKind kind;

  @override
  String toString() => 'DeviceSettingKey($name)';
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
/// 不缓存 prefs 实例：测试会在构造后替换 mock 存储，缓存会读到旧值。
/// 写入串行：一次 `set*` 完成后再开始下一次，避免整文件偏好被交叉重写。
class DeviceSettings {
  /// 生产 / 测试共用构造：`preferences` 为空时走 SharedPreferences 单例。
  DeviceSettings({this._preferences}) : _open = SharedPreferences.getInstance;

  /// 生产入口（语义别名，便于组合根区分「设备本地」与登记键）。
  factory DeviceSettings.production() => DeviceSettings();

  /// 测试注入打开失败 / 延迟的存储；生产不要使用。
  @visibleForTesting
  DeviceSettings.withOpener(Future<SharedPreferences> Function() opener)
    : _preferences = null,
      _open = opener;

  final SharedPreferences? _preferences;
  final Future<SharedPreferences> Function() _open;

  /// 串行写链：上一个动作结束后才启动下一个。
  Future<void> _writeChain = Future<void>.value();

  Future<SharedPreferences> _openPreferences() {
    final injected = _preferences;
    return injected == null ? _open() : Future.value(injected);
  }

  /// 读取标量；缺键 / 读取失败回退 [DeviceSettingKey.defaultValue]。
  Future<T> read<T extends Object>(DeviceSettingKey<T> key) async {
    try {
      final prefs = await _openPreferences();
      final stored = switch (key.kind) {
        DeviceSettingKind.boolean => prefs.getBool(key.name),
        DeviceSettingKind.integer => prefs.getInt(key.name),
        DeviceSettingKind.decimal => prefs.getDouble(key.name),
        DeviceSettingKind.text => prefs.getString(key.name),
        DeviceSettingKind.stringList => prefs.getStringList(key.name),
      };
      if (stored == null) return key.defaultValue;
      if (stored is T) return stored;
      // 存储里的类型与键声明不一致（手工改偏好 / 旧版本残留）：按默认值处理。
      _log('读取 ${key.name} 的类型是 ${stored.runtimeType}，回退默认值');
      return key.defaultValue;
    } catch (error) {
      _log('读取 ${key.name} 失败，回退默认值：$error');
      return key.defaultValue;
    }
  }

  /// 写入标量；失败只记日志，不向调用方抛错。
  Future<void> write<T extends Object>(DeviceSettingKey<T> key, T value) =>
      _enqueueWrite(key.name, (prefs) async {
        switch (key.kind) {
          case DeviceSettingKind.boolean:
            await prefs.setBool(key.name, value as bool);
          case DeviceSettingKind.integer:
            await prefs.setInt(key.name, value as int);
          case DeviceSettingKind.decimal:
            await prefs.setDouble(key.name, (value as num).toDouble());
          case DeviceSettingKind.text:
            await prefs.setString(key.name, value as String);
          case DeviceSettingKind.stringList:
            await prefs.setStringList(key.name, (value as List).cast<String>());
        }
      });

  /// 删除键（读回默认值）；失败只记日志。
  Future<void> remove<T extends Object>(DeviceSettingKey<T> key) =>
      _enqueueWrite(key.name, (prefs) async {
        await prefs.remove(key.name);
      });

  /// 读取 JSON 对象；缺键、非对象、解析失败都回 `null`（调用方回默认值）。
  ///
  /// 把「多个值合并成一个键」的编解码收在这一处：桌面 shared_preferences
  /// 每次写都会重写整个偏好文件，两次写入就是两次整文件 I/O。
  Future<Map<String, dynamic>?> readJson(DeviceSettingKey<String> key) async {
    try {
      final prefs = await _openPreferences();
      final raw = prefs.getString(key.name);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      _log('读取 ${key.name} 不是 JSON 对象，回退默认值');
      return null;
    } catch (error) {
      _log('读取 ${key.name} 失败，回退默认值：$error');
      return null;
    }
  }

  /// 写入 JSON 对象；编码 / 写盘失败只记日志。
  Future<void> writeJson(
    DeviceSettingKey<String> key,
    Map<String, Object?> value,
  ) => _enqueueWrite(key.name, (prefs) async {
    await prefs.setString(key.name, jsonEncode(value));
  });

  /// 排队执行一次写动作：前一次完成后才开始，失败也不会打断后面的写。
  Future<void> _enqueueWrite(
    String name,
    Future<void> Function(SharedPreferences prefs) action,
  ) {
    final next = _writeChain.then((_) async {
      try {
        final prefs = await _openPreferences();
        await action(prefs);
      } catch (error) {
        // 静默：持久化失败不值得打断用户操作，本次会话值由调用方保留。
        _log('写入 $name 失败（保留本次会话值）：$error');
      }
    });
    _writeChain = next;
    return next;
  }
}

void _log(String message) => debugPrint('[Molia] 设备本地设置：$message');
