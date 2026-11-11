/// 同步适配器依赖的最小设置面。
///
/// **为什么单独抽接口**：同步只需要「有哪些键 / 读当前值 / 应用远端值 /
/// 触发应用后的重载」；整张登记表、本地写入钩子与本地写方法都不下放。
/// `PrefsSyncAdapter` 只持有本接口，测试用 fake 即可覆盖远端应用与重载时序，
/// 不必构造真实注册表，也不会顺手把同步逻辑绑死在注册表实现上。
library;

import 'settings_key.dart';

abstract interface class SettingsSyncSurface {
  /// 参与同步的登记键（顺序即收集顺序）。
  List<SettingsKey<Object?>> get entries;

  /// 读取当前原始值（缺键 = 键的默认值）。
  Future<Object?> readRaw(SettingsKey<Object?> key);

  /// 应用远端值：不触发本机写入钩子，并登记该键等待 [reloadApplied]。
  ///
  /// 只登记不立即重载：一批远端记录应用完后统一触发，同一模块的多个键
  /// 只跑一次幂等重读。
  Future<void> applyRemote(SettingsKey<Object?> key, Object? value);

  /// 触发本批 [applyRemote] 应用过的键对应的模块重载，然后清空待处理集合。
  Future<void> reloadApplied();
}
