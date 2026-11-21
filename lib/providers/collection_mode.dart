/// 曲库聚合浏览的展示模式（专辑 / 歌手）。
///
/// 设备本地 UI 状态：持久化到偏好，不登记设置注册表、不参与同步。
/// 只服务「曲库」合集；收藏 / 历史 / 本地歌曲 / 自建列表不再有模式切换。
library;

import 'package:flutter/foundation.dart';

import '../data/settings/device_settings.dart';
import '../data/settings/device_settings_keys.dart';

enum CollectionMode { albums, artists }

class CollectionModeStore extends ChangeNotifier {
  /// [settings] 仅测试注入；生产构造自己的设备本地入口。
  CollectionModeStore({DeviceSettings? settings})
    : _settings = settings ?? DeviceSettings();

  static const String prefsKey = kLibraryBrowseModeKeyName;

  final DeviceSettings _settings;
  CollectionMode _mode = CollectionMode.albums;
  bool _loaded = false;

  CollectionMode get mode => _mode;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    final raw = await _settings.read(kLibraryBrowseModeKey);
    _mode = CollectionMode.values.firstWhere(
      (mode) => mode.name == raw,
      orElse: () => CollectionMode.albums,
    );
    _loaded = true;
    notifyListeners();
  }

  Future<void> setMode(CollectionMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    await _settings.write(kLibraryBrowseModeKey, mode.name);
  }
}
