import 'package:flutter/foundation.dart';

import '../../data/settings/settings_access.dart';
import '../../data/settings/settings_keys.dart';
import '../../domain/models/cover_style.dart';

/// 封面风格偏好：设置页与所有封面消费面共享的唯一一份状态。
///
/// 两个键都按「跟人走」登记（[SyncCategory.settings]），跨设备同步应用远端
/// 设置后由 [bindReload] 触发 [init] 重载。非法持久化值回退默认：
/// 风格 = 原图、范围 = 仅播放中——即「不改变既有默认行为」。
class CoverStyleSettings extends ChangeNotifier {
  CoverStyleSettings({required this._settings}) {
    _settings.bindReload(kCoverStyle, init);
    _settings.bindReload(kCoverStyleScope, init);
  }

  final SettingsAccess _settings;

  CoverStyle _style = CoverStyle.fromId(kCoverStyle.defaultValue);
  CoverStyleScope _scope = CoverStyleScope.fromId(
    kCoverStyleScope.defaultValue,
  );

  /// 当前风格（默认 [CoverStyle.original]）。
  CoverStyle get style => _style;

  /// 当前作用范围（默认 [CoverStyleScope.player]，仅当前播放曲目）。
  CoverStyleScope get scope => _scope;

  /// 读取持久化值（失败 / 缺项保持默认；不抛异常）。
  ///
  /// 同时作为远端设置应用后的重载入口：两个键任一变化都会走这里。
  Future<void> init() async {
    try {
      final style = CoverStyle.fromId(await _settings.read(kCoverStyle));
      final scope = CoverStyleScope.fromId(
        await _settings.read(kCoverStyleScope),
      );
      if (style == _style && scope == _scope) return;
      _style = style;
      _scope = scope;
      notifyListeners();
    } catch (_) {}
  }

  /// 显式重载（与 [init] 同义，便于调用方表达意图）。
  Future<void> reload() => init();

  Future<void> setStyle(CoverStyle value) async {
    if (_style == value) return;
    _style = value;
    notifyListeners();
    try {
      await _settings.write(kCoverStyle, value.id);
    } catch (_) {}
  }

  Future<void> setScope(CoverStyleScope value) async {
    if (_scope == value) return;
    _scope = value;
    notifyListeners();
    try {
      await _settings.write(kCoverStyleScope, value.id);
    } catch (_) {}
  }
}
