/// 桌面壳栈：托盘行为偏好（关闭时最小化到托盘）+ 统一退出路径 +
/// 关闭请求分流 + 托盘菜单状态同步。
///
/// 托盘实现（`app_tray.dart` 出口）与窗口 chrome 只在这里出现，
/// 其余组合根代码不感知桌面插件；首帧后的托盘创建由 [DesktopStack.initTray]
/// 承担（图标资源可读、不占启动关键路径）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../services/app_branding_service.dart';
import '../../services/app_presence.dart';
import '../../services/language_service.dart';
import '../../services/play_statistics_service.dart';
import '../../services/window/app_tray.dart';
import '../../services/window/tray_settings.dart';
import '../../services/window/window_chrome.dart';

/// 桌面壳栈产物。
typedef DesktopStack = ({
  TraySettings traySettings,

  /// 统一退出路径（托盘「退出」/ 更新安装后的重启替换）。
  Future<void> Function() quitApp,

  /// 首帧后创建托盘（含宿主探测预热）。
  void Function() initTray,
});

/// 装配托盘偏好、退出路径与关闭策略（无托盘的平台全部是安全的空操作）。
Future<DesktopStack> buildDesktopStack({
  required PlaybackProvider playback,
  required LibraryProvider libraryProvider,
  required PlayStatisticsService playStatisticsService,
}) async {
  // 托盘与关闭行为（设备本地偏好，不登记设置注册表）：关闭窗口时默认
  // 最小化到托盘（播放不中断）；偏好可在设置 › 通用 › 桌面 切换为直接退出。
  final traySettings = TraySettings();
  await traySettings.init();

  // 统一退出路径（托盘「退出」/ 更新安装后的重启替换）：先把播放会话与
  // 统计落盘（等价于 App 进入后台的 flush，两者都是同步的「标记 + 触发」），
  // 再无视关闭策略销毁窗口。落盘失败不阻断退出（否则窗口已关、进程却退不掉）。
  Future<void> quitApp() async {
    try {
      playback.flushPlaybackSession();
      playStatisticsService.flush();
    } catch (e) {
      debugPrint('[Molia] 退出前落盘失败（继续退出）: $e');
    }
    await WindowChrome.quit();
  }

  // 关闭请求（顶栏关闭键 / 系统关闭按钮）→ 按设置分流：隐藏到托盘或退出。
  // 无托盘宿主（GNOME 未装 AppIndicator 扩展、无面板的裸 WM）时不做隐藏：
  // 藏起来就没有找回入口，退回直接退出（设置页对 Linux 有同一提示）。
  WindowChrome.setCloseHandler(() async {
    if (traySettings.closeToTray && await AppTray.detectHost()) {
      // 先置休眠态并等这一帧把界面卸下来（窗口还可见、帧还开着），再隐藏：
      // 隐藏后平台会停帧，休眠树若没建成就要等恢复窗口才建，托盘期省不下来。
      // endOfFrame 自带超时兜底，异常路径不把「点关闭」卡死。
      AppPresence.instance.markTrayHidden();
      await WidgetsBinding.instance.endOfFrame
          .timeout(const Duration(seconds: 2), onTimeout: () {});
      await WindowChrome.hide();
    } else {
      await quitApp();
    }
  });

  // 菜单动作全部落到既有 provider；文案 / tooltip / 菜单可用性跟随播放、
  // 收藏、语言与品牌名变化。
  void syncTray() {
    final snapshot = playback.snapshot;
    final track = snapshot.current;
    final brand = AppBrandingService.titleNotifier.value;
    AppTray.setLabels(_trayLabels());
    AppTray.setPlaybackState(
      hasTrack: track != null,
      isPlaying: snapshot.isPlaying,
    );
    AppTray.setFavorite(
      track != null &&
          libraryProvider.isFavorite(track.id.sourceKey, track.id.id),
    );
    AppTray.setTooltip(
      track == null ? brand : '$brand · ${_trackTooltip(track)}',
    );
    // 任务栏 / 窗口列表标题：显示当前曲目（无曲目回退应用名）。与托盘
    // tooltip 同一份文案来源，切歌 / 播放态变化都在这里一次同步。
    unawaited(
      WindowChrome.setTitle(
        track == null ? brand : '${_trackTooltip(track)} · $brand',
      ),
    );
  }

  playback.addListener(syncTray);
  libraryProvider.addListener(syncTray);
  AppBrandingService.titleNotifier.addListener(syncTray);
  LanguageService.localeNotifier.addListener(syncTray);
  syncTray();

  return (
    traySettings: traySettings,
    quitApp: quitApp,
    // 托盘在首帧后创建：此时图标资源可读，且不占启动关键路径。
    // 宿主探测预热：关闭策略首次触发时直接读缓存结果（并留下启动日志）。
    initTray: () {
      unawaited(AppTray.detectHost());
      AppTray.init(
        labels: _trayLabels(),
        onShowWindow: () => unawaited(WindowChrome.show()),
        onTogglePlay: () => unawaited(playback.togglePlayPause()),
        onPrevious: () => unawaited(playback.skipToPrevious()),
        onNext: () => unawaited(playback.skipToNext()),
        onToggleFavorite: () {
          final track = playback.snapshot.current;
          if (track != null) {
            unawaited(libraryProvider.toggleFavoriteTrack(track));
          }
        },
        onQuit: () => unawaited(quitApp()),
      );
    },
  );
}

/// 托盘菜单文案：按当前界面语言解析（未选择语言时跟随系统；与
/// `app_shell.dart` 的品牌名解析同一规则）。
TrayMenuLabels _trayLabels() {
  final effective = LanguageService.localeNotifier.value ??
      WidgetsBinding.instance.platformDispatcher.locale;
  final resolved = LanguageService.supportedLocales.any(
    (supported) => supported.languageCode == effective.languageCode,
  )
      ? effective
      : LanguageService.supportedLocales.first;
  final l10n = lookupAppLocalizations(resolved);
  return TrayMenuLabels(
    showWindow: l10n.trayShowWindow,
    play: l10n.play,
    pause: l10n.pause,
    previous: l10n.trayPrevious,
    next: l10n.trayNext,
    addFavorite: l10n.favoriteAdd,
    removeFavorite: l10n.favoriteRemove,
    quit: l10n.trayQuit,
  );
}

/// 托盘 tooltip 的曲目部分：`曲名 - 歌手`（无歌手时只留曲名）。
String _trackTooltip(Track track) {
  final artists = track.artists.map((artist) => artist.name).join(' / ');
  return artists.isEmpty ? track.title : '${track.title} - $artists';
}
