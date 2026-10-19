import 'package:shared_preferences/shared_preferences.dart';

import 'settings_access.dart';
import 'settings_key.dart';
import 'settings_secret_store.dart';

/// 设置注册表：登记键的唯一家（读 / 写 / 同步往返 / 重载钩子）。
///
/// **边界**：登记 = 这个键有第二位消费者 —— 跨设备同步、备份导出、应用远端值
/// 后的定向重载，或整表驱动的测试。设备本地键（省流、缓存策略、全局字体、
/// 桌面歌词悬浮窗、AI 待处理批次、播放会话、曲库数据…）各自只有一位消费者，
/// 留在模块里；收进来只增加门房面积，不减少漂移。
///
/// **「一个键一个家」**：键名字面量只准出现在 `settings_keys.dart`；
/// 模块与同步适配器都经本类读写，不存在第二份类型转换。
class SettingsRegistry implements SettingsAccess {
  SettingsRegistry({
    required List<SettingsKey<Object?>> keys,
    SharedPreferences? preferences,
    SettingsSecretStore? secrets,
  })  : keys = List.unmodifiable(keys),
        _preferencesOverride = preferences,
        _secrets = secrets ?? const SecureSettingsSecretStore() {
    final names = <String>{};
    for (final key in this.keys) {
      assert(names.add(key.name), '设置键重复登记：${key.name}');
    }
  }

  /// 登记键总表（顺序即同步收集顺序）。
  final List<SettingsKey<Object?>> keys;

  /// 构造一个按键收窄的模块视图：只允许访问 [keys] 里声明的键。
  ///
  /// 组合根按模块现有的 reload 绑定 / 读写键传入列表；作用域之外的键在
  /// debug 断言、release 抛 [StateError]，避免模块悄悄读写别的模块的键。
  SettingsScope scope(Iterable<SettingsKey<Object?>> keys) =>
      SettingsScope._(this, List<SettingsKey<Object?>>.of(keys));

  /// 写入回调（组合根在同步栈建好后接线：把「这个键属于哪个同步类别」转成
  /// 待外发标记）。在同步栈之前构造，因此留作可后置赋值。
  ///
  /// 只允许绑定一次：两个钩子共存时后绑的会静默覆盖先绑的，同步会漏标记、
  /// 增量日志也会漏写，且没有任何可见报错。需要重新接线时先显式置 null。
  void Function(SettingsKey<Object?> key)? get onWrite => _onWrite;
  set onWrite(void Function(SettingsKey<Object?> key)? hook) {
    if (hook == null) {
      _onWrite = null;
      return;
    }
    assert(_onWrite == null, 'SettingsRegistry.onWrite 只允许绑定一次');
    if (_onWrite != null) {
      throw StateError('SettingsRegistry.onWrite 已绑定，拒绝第二次覆盖');
    }
    _onWrite = hook;
  }

  void Function(SettingsKey<Object?> key)? _onWrite;

  final SharedPreferences? _preferencesOverride;
  final SettingsSecretStore _secrets;

  /// 每个键的重载钩子（模块在构造时自绑，通常一个模块多个键共用一个）。
  final Map<String, List<Future<void> Function()>> _reloads = {};

  /// 不缓存实例：SharedPreferences 自身已缓存 `getInstance`，而测试会在构造后
  /// 用 `setMockInitialValues` 换掉存储，再走 reload 路径（缓存会读到旧值）。
  Future<SharedPreferences> _prefs() => _preferencesOverride == null
      ? SharedPreferences.getInstance()
      : Future.value(_preferencesOverride);

  /// 值的类型由键的静态类型推导（四种值类型各自对应一个 kind）。
  static SettingsValueKind _kindOf(SettingsKey<Object?> key) {
    if (key is SettingsKey<bool>) return SettingsValueKind.bool;
    if (key is SettingsKey<int>) return SettingsValueKind.int;
    if (key is SettingsKey<List<String>>) return SettingsValueKind.stringList;
    return SettingsValueKind.string;
  }

  /// 读取当前值；缺键回退键的默认值（读不到不写回，缺省与默认等价）。
  @override
  Future<T> read<T extends Object?>(SettingsKey<T> key) async =>
      (await readRaw(key)) as T;

  /// 写入并持久化；`null` 表示删除键（回到默认值）。
  @override
  Future<void> write<T extends Object?>(SettingsKey<T> key, T value) =>
      writeRaw(key, value);

  /// 删除键（读回默认值）；用于非空值类型（bool / int / List）。
  @override
  Future<void> clear(SettingsKey<Object?> key) => writeRaw(key, null);

