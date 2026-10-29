/// 移动端播放功耗策略：应用前后台 + 桌面歌词 / 其他歌词输出是否可能展示。
///
/// **与 `AppPresence` 完全独立**：`AppPresence` 是桌面窗口可见性的事实源；
/// 移动端退后台**不能**写进它，否则会把桌面托盘语义和移动端生命周期混在
/// 一起。本策略按「后台还有没有展示面 / 输出需要」回答三类问题：
/// - 播放节拍：位置采样（前台或桌面歌词开启 → 高频流；后台其余情形 →
///   1s 轮询；后台暂停 → 不采样）；会话落盘不在本策略里做周期调度，
///   只在动作 / 进入后台时提交一次（见 `PlaybackSessionCoordinator`）；
/// - 视觉工作：封面预取只为应用内界面服务，后台不跑；封面取色在桌面歌词
///   可能展示时仍要跑（悬浮窗可跟随封面配色）；
/// - 歌词与音频预取：后台只有存在歌词输出（悬浮窗 / 通知 / 蓝牙）时才取词；
///   下一首直链仍预热，但音频字节预取只在应用前台进行（后台听歌时不再为了
///   「下一首秒开」提前占满网络与磁盘）。
///
/// 只在值变化时通知；桌面端不接生命周期，默认一直前台。
library;

import 'package:flutter/foundation.dart';

class PlaybackPowerPolicy extends ChangeNotifier {
  PlaybackPowerPolicy({this._foreground = true});

  bool _foreground;
  bool _desktopLyricsActive = false;
  bool _lyricsOutputActive = false;

  /// 应用是否在前台（Android / iOS 由生命周期事件维护；桌面恒为 true）。
  bool get isForeground => _foreground;

  /// 桌面歌词悬浮窗是否**可能**在展示。
  ///
  /// 只要求「平台支持 + 用户开启」：未授予悬浮窗权限时也保持 true——最多
  /// 多付一次 5Hz 采样，换授权后歌词 / 颜色不必等下一次前后台切换才对齐。
  bool get desktopLyricsActive => _desktopLyricsActive;

  /// 是否存在任一歌词输出（桌面悬浮窗 / 通知锁屏 / 蓝牙）。
  ///
  /// 只用于判断后台是否值得取词：没有输出时歌词只服务应用内页面，退后台
  /// 就没有展示面，取词纯属白耗网络与解析 CPU。
  bool get lyricsOutputActive => _lyricsOutputActive;

  /// 是否需要高频（约 5Hz）位置采样：前台或桌面歌词可能展示。
  bool get keepHighFrequencyPosition => _foreground || _desktopLyricsActive;

  /// 是否允许预取封面：封面只在应用内界面展示，后台（含息屏、悬浮窗）
  /// 没有任何消费面，解码只会占内存与 CPU。
  bool get canPreloadCovers => _foreground;

  /// 是否允许提取封面配色：后台只有桌面歌词可能用到（「跟随封面」配色）。
  /// 通知锁屏不消费主题色，因此不把 [lyricsOutputActive] 算进来。
  bool get canExtractArtworkPalette => _foreground || _desktopLyricsActive;

  /// 后台是否需要为歌词输出取词：前台（页面可能打开）或任一输出启用。
  bool get shouldLoadLyrics =>
      _foreground || _desktopLyricsActive || _lyricsOutputActive;

  /// 是否允许把下一首音频字节预取到缓存。
  ///
  /// 直链预热不受此限制（见 `NextTrackPreloader`）：后台听歌仍能快速拿到
  /// 下一首地址，但不再一边播当前曲目一边下载整首下一曲——这是后台最重的
  /// 网络 / 磁盘工作，会明显拉高熄屏功耗。
  bool get canPredownloadNextTrackBytes => _foreground;

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

  /// 任一歌词输出开关变化时同步（幂等）。
  void setLyricsOutputActive(bool value) {
    if (_lyricsOutputActive == value) return;
    _lyricsOutputActive = value;
    notifyListeners();
  }

  void _setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    notifyListeners();
  }
}
