/// 桌面壳栈：托盘行为偏好（关闭时最小化到托盘）+ 统一退出路径 +
/// 关闭请求分流 + 桌面状态同步（托盘菜单 / Windows 任务栏缩略图按钮）。
///
/// 桌面实现（`app_tray.dart` / `taskbar_thumb_bar.dart` 出口）与窗口 chrome
/// 只在这里出现，其余组合根代码不感知桌面插件；首帧后的托盘与任务栏按钮
/// 创建由 [DesktopStack.initDesktopSurfaces] 承担（图标资源可读、不占启动
/// 关键路径）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../services/app_branding_service.dart';
import '../../services/app_presence.dart';
import '../../services/language_service.dart';
import '../../services/play_statistics_service.dart';
import '../../services/window/app_tray.dart';
import '../../services/window/taskbar_thumb_bar.dart';
import '../../services/window/tray_settings.dart';
import '../../services/window/window_chrome.dart';

final Logger _quitLog = Logger('molia.quit');

/// 桌面壳栈产物。
typedef DesktopStack = ({
  TraySettings traySettings,

  /// 统一退出路径（托盘「退出」/ 更新安装后的重启替换）。
  Future<void> Function() quitApp,

  /// 首帧后创建桌面外壳入口：托盘（含宿主探测预热）与 Windows 任务栏
  /// 缩略图按钮；其余平台都是空操作。
  void Function() initDesktopSurfaces,
});

