/// 列表分组展开 / 收起状态（设备本地）的唯一持有者。
///
/// 这是瞬时 UI 偏好，不是同步设置：换设备后重新按默认收起即可，重命名分组
/// 也不迁移旧名字的折叠状态。因此直接落 SharedPreferences，不进设置注册表、
/// 不进同步类别。合集弹层是唯一消费方（宽屏左栏已删除）。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlaylistFolderCollapseController extends ChangeNotifier {
  PlaylistFolderCollapseController({Set<String>? initiallyCollapsed})
    : _collapsed = {...?initiallyCollapsed};

  static const String prefsKey = 'playlist_folder_collapsed_v1';

  final Set<String> _collapsed;
  bool _disposed = false;

  /// 是否读到过用户手动改过的折叠状态。null 持久值 = 首次进入，
  /// 分组按 [applyDefaults] 默认收起（当前所在分组展开）。
  bool _hasStoredState = false;

  Set<String> get collapsed => Set.unmodifiable(_collapsed);

  bool isCollapsed(String folder) => _collapsed.contains(folder);

  /// 读取持久状态；读取失败保持当前内存值。重复调用安全。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(prefsKey);
      if (stored == null) return;
      _hasStoredState = true;
      _collapsed
        ..clear()
        ..addAll(stored);
      _notify();
    } catch (_) {
      // 读取失败保持当前内存状态。
    }
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

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(prefsKey, _collapsed.toList()..sort());
    } catch (_) {
      // 持久化失败只影响下次启动的展开状态。
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
