/// 一个设置模块的挂载描述：作用域键 + 应用远端值后的重载行为。
///
/// **为什么键和 reload 必须同屋**：注册表的重载钩子是按键后置绑定的，
/// 只声明键、忘绑钩子不会编译失败；远端值落地后模块的内存状态仍是旧值，
/// UI 会一直陈旧到下次重启。把两者收进同一个值并在构造时校验「每个键都被
/// 某次 reload 覆盖」，漏接就从静默缺陷变成启动期错误。
library;

import 'settings_key.dart';

/// 模块内一组共用同一重载的键。
///
/// 同一模块可以有多组（例如 AI 的连接凭证回读与推荐偏好重读是两条路径）；
/// 一个键只能属于一组——重复绑定会让一次远端应用触发多次重读。
typedef SettingsReload = ({
  List<SettingsKey<Object?>> keys,
  Future<void> Function() reload,
});

class SettingsModule {
  /// 全部键共用同一个重载（最常见：模块只有一份内存状态）。
  factory SettingsModule({
    required Iterable<SettingsKey<Object?>> keys,
    required Future<void> Function() reload,
  }) {
    final declared = List<SettingsKey<Object?>>.unmodifiable(keys);
    return SettingsModule.withReloads(
      keys: declared,
      reloads: [(keys: declared, reload: reload)],
    );
  }

  /// 按键分组重载：作用域仍是 [keys] 的并集，但不同键触发不同的重读路径。
  SettingsModule.withReloads({
    required Iterable<SettingsKey<Object?>> keys,
    required Iterable<SettingsReload> reloads,
  }) : keys = List.unmodifiable(keys),
       reloads = List<SettingsReload>.unmodifiable([
         for (final group in reloads)
           (
             keys: List<SettingsKey<Object?>>.unmodifiable(group.keys),
             reload: group.reload,
           ),
       ]) {
    if (this.keys.isEmpty) {
      throw ArgumentError.value(keys, 'keys', '设置模块至少声明一个键');
    }
    final declared = <String>{};
    for (final key in this.keys) {
      if (!declared.add(key.name)) {
        throw ArgumentError.value(key.name, 'keys', '设置键重复声明');
      }
    }
    final covered = <String>{};
    for (final group in this.reloads) {
      for (final key in group.keys) {
        if (!declared.contains(key.name)) {
          throw ArgumentError.value(key.name, 'reloads', '重载键不在模块作用域内');
        }
        if (!covered.add(key.name)) {
          throw ArgumentError.value(key.name, 'reloads', '设置键重复绑定重载');
        }
      }
    }
    final missing = declared.difference(covered);
    if (missing.isNotEmpty) {
      throw ArgumentError.value(
        missing.join(', '),
        'keys',
        '声明了设置键但没有绑定应用远端值后的重载',
      );
    }
  }

  /// 本模块的作用域键（顺序即注册表返回的 scope 顺序）。
  final List<SettingsKey<Object?>> keys;

  /// 应用远端值后的重载分组；各组键互不重叠且覆盖 [keys]。
  final List<SettingsReload> reloads;
}
