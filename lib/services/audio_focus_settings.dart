import 'package:flutter/foundation.dart';

import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../utils/snapshot_source.dart';

/// 音频焦点偏好：其他应用播放声音时是否继续播放（设置 › 播放，**默认开**）。
///
/// 播放服务把它当作 [ValueListenable] 订阅：开关即时生效，不重建播放器；
/// 关闭后回到「焦点丢失 → 暂停」，开启后 Android 忽略焦点丢失、iOS 混播。
///
/// 状态是单个布尔值（[state]），订阅面是 [changes]；UI 经
/// `audioFocusSettingsProvider` 读快照，设置项经 `audioFocusSettingsController`
/// 改值。
class AudioFocusSettings
    implements SnapshotSource<bool>, ValueListenable<bool> {
  AudioFocusSettings({required this._settings});

  final SettingsAccess _settings;
  final SnapshotSignal _changes = SnapshotSignal();

  bool _playWithOtherApps = kPlayWithOtherApps.defaultValue;

  /// 其他应用播放声音时继续播放。
  bool get playWithOtherApps => _playWithOtherApps;

  @override
  bool get state => _playWithOtherApps;

  @override
  bool get value => _playWithOtherApps;

  @override
  Listenable get changes => _changes;

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  /// 读取持久化值（失败 / 缺项保持默认；不抛异常）。
  Future<void> init() async {
    try {
      final enabled = await _settings.read(kPlayWithOtherApps);
      if (_playWithOtherApps == enabled) return;
      _playWithOtherApps = enabled;
      _changes.notify();
    } catch (_) {}
  }

  Future<void> setPlayWithOtherApps(bool value) async {
    if (_playWithOtherApps == value) return;
    _playWithOtherApps = value;
    _changes.notify();
    try {
      await _settings.write(kPlayWithOtherApps, value);
    } catch (_) {}
  }
}
