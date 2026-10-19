/// 模块面的设置访问面：只含读 / 写 / 删除 / 重载绑定。
///
/// **为什么单独抽接口**：模块只需要「自己那几个键」的读写能力，不应拿到
/// 整张登记表与同步面（`readRaw` / `writeRaw` / `onWrite` / `reloadKeys`）。
/// 组合根构造唯一的 [SettingsRegistry]，再按模块分发
/// `registry.scope([...])`；模块构造参数只依赖本接口，漏注入会在编译期暴露，
/// 也不会再各建一份私有注册表（那份注册表会漏掉同步写入钩子）。
library;

import 'settings_key.dart';

abstract interface class SettingsAccess {
  /// 读取当前值；缺键回退 [SettingsKey.defaultValue]。
  Future<T> read<T extends Object?>(SettingsKey<T> key);

  /// 写入并持久化；`null` 表示删除键（回到默认值）。
  Future<void> write<T extends Object?>(SettingsKey<T> key, T value);

  /// 删除键（读回默认值）。
  Future<void> clear(SettingsKey<Object?> key);

  /// 绑定「应用远端值后重载」的钩子；同一模块可把多个键绑到同一个幂等
  /// 重载函数上。
  void bindReload(SettingsKey<Object?> key, Future<void> Function() reload);
}
