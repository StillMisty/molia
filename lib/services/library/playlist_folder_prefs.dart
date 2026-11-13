/// 列表分组展开 / 收起状态（设备本地）。
///
/// 这是瞬时 UI 偏好，不是同步设置：换设备后重新按默认展开即可，重命名分组
/// 也不迁移旧名字的折叠状态。因此直接落 SharedPreferences，不进设置注册表、
/// 不进同步类别。
library;

import 'package:shared_preferences/shared_preferences.dart';

class PlaylistFolderCollapseStore {
  PlaylistFolderCollapseStore._();

  static const String _key = 'playlist_folder_collapsed_v1';

  /// 读取已收起的分组名集合；读取失败按全部展开处理。
  static Future<Set<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_key) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// 保存收起的分组名集合；失败不影响当前会话。
  static Future<void> save(Set<String> collapsed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, collapsed.toList()..sort());
    } catch (_) {
      // 持久化失败只影响下次启动的展开状态。
    }
  }
}
