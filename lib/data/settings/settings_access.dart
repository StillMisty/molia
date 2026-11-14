/// 模块面的设置访问面：只含读 / 写 / 删除。
///
/// **为什么单独抽接口**：模块只需要「自己那几个键」的读写能力，不应拿到
/// 整张登记表与同步面（`readRaw` / `applyRemote` / `onWrite` / `reloadKeys`）。
/// 组合根构造唯一的 `SettingsRegistry`，再按模块 `mount(SettingsModule)`
/// 取得窄视图；模块构造参数只依赖本接口，漏注入会在编译期暴露，
/// 也不会各建一份私有注册表（私有注册表会漏掉同步写入钩子）。
///
/// 重载绑定不在本接口：键的声明与 reload 必须一起交给挂载点，模块自己
/// 后置绑定会让「声明了键但忘了 reload」重新变成可表达的静默缺陷。
library;

import 'settings_key.dart';

abstract interface class SettingsAccess {
  /// 读取当前值；缺键回退 [SettingsKey.defaultValue]。
  Future<T> read<T extends Object?>(SettingsKey<T> key);

  /// 写入并持久化；`null` 表示删除键（回到默认值）。
  Future<void> write<T extends Object?>(SettingsKey<T> key, T value);

  /// 删除键（读回默认值）。
  Future<void> clear(SettingsKey<Object?> key);
}
