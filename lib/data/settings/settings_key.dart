import '../../domain/models/device_sync.dart';

/// 设置值的存放盒。
enum SettingsValueStore { preferences, secure }

/// 设置值的类型（决定 SharedPreferences 读写与远端值的宽容转换）。
enum SettingsValueKind { string, bool, int, stringList }

/// 一个登记键：名字、默认值、同步类别、存放盒。
///
/// 只有「有第二消费者」的键才登记（跨设备同步 / 备份 / 应用远端后的重载 /
/// 整表驱动的测试）；设备本地键不登记，边界见 `settings_keys.dart`。
///
/// [defaultValue] 同时是「缺键时的回退值」和同步的「等于默认值 = 时间戳 0」
/// 规则输入（新设备接入时让已有配置胜出，见 ADR-0003 §5）。
class SettingsKey<T extends Object?> {
  const SettingsKey(
    this.name,
    this.defaultValue, {
    required this.category,
    this.store = SettingsValueStore.preferences,
  });

  /// 持久化键名（也是同步记录键）。
  final String name;

  /// 缺键时的回退值。
  final T defaultValue;

  /// 同步类别（跟人走 / 音源 / 凭证）。
  final SyncCategory category;

  /// 存放盒。
  final SettingsValueStore store;

  @override
  String toString() => 'SettingsKey($name)';
}
