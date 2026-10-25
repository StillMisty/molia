import 'package:flutter/foundation.dart';

import '../../data/settings/settings_access.dart';
import '../../data/settings/settings_keys.dart';

/// 新曲目加入收藏 / 自建列表时的位置。
enum LibraryAddPosition {
  /// 列表开头（默认）。
  top,

  /// 列表末尾。
  bottom;

  /// 解析持久化值：未知值（同步来的新值 / 损坏数据）回退默认的开头。
  static LibraryAddPosition parse(String? raw) =>
      raw == LibraryAddPosition.bottom.name
          ? LibraryAddPosition.bottom
          : LibraryAddPosition.top;
}

/// 加入位置偏好：`设置 › 播放`，**默认放列表开头**（跟人走）。
///
/// 两位消费者：写入网关按它取新曲目的 `sortOrder`（加入收藏与列表），设置页
/// 读写这一份实例——偏好只有一个家，不各读各的键。
class LibraryAddSettings extends ChangeNotifier {
  LibraryAddSettings({required SettingsAccess settings})
      : _settings = settings {
    _settings.bindReload(kLibraryAddPosition, init);
  }

  final SettingsAccess _settings;

  LibraryAddPosition _position =
      LibraryAddPosition.parse(kLibraryAddPosition.defaultValue);
  LibraryAddPosition get position => _position;

  /// 写入网关的布尔视图：true = 新曲目排到列表开头。
  bool get addToTop => _position == LibraryAddPosition.top;

  /// 读取持久化值（失败 / 缺项保持默认；不抛异常）。
  Future<void> init() async {
    try {
      _position = LibraryAddPosition.parse(
        await _settings.read(kLibraryAddPosition),
      );
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setPosition(LibraryAddPosition value) async {
    if (_position == value) return;
    _position = value;
    notifyListeners();
    try {
      await _settings.write(kLibraryAddPosition, value.name);
    } catch (_) {}
  }
}
