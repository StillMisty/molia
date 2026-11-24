import 'package:flutter/foundation.dart';

import '../../data/settings/settings_access.dart';
import '../../data/settings/settings_keys.dart';
import '../../utils/snapshot_signal.dart';

/// 换源偏好的不可变快照（UI 经 `sourceSwapSettingsProvider` 读）。
@immutable
class SourceSwapSettingsState {
  const SourceSwapSettingsState({required this.autoEnabled});

  /// 播放失败后是否自动换源。
  final bool autoEnabled;
}

/// 换源偏好：自动换源开关（设置 › 播放，**默认开**；跟人走）。
///
/// 只影响播放失败后的自动行为；手动换源不受开关控制。
///
/// 状态是只读快照 [state]，订阅面是 [changes]（ADR-0041「启动期状态对象」）。
class SourceSwapSettings implements SnapshotSource<SourceSwapSettingsState> {
  SourceSwapSettings({required this._settings});

  final SettingsAccess _settings;
  final SnapshotSignal _changes = SnapshotSignal();

  bool _autoEnabled = kSourceSwapAutoEnabled.defaultValue;

  bool get autoEnabled => _autoEnabled;

  @override
  SourceSwapSettingsState get state =>
      SourceSwapSettingsState(autoEnabled: _autoEnabled);

  @override
  Listenable get changes => _changes;

  /// 读取持久化值（失败/缺项保持默认；不抛异常）。
  Future<void> init() async {
    try {
      _autoEnabled = await _settings.read(kSourceSwapAutoEnabled);
      _changes.notify();
    } catch (_) {}
  }

  Future<void> setAutoEnabled(bool value) async {
    if (_autoEnabled == value) return;
    _autoEnabled = value;
    _changes.notify();
    try {
      await _settings.write(kSourceSwapAutoEnabled, value);
    } catch (_) {}
  }
}
