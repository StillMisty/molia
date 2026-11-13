/// 列表分组展开 / 收起状态（设备本地）的唯一持有者。
///
/// 这是瞬时 UI 偏好，不是同步设置：换设备后重新按默认展开即可，重命名分组
/// 也不迁移旧名字的折叠状态。因此直接落 SharedPreferences，不进设置注册表、
/// 不进同步类别。页面侧栏与合集弹层共用同一个 controller，避免两套内存状态
/// 各改各的。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlaylistFolderCollapseController extends ChangeNotifier {
  PlaylistFolderCollapseController({Set<String>? initiallyCollapsed})
    : _collapsed = {...?initiallyCollapsed};

  static const String prefsKey = 'playlist_folder_collapsed_v1';

  final Set<String> _collapsed;
  bool _disposed = false;

  Set<String> get collapsed => Set.unmodifiable(_collapsed);

  bool isCollapsed(String folder) => _collapsed.contains(folder);

  /// 读取持久状态；读取失败按全部展开处理。重复调用安全。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = (prefs.getStringList(prefsKey) ?? const <String>[])
          .toSet();
      _collapsed
        ..clear()
        ..addAll(stored);
      _notify();
    } catch (_) {
      // 读取失败保持当前内存状态（默认全部展开）。
    }
  }

  Future<void> toggle(String folder) async {
    if (!_collapsed.remove(folder)) _collapsed.add(folder);
    _notify();
    await _persist();
  }

  /// 分组重命名：旧名字的折叠状态不迁移；[merged] 目标分组也展开。
  Future<void> rename(String from, String to, {bool merged = false}) async {
    _collapsed.remove(from);
    if (merged) _collapsed.remove(to);
    _notify();
    await _persist();
  }

  /// 删除分组只清设备本地折叠状态。
  Future<void> delete(String folder) async {
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
