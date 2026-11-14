import 'package:flutter/foundation.dart';

import '../../providers/lyrics_display_provider.dart';
import '../../providers/nav_provider.dart';
import '../../providers/sources_provider.dart';
import '../../providers/sync_provider.dart';
import '../../providers/update_provider.dart';
import '../../services/audio_focus_settings.dart';
import '../../services/data_saver_service.dart';
import '../../services/library/library_add_settings.dart';
import '../../services/lyrics_display/lyrics_output.dart';
import '../../services/play_statistics_service.dart';
import '../../services/scrobble/scrobble_service.dart';
import '../../services/source_swap/source_swap_settings.dart';
import '../../services/window/app_tray.dart';
import '../../services/window/tray_settings.dart';
import '../../utils/responsive.dart';

/// 设置首屏各卡的「这一行现在能不能出现」：可选子系统是否已挂载、平台能力
/// 是否具备，都在这里一次解析。
///
/// **为什么需要它**：九张卡依赖的可选子系统与平台能力各不相同，但「缺省就
/// 隐藏入口」必须是同一套判断。把探针收成一份不可变快照，卡片只需问
/// 「这一行可见吗」，不用各自拼 `null` 检查与平台分支；快照可在无 widget 树时
/// 构造与断言，行可见性也能直接测。
///
/// **边界**：本类只回答「有没有」，不持有值的订阅。值仍由消费行的
/// `Selector` / `watch` / `ValueListenable` 订阅——否则任意可选服务的通知
/// （例如同步进度）都会重建整页。设备本地值、设置键与同步类别也不在这里。
@immutable
class SettingsSectionAvailability {
  SettingsSectionAvailability({
    this.dataSaver,
    this.sourceSwap,
    this.audioFocus,
    this.sources,
    this.lyricsDisplay,
    this.scrobble,
    this.libraryAdd,
    this.statistics,
    this.sync,
    this.tray,
    this.update,
    this.nav,
    TargetPlatform? platform,
    bool? traySupported,
  }) : _platform = platform ?? defaultTargetPlatform,
       _traySupported = traySupported ?? AppTray.isSupported;

  /// 省流模式（可选：测试 / 精简挂载时缺省）。
  final DataSaverService? dataSaver;

  /// 自动换源偏好（可选：测试 / 精简挂载时缺省）。
  final SourceSwapSettings? sourceSwap;

  /// 音频焦点偏好（Android / iOS 挂载；桌面无实现）。
  final AudioFocusSettings? audioFocus;

  /// 音源管理门面（缺省时隐藏默认音质行）。
  final SourcesProvider? sources;

  /// 歌词显示投送面（能力决定桌面歌词 / 系统媒体歌词入口）。
  final LyricsDisplayProvider? lyricsDisplay;

  /// 听歌同步服务（缺省时隐藏入口）。
  final ScrobbleService? scrobble;

  /// 加入位置偏好（缺省时隐藏「加入位置」行）。
  final LibraryAddSettings? libraryAdd;

  /// 听歌统计服务（缺省时隐藏统计开关与入口）。
  final PlayStatisticsService? statistics;

  /// 跨设备同步门面（缺省时隐藏同步入口）。
  final SyncProvider? sync;

  /// 托盘偏好（与平台能力同时具备才显示托盘 / 窗口行）。
  final TraySettings? tray;

  /// 更新编排（缺省时隐藏更新入口）。
  final UpdateProvider? update;

  /// 导航偏好（缺省时隐藏启动页与底部导航行）。
  final NavProvider? nav;

  /// 平台判据；测试可显式传入，避免依赖运行测试的宿主平台。
  final TargetPlatform _platform;

  /// 宿主是否提供托盘能力；测试可显式传入。
  final bool _traySupported;

  /// 桌面平台（与 `isDesktopPlatform()` 同口径，平台可注入）。
  bool get isDesktop => isDesktopPlatform(_platform);

  bool get hasDataSaver => dataSaver != null;

  bool get hasSourceSwap => sourceSwap != null;

  bool get hasSources => sources != null;

  bool get hasScrobble => scrobble != null;

  bool get hasLibraryAdd => libraryAdd != null;

  bool get hasStatistics => statistics != null;

  bool get hasSync => sync != null;

  bool get hasUpdate => update != null;

  bool get hasNav => nav != null;

  /// 音频焦点行：有实现且不是桌面（桌面只有进程内混音，没有焦点事件）。
  bool get audioFocusRowVisible => audioFocus != null && !isDesktop;

  /// 音乐文件夹行：iOS 没有可浏览的共享目录，入口不出现。
  bool get musicFoldersRowVisible => _platform != TargetPlatform.iOS;

  /// 桌面歌词入口：输出端报告支持（能力就绪或待授权）才显示。
  bool get desktopLyricsVisible =>
      _lyricsCapability(LyricsOutputIds.desktop) !=
      LyricsOutputCapability.unsupported;

  /// 系统媒体歌词入口：同上。
  bool get systemMediaLyricsVisible =>
      _lyricsCapability(LyricsOutputIds.media) !=
      LyricsOutputCapability.unsupported;

  /// 两路歌词输出都不可用：卡片给一句解释，而不是静默只剩一条入口。
  bool get noLyricsOutputs =>
      !desktopLyricsVisible && !systemMediaLyricsVisible;

  /// 平台支持系统媒体但会话初始化失败（音频服务 init 返回 null）：
  /// 入口已消失，需要一条可见提示让用户自查。
  bool get mediaSessionLyricsHintVisible =>
      systemMediaLyricsVisible &&
      (lyricsDisplay?.mediaSessionInitFailed ?? false);

  /// 托盘与窗口行：平台有托盘且有偏好实例（Linux 精简桌面可能没有托盘）。
  bool get trayRowsVisible => _traySupported && tray != null;

  /// Linux 桌面卡底的托盘说明：托盘扩展是操作前提，Linux 上即使当前没有
  /// 托盘能力也提示（用户需要先装扩展）。
  bool get trayLinuxHintVisible => _platform == TargetPlatform.linux;

  LyricsOutputCapability _lyricsCapability(String outputId) =>
      lyricsDisplay?.capabilityOf(outputId) ??
      LyricsOutputCapability.unsupported;
}
