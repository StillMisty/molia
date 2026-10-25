/// 移动端播放功耗策略：应用前后台 + 桌面歌词是否可能展示。
///
/// **与 `AppPresence` 完全独立**：`AppPresence` 是桌面窗口可见性的事实源，
/// 被 `PlaybackObserver` / `ImagePreloadManager` / `ArtworkThemeSync` 用来
/// 停产封面预取、下一首歌词预取与取色；移动端退后台**不能**写进它，否则
/// 息屏时这些工作会一起停掉，桌面歌词悬浮窗的歌词 / 颜色 / 下一首体验反而
/// 退化。本策略只回答「播放链路要不要按前台节拍工作」：
/// - 位置采样：前台或桌面歌词开启 → 跟随播放器高频流；后台其余情形 →
///   1s 轮询；后台暂停 → 不采样（见 `LocalPlaybackService`）；
/// - 会话落盘：前台 1s，后台 15s；进入后台先强制整份落盘一次
///   （见 `PlaybackSessionCoordinator`）。
///
/// 只在值变化时通知；桌面端不接生命周期，默认一直前台。
library;

import 'package:flutter/foundation.dart';

class PlaybackPowerPolicy extends ChangeNotifier {
  PlaybackPowerPolicy({this._foreground = true});

  bool _foreground;
  bool _desktopLyricsActive = false;

  /// 应用是否在前台（Android / iOS 由生命周期事件维护；桌面恒为 true）。
  bool get isForeground => _foreground;

  /// 桌面歌词悬浮窗是否**可能**在展示。
  ///
  /// 只要求「平台支持 + 用户开启」：未授予悬浮窗权限时也保持 true——最多
  /// 多付一次 5Hz 采样，换授权后歌词 / 颜色不必等下一次前后台切换才对齐。
  bool get desktopLyricsActive => _desktopLyricsActive;

  /// 是否需要高频（约 5Hz）位置采样：前台或桌面歌词可能展示。
  bool get keepHighFrequencyPosition => _foreground || _desktopLyricsActive;

  /// 会话进度落盘节流：后台放宽到 15s（被系统杀死最多丢约 15s 进度）。
  Duration get sessionSaveInterval =>
      _foreground ? const Duration(seconds: 1) : const Duration(seconds: 15);

  /// 回到前台（幂等）。
  void markForeground() => _setForeground(true);

  /// 退到后台 / 息屏（幂等）。
  void markBackground() => _setForeground(false);

  /// 桌面歌词开关 / 平台能力变化时同步（幂等）。
  void setDesktopLyricsActive(bool value) {
    if (_desktopLyricsActive == value) return;
    _desktopLyricsActive = value;
    notifyListeners();
  }

  void _setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    notifyListeners();
  }
}
