import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';
import '../../domain/models/app_release.dart';

/// 已交给安装器、等待下次启动确认的更新目标。
///
/// 为什么需要：桌面替换脚本 / Android 系统安装器接管后进程会退出，应用
/// 无法在本次会话里得知结果；下次启动拿当前版本对比目标版本即可判断
/// 「装成功」还是「没装完」。
class PendingUpdate {
  const PendingUpdate({required this.version, required this.build});

  final String version;
  final int build;

  /// 当前安装的版本是否已达到（或超过）这次待确认的目标。
  bool isSatisfiedBy({required String version, required int build}) {
    final compared = compareAppVersions(version, this.version);
    return compared > 0 || (compared == 0 && build >= this.build);
  }

  @override
  bool operator ==(Object other) =>
      other is PendingUpdate &&
      other.version == version &&
      other.build == build;

  @override
  int get hashCode => Object.hash(version, build);

  @override
  String toString() => 'PendingUpdate($version+$build)';
}

/// 应用内更新的本地偏好（设备本地设置）。
///
/// 这些键都是设备本地项（更新渠道 / 镜像在不同设备可以不同，且只有一个
/// 消费者），按仓库约定不登记进 `SettingsRegistry`（见 settings_keys.dart
/// 的分档说明）。
class UpdatePreferences {
  /// [settings] 仅测试注入；生产构造自己的设备本地入口。
  UpdatePreferences({DeviceSettings? settings})
    : _settings = settings ?? DeviceSettings();

  static const String keyAutoCheck = kUpdateAutoCheckKeyName;
  static const String keyCheckOnStartup = kUpdateCheckOnStartupKeyName;
  static const String keyCheckDaily = kUpdateCheckDailyKeyName;
  static const String keyChannel = kUpdateChannelKeyName;
  static const String keyManifestOverride = kUpdateManifestOverrideKeyName;
  static const String keyDownloadPrefix = kUpdateDownloadPrefixKeyName;
  static const String keyLastCheckAt = kUpdateLastCheckAtKeyName;
  static const String keyPendingVersion = kUpdatePendingVersionKeyName;
  static const String keyPendingBuild = kUpdatePendingBuildKeyName;

  /// 自动检查默认关闭：更新是低频行为，且桌面端会自动替换文件，
  /// 必须由用户显式开启（设置页「启动时检查 / 每日检查」）。
  static const bool defaultCheckOnStartup = kDefaultUpdateCheckOnStartup;
  static const bool defaultCheckDaily = kDefaultUpdateCheckDaily;
  static const UpdateChannel defaultChannel = UpdateChannel.stable;

  final DeviceSettings _settings;

  bool _checkOnStartup = defaultCheckOnStartup;
  bool _checkDaily = defaultCheckDaily;
  UpdateChannel _channel = defaultChannel;
  String _manifestOverride = '';
  String _downloadPrefix = '';
  DateTime? _lastCheckedAt;
  PendingUpdate? _pendingUpdate;

  bool get checkOnStartup => _checkOnStartup;
  bool get checkDaily => _checkDaily;

  /// 任一种自动检查开启（诊断导出与设置入口副标题使用）。
  bool get anyAutoCheckEnabled => _checkOnStartup || _checkDaily;

  UpdateChannel get channel => _channel;
  String get manifestUrlOverride => _manifestOverride;
  String get downloadPrefix => _downloadPrefix;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  PendingUpdate? get pendingUpdate => _pendingUpdate;

  Future<void> load() async {
    try {
      // 旧版只有一个「自动检查」开关（启动时 + 24h 节流）。新键缺失时把它
      // 迁移成「启动时检查 + 每日检查」，用户主动改过任一开关后新键即落盘，
      // 后续不再读旧值。
      final startup = await _settings.readIfPresent(kUpdateCheckOnStartupKey);
      final daily = await _settings.readIfPresent(kUpdateCheckDailyKey);
      if (startup == null && daily == null) {
        final legacy = await _settings.read(kUpdateAutoCheckKey);
        _checkOnStartup = legacy;
        _checkDaily = legacy;
      } else {
        _checkOnStartup = startup ?? defaultCheckOnStartup;
        _checkDaily = daily ?? defaultCheckDaily;
      }
      _channel = UpdateChannel.fromWire(
        await _settings.read(kUpdateChannelKey),
      );
      _manifestOverride = await _settings.read(kUpdateManifestOverrideKey);
      _downloadPrefix = await _settings.read(kUpdateDownloadPrefixKey);
      final lastCheck = await _settings.read(kUpdateLastCheckAtKey);
      _lastCheckedAt = lastCheck <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastCheck);
      final pendingVersion = await _settings.read(kUpdatePendingVersionKey);
      final pendingBuild = await _settings.readIfPresent(
        kUpdatePendingBuildKey,
      );
      _pendingUpdate = null;
      if (pendingVersion.isNotEmpty && pendingBuild != null) {
        _pendingUpdate = PendingUpdate(
          version: pendingVersion,
          build: pendingBuild,
        );
      }
    } catch (_) {
      // 读取失败保持默认值：更新配置坏了不应该影响启动；pending 不完整
      // 时按「没有待确认更新」处理，避免误报安装失败。
      _pendingUpdate = null;
    }
  }

  Future<void> setCheckOnStartup(bool value) async {
    _checkOnStartup = value;
    await _writeAutoCheckKeys();
  }

  Future<void> setCheckDaily(bool value) async {
    _checkDaily = value;
    await _writeAutoCheckKeys();
  }

  /// 两个新键一起写：任一开关被用户改过即完成旧键迁移，避免下次启动
  /// 又从旧 `update_auto_check` 回填。
  Future<void> _writeAutoCheckKeys() async {
    await _settings.write(kUpdateCheckOnStartupKey, _checkOnStartup);
    await _settings.write(kUpdateCheckDailyKey, _checkDaily);
  }

  Future<void> setChannel(UpdateChannel channel) async {
    _channel = channel;
    await _settings.write(kUpdateChannelKey, channel.wireName);
  }

  Future<void> setManifestUrlOverride(String value) async {
    _manifestOverride = value.trim();
    await _settings.write(kUpdateManifestOverrideKey, _manifestOverride);
  }

  Future<void> setDownloadPrefix(String value) async {
    _downloadPrefix = value.trim();
    await _settings.write(kUpdateDownloadPrefixKey, _downloadPrefix);
  }

  Future<void> markChecked(DateTime at) async {
    _lastCheckedAt = at;
    await _settings.write(kUpdateLastCheckAtKey, at.millisecondsSinceEpoch);
  }

  /// 记录「已交给安装器」的目标版本；写入失败只丢下次启动的回执。
  Future<void> markPendingUpdate({
    required String version,
    required int build,
  }) async {
    _pendingUpdate = PendingUpdate(version: version, build: build);
    await _settings.write(kUpdatePendingVersionKey, version);
    await _settings.write(kUpdatePendingBuildKey, build);
  }

  /// 清除待确认更新（安装失败 / 用户取消 / 已消费回执）。
  Future<void> clearPendingUpdate() async {
    _pendingUpdate = null;
    await _settings.remove(kUpdatePendingVersionKey);
    await _settings.remove(kUpdatePendingBuildKey);
  }
}
