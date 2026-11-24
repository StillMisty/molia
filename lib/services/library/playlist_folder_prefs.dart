/// 列表分组展开 / 收起状态（设备本地）的唯一持有者。
///
/// 这是瞬时 UI 偏好，不是同步设置：换设备后重新按默认收起即可，重命名分组
/// 也不迁移旧名字的折叠状态。因此落在设备本地设置，不进设置注册表、
/// 不进同步类别。合集弹层是唯一消费方（宽屏左栏已删除）。
library;

import 'package:flutter/foundation.dart';

import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';
import '../../utils/snapshot_source.dart';

/// 分组折叠状态的不可变快照。
@immutable
class PlaylistFolderCollapseState {
  PlaylistFolderCollapseState(Set<String> collapsed)
    : collapsed = Set.unmodifiable(collapsed);

  /// 当前收起的分组名集合。
  final Set<String> collapsed;
}

class PlaylistFolderCollapseController
    implements SnapshotSource<PlaylistFolderCollapseState> {
  /// [settings] 仅测试注入；生产构造自己的设备本地入口。
  PlaylistFolderCollapseController({
    Set<String>? initiallyCollapsed,
    DeviceSettings? settings,
  }) : _settings = settings ?? DeviceSettings(),
       _collapsed = {...?initiallyCollapsed};

  static const String prefsKey = kPlaylistFolderCollapsedKeyName;

  final DeviceSettings _settings;
  final Set<String> _collapsed;
  final SnapshotSignal _changes = SnapshotSignal();
  bool _disposed = false;

  /// 是否读到过用户手动改过的折叠状态。null 持久值 = 首次进入，
  /// 分组按 [applyDefaults] 默认收起（当前所在分组展开）。
  bool _hasStoredState = false;

  Set<String> get collapsed => Set.unmodifiable(_collapsed);

  bool isCollapsed(String folder) => _collapsed.contains(folder);

  @override
  PlaylistFolderCollapseState get state =>
      PlaylistFolderCollapseState(_collapsed);

  @override
  Listenable get changes => _changes;

  /// 读取持久状态；读取失败保持当前内存值。重复调用安全。
  Future<void> load() async {
    final stored = await _settings.readIfPresent(kPlaylistFolderCollapsedKey);
    if (stored == null) return;
    _hasStoredState = true;
    _collapsed
      ..clear()
      ..addAll(stored);
    _notify();
  }

  /// 首次进入时把所有分组设为收起，只展开当前列表所在分组。
  ///
  /// 用户手动展开 / 收起过任意分组后 [_hasStoredState] 为 true，之后
  /// 不再套默认值，避免每次打开弹层都把用户展开的分组重新收起来。
  void applyDefaults(Iterable<String> folders, {String? expanded}) {
    if (_hasStoredState) return;
    var changed = false;
    for (final folder in folders) {
      if (folder.isEmpty) continue;
      final shouldCollapse = folder != expanded;
      if (shouldCollapse) {
        changed = _collapsed.add(folder) || changed;
      } else {
        changed = _collapsed.remove(folder) || changed;
      }
    }
    if (changed) _notify();
  }

  Future<void> toggle(String folder) async {
    _hasStoredState = true;
    if (!_collapsed.remove(folder)) _collapsed.add(folder);
    _notify();
    await _persist();
  }

  /// 分组重命名：旧名字的折叠状态不迁移；[merged] 目标分组也展开。
  Future<void> rename(String from, String to, {bool merged = false}) async {
    _hasStoredState = true;
    _collapsed.remove(from);
    if (merged) _collapsed.remove(to);
    _notify();
    await _persist();
  }

  /// 删除分组只清设备本地折叠状态。
  Future<void> delete(String folder) async {
    _hasStoredState = true;
    if (!_collapsed.remove(folder)) return;
    _notify();
    await _persist();
  }

  Future<void> _persist() =>
      _settings.write(kPlaylistFolderCollapsedKey, _collapsed.toList()..sort());

  void _notify() {
    if (!_disposed) _changes.notify();
  }

  void dispose() {
    _disposed = true;
  }
}