/// 装配托盘偏好、退出路径与关闭策略（无托盘的平台全部是安全的空操作）。
Future<DesktopStack> buildDesktopStack({
  required PlaybackProvider playback,
  required LibraryProvider libraryProvider,
  required PlayStatisticsService playStatisticsService,

  /// 退出前的音频收尾（暂停 + 释放播放器）；无真实播放后端 / 测试时为空。
  Future<void> Function()? shutdownAudio,
}) async {
  // 托盘与关闭行为（设备本地偏好，不登记设置注册表）：关闭窗口时默认
  // 最小化到托盘（播放不中断）；偏好可在设置 › 通用 › 桌面 切换为直接退出。
  final traySettings = TraySettings();
  await traySettings.init();

  // Windows 任务栏缩略图工具栏：与托盘共用同一批动作与同一份文案，
  // 非 Windows 平台上所有方法都是空操作。
  final taskbar = TaskbarThumbBar();

  // 菜单动作（托盘菜单与任务栏按钮共用）：全部落到既有 provider。
  void togglePlay() => unawaited(playback.togglePlayPause());
  void skipToPrevious() => unawaited(playback.skipToPrevious());
  void skipToNext() => unawaited(playback.skipToNext());
  void toggleFavorite() {
    final track = playback.snapshot.current;
    if (track != null) {
      // 托盘 / 任务栏没有提示位：失败由 provider 记日志，成功靠图标与菜单文案。
      unawaited(libraryProvider.toggleFavoriteTrack(track));
    }
  }

  // 统一退出路径（托盘「退出」/ 更新安装后的重启替换）：先 await 播放会话
  // 提交（与壳层 paused 同一个挂起入口，最多等 2s），再收尾音频设备，然后
  // 触发统计落盘，最后销毁窗口。会话提交不 await 就销毁窗口，进程会在写请求
  // 落盘前退出——恢复态丢掉最后一段进度；平台通道挂起则超时继续退出（见
  // commitBeforeQuit）。
  Future<void> quitApp() async {
    await commitBeforeQuit(
      commitSession: playback.suspendPlaybackSession,
      shutdownAudio: shutdownAudio,
      flushStatistics: playStatisticsService.flush,
      quitWindow: WindowChrome.quit,
    );
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
    final labels = _trayLabels();
    final isFavorite = track != null &&
        libraryProvider.isFavorite(track.id.sourceKey, track.id.id);
    AppTray.setLabels(labels);
    AppTray.setPlaybackState(
      hasTrack: track != null,
      isPlaying: snapshot.isPlaying,
    );
    AppTray.setFavorite(isFavorite);
    AppTray.setTooltip(
      track == null ? brand : '$brand · ${_trackTooltip(track)}',
    );
    // Windows 任务栏缩略图按钮：同一份状态与文案（原生只在值变化时重画）。
    taskbar.setLabels(labels);
    taskbar.setPlaybackState(
      hasTrack: track != null,
      isPlaying: snapshot.isPlaying,
    );
    taskbar.setFavorite(isFavorite);
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
  // 窗口隐藏 / 最小化到托盘也是「离开」动作：提交一次会话进度（与退出共用
  // suspendPlaybackSession），托盘期进程被结束时可恢复最后位置。
  var lastPresence = AppPresence.instance.value;
  AppPresence.instance.addListener(() {
    final presence = AppPresence.instance.value;
    final leftVisible = lastPresence == AppPresenceState.visible &&
        !AppPresence.instance.isVisible;
    lastPresence = presence;
    if (leftVisible) unawaited(playback.suspendPlaybackSession());
  });
  syncTray();

  return (
    traySettings: traySettings,
    quitApp: quitApp,
    // 托盘在首帧后创建：此时图标资源可读，且不占启动关键路径。
    // 宿主探测预热：关闭策略首次触发时直接读缓存结果（并留下启动日志）。
    initDesktopSurfaces: () {
      unawaited(AppTray.detectHost());
      AppTray.init(
        labels: _trayLabels(),
        onShowWindow: () => unawaited(WindowChrome.show()),
        onTogglePlay: togglePlay,
        onPrevious: skipToPrevious,
        onNext: skipToNext,
        onToggleFavorite: toggleFavorite,
        onQuit: () => unawaited(quitApp()),
      );
      // Windows 任务栏缩略图按钮（悬浮任务栏按钮时的预览浮层）：点击与
      // 托盘菜单共用上面这批动作，非 Windows 上是空操作。
      unawaited(
        taskbar.init(
          labels: _trayLabels(),
          onTogglePlay: togglePlay,
          onPrevious: skipToPrevious,
          onNext: skipToNext,
          onToggleFavorite: toggleFavorite,
        ),
      );
    },
  );
}

/// 退出前提交的唯一顺序：先 await 会话提交，再收尾音频设备，然后触发统计
/// 落盘，最后退出窗口。
///
/// 音频放在会话落盘之后，是因为进度快照仍要读当前播放状态；反过来先释放
/// 播放器会让最后一段进度丢失。音频收尾停止的是设备输出（暂停 + 释放），
/// 不清空会话——清会话是壳层暂停 / 停止的语义，不是退出语义。
///
/// 拆成注入面是为了让「会话提交没完成不销毁窗口」可以被测试用 fake 钉住；
/// 生产调用点只有 [buildDesktopStack] 的 `quitApp`。会话提交、音频收尾与
/// 统计落盘都有界等待（[sessionTimeout] 默认 2s、[audioTimeout] /
/// [statisticsTimeout] 默认 500ms）：平台通道、音频设备或数据库挂起时不能把
/// 退出流程无限拖住。超时 / 失败都继续退出：用户已经点了退出，卡在保存或
/// 音频设备上比丢一次进度更糟。
@visibleForTesting
Future<void> commitBeforeQuit({
  required Future<void> Function() commitSession,
  required FutureOr<void> Function() flushStatistics,
  required Future<void> Function() quitWindow,
  Future<void> Function()? shutdownAudio,
  Duration sessionTimeout = const Duration(seconds: 2),
  Duration audioTimeout = const Duration(milliseconds: 500),
  Duration statisticsTimeout = const Duration(milliseconds: 500),
}) async {
  final sessionWatch = Stopwatch()..start();
  try {
    await commitSession().timeout(sessionTimeout);
  } on TimeoutException {
    debugPrint(
      '[Molia] 退出前落盘播放会话超时（${sessionTimeout.inMilliseconds}ms，继续退出）',
    );
  } catch (e) {
    debugPrint('[Molia] 退出前落盘播放会话失败（继续退出）: $e');
  }
  sessionWatch.stop();

  final audioWatch = Stopwatch()..start();
  final audioShutdown = shutdownAudio;
  if (audioShutdown != null) {
    try {
      await audioShutdown().timeout(audioTimeout);
    } on TimeoutException {
      debugPrint(
        '[Molia] 退出前音频收尾超时（${audioTimeout.inMilliseconds}ms，继续退出）',
      );
    } catch (e) {
      debugPrint('[Molia] 退出前音频收尾失败（继续退出）: $e');
    }
  }
  audioWatch.stop();

  final statsWatch = Stopwatch()..start();
  try {
    // 统计现在只在动作时写库；退出是最后一个动作，必须等写入完成，
    // 否则进程可能在数据库落盘前退出，丢掉最后一段收听时长。
    await Future<void>.sync(flushStatistics).timeout(statisticsTimeout);
  } on TimeoutException {
    debugPrint(
      '[Molia] 退出前落盘统计超时'
      '（${statisticsTimeout.inMilliseconds}ms，继续退出）',
    );
  } catch (e) {
    debugPrint('[Molia] 退出前落盘统计失败（继续退出）: $e');
  }
  statsWatch.stop();

  _quitLog.info(
    '退出收尾：会话 ${sessionWatch.elapsedMilliseconds}ms，'
    '音频 ${audioWatch.elapsedMilliseconds}ms，'
    '统计 ${statsWatch.elapsedMilliseconds}ms',
  );
  await quitWindow();
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