  /// 同步面：读原始值（按 kind 解释；secure 盒保持旧的字符串语义）。
  ///
  /// 存储不可用（测试环境无插件 / 平台存储损坏）按默认值处理，不阻塞启动 ——
  /// 与各模块迁移前的行为一致；写入失败仍抛出，由调用方决定兜底策略。
  Future<Object?> readRaw(SettingsKey<Object?> key) async {
    try {
      final kind = _kindOf(key);
      if (key.store == SettingsValueStore.secure) {
        final raw = await _secrets.read(key.name);
        return raw ?? key.defaultValue;
      }
      final prefs = await _prefs();
      return switch (kind) {
        SettingsValueKind.string =>
          prefs.getString(key.name) ?? key.defaultValue,
        SettingsValueKind.bool => prefs.getBool(key.name) ?? key.defaultValue,
        SettingsValueKind.int => prefs.getInt(key.name) ?? key.defaultValue,
        SettingsValueKind.stringList =>
          prefs.getStringList(key.name) ?? key.defaultValue,
      };
    } catch (_) {
      return key.defaultValue;
    }
  }

  /// 同步面：写入远端值。
  ///
  /// 远端值可能来自旧版本设备，按 kind 宽容转换；转换失败与 `null` 一样删除
  /// 键（回到默认值），保证重复应用幂等。secure 盒只接受字符串。
  ///
  /// [remote] 为 true（同步适配器应用远端值）时不触发 [onWrite]：本机写入
  /// 钩子只标记**本地**变更（远端值不算本地修改，也不该再追加日志）。
  Future<void> writeRaw(
    SettingsKey<Object?> key,
    Object? value, {
    bool remote = false,
  }) async {
    await _writeRaw(key, value);
    if (!remote) onWrite?.call(key);
  }

  Future<void> _writeRaw(SettingsKey<Object?> key, Object? value) async {
    if (key.store == SettingsValueStore.secure) {
      if (value == null || (value is String && value.isEmpty)) {
        await _secrets.delete(key.name);
      } else if (value is String) {
        await _secrets.write(key.name, value);
      }
      return;
    }
    final prefs = await _prefs();
    if (value == null) {
      await prefs.remove(key.name);
      return;
    }
    switch (_kindOf(key)) {
      case SettingsValueKind.string:
        await prefs.setString(
          key.name,
          value is String ? value : value.toString(),
        );
      case SettingsValueKind.bool:
        final boolValue = value is bool
            ? value
            : (value is String ? value.toLowerCase() == 'true' : null);
        if (boolValue == null) {
          await prefs.remove(key.name);
        } else {
          await prefs.setBool(key.name, boolValue);
        }
      case SettingsValueKind.int:
        final intValue = value is num
            ? value.toInt()
            : (value is String ? int.tryParse(value) : null);
        if (intValue == null) {
          await prefs.remove(key.name);
        } else {
          await prefs.setInt(key.name, intValue);
        }
      case SettingsValueKind.stringList:
        if (value is List) {
          await prefs.setStringList(
            key.name,
            value.whereType<String>().toList(),
          );
        } else {
          await prefs.remove(key.name);
        }
    }
  }

  /// 绑定「应用远端值后重载」的钩子（模块在构造时自绑）。
  ///
  /// 同一个钩子绑多个键（如主题的 5 个键）只会执行一次：重载是幂等的整表
  /// 读取，按键重复跑没有意义。
  @override
  void bindReload(SettingsKey<Object?> key, Future<void> Function() reload) {
    _reloads.putIfAbsent(key.name, () => []).add(reload);
  }

  /// 触发 [names] 中已绑定键的重载（同步应用远端设置后由组合根调用）。
  Future<void> reloadKeys(Iterable<String> names) async {
    final hooks = <Future<void> Function()>{
      for (final name in names) ...?_reloads[name],
    };
    for (final hook in hooks) {
      await hook();
    }
  }
}

/// 模块面的按键视图：同一份注册表 / 同一份存储，只开放声明的键。
///
/// 不是第二个注册表：读写 / reload 都委托给构造它的 [SettingsRegistry]，
/// 因此同步写入钩子、密钥盒与远端值的宽容转换对模块完全一致。
class SettingsScope implements SettingsAccess {
  SettingsScope._(this._registry, List<SettingsKey<Object?>> keys)
      : keys = List.unmodifiable(keys),
        _names = {for (final key in keys) key.name};

  final SettingsRegistry _registry;

  /// 本作用域声明的键（顺序即构造时传入顺序）。
  final List<SettingsKey<Object?>> keys;

  final Set<String> _names;

  /// 作用域校验：不在声明列表里的键不允许读写 / 绑重载。
  ///
  /// debug 先断言给出调用栈；release 继续抛 [StateError]，保证越界访问不会
  /// 变成「另一个模块的键被静默改写」。
  void _check(SettingsKey<Object?> key) {
    if (_names.contains(key.name)) return;
    assert(_names.contains(key.name), '设置键不在作用域内：${key.name}');
    throw StateError('设置键不在作用域内：${key.name}');
  }

  @override
  Future<T> read<T extends Object?>(SettingsKey<T> key) {
    _check(key);
    return _registry.read(key);
  }

  @override
  Future<void> write<T extends Object?>(SettingsKey<T> key, T value) {
    _check(key);
    return _registry.write(key, value);
  }

  @override
  Future<void> clear(SettingsKey<Object?> key) {
    _check(key);
    return _registry.clear(key);
  }

  @override
  void bindReload(
    SettingsKey<Object?> key,
    Future<void> Function() reload,
  ) {
    _check(key);
    _registry.bindReload(key, reload);
  }
}
