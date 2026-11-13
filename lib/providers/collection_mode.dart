/// 收藏页 / 曲库页的展示模式（歌曲 / 专辑 / 歌手）。
///
/// 设备本地 UI 状态：持久化到偏好，不登记设置注册表、不参与同步。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CollectionMode { songs, albums, artists }

class CollectionModeStore extends ChangeNotifier {
  CollectionModeStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static const String prefsKey = 'favorites_collection_mode_v1';

  final Future<SharedPreferences> Function() _preferences;
  CollectionMode _mode = CollectionMode.songs;
  bool _loaded = false;

  CollectionMode get mode => _mode;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await _preferences();
      final raw = prefs.getString(prefsKey);
      _mode = CollectionMode.values.firstWhere(
        (mode) => mode.name == raw,
        orElse: () => CollectionMode.songs,
      );
    } catch (e) {
      debugPrint('[Molia] 读取曲库模式失败: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setMode(CollectionMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await _preferences();
      await prefs.setString(prefsKey, mode.name);
    } catch (e) {
      debugPrint('[Molia] 保存曲库模式失败: $e');
    }
  }
}
