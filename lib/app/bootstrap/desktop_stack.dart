/// 桌面壳栈：托盘行为偏好（关闭时最小化到托盘）+ 统一退出路径 +
/// 关闭请求分流 + 桌面状态同步（托盘菜单 / Windows 任务栏缩略图按钮）。
///
/// 桌面实现（`app_tray.dart` / `taskbar_thumb_bar.dart` 出口）与窗口 chrome
/// 只在这里出现，其余组合根代码不感知桌面插件；首帧后的托盘与任务栏按钮
/// 创建由 [DesktopStack.initDesktopSurfaces] 承担（图标资源可读、不占启动
/// 关键路径）。
library;

import 'dart:async';
import 'dart:io' show exit;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show SystemNavigator;
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

/// 统一退出流程的阶段（系统级退出请求据此决定取消还是放行）。
enum _DesktopQuitPhase {
  /// 尚未开始退出，或上一次退出失败已复位。
  idle,

  /// 正在提交会话 / 收尾音频 / 落盘统计；系统终止请求必须继续取消。
  saving,

  /// 落盘完成，正在销毁窗口；此时原生 close 触发的终止请求应放行。
  exiting,

  /// 销毁动作已返回，等待进程结束；重复终止请求直接放行。
  done,
}

/// 退出提交动作：先落盘，再在销毁窗口前调用 [onBeforeQuitWindow]。
typedef QuitCommit = Future<void> Function(void Function() onBeforeQuitWindow);

/// 统一退出门闩：托盘退出 / 更新重启 / 系统退出请求共用。
///
/// 关键点是把「保存中」和「销毁中」分开。macOS Cmd+Q / Linux 应用 quit 在
/// 保存中必须返回 `cancel`，否则进程会在会话 / 统计落盘前退出；但销毁窗口
/// 本身又会触发一次原生终止请求，这时必须返回 `exit`，否则会把我们自己的
/// 退出流程取消掉。并发调用复用同一个 future，避免重复落盘。
class AppQuitController {
  AppQuitController(this._commit);

  final QuitCommit _commit;

  _DesktopQuitPhase _phase = _DesktopQuitPhase.idle;
  Future<void>? _future;

  /// 是否已有退出流程在跑（关闭窗口不应再走「隐藏到托盘」）。
  bool get isActive => _phase != _DesktopQuitPhase.idle;

  Future<void> quit() {
    final inFlight = _future;
    if (inFlight != null) return inFlight;
    final future = _run();
    _future = future;
    return future;
  }

  Future<void> _run() async {
    _phase = _DesktopQuitPhase.saving;
    try {
      await _commit(() {
        _phase = _DesktopQuitPhase.exiting;
      });
      _phase = _DesktopQuitPhase.done;
    } catch (error, stackTrace) {
      // 窗口销毁失败时进程还在：复位门闩，下一次退出请求可以重试，
      // 同时把错误留在日志里，不能让托盘「退出」静默失效。
      _phase = _DesktopQuitPhase.idle;
      _future = null;
      _quitLog.warning('退出流程失败，应用继续运行', error, stackTrace);
    }
  }

  AppExitResponse handleExitRequest() {
    switch (_phase) {
      case _DesktopQuitPhase.idle:
        // 先把门闩置为 saving 再返回 cancel：系统会取消这次终止，等
        // quit 完成落盘后由销毁窗口动作触发的新请求放行。
        unawaited(quit());
        return AppExitResponse.cancel;
      case _DesktopQuitPhase.saving:
        // 落盘还没结束：继续取消，不能提前退出。
        return AppExitResponse.cancel;
      case _DesktopQuitPhase.exiting:
      case _DesktopQuitPhase.done:
        // 已经进入销毁窗口 / 已完成：放行原生终止，避免把 close 再拦一次。
        return AppExitResponse.exit;
    }
  }
}

/// 桌面壳栈产物。
typedef DesktopStack = ({
  TraySettings traySettings,

  /// 统一退出路径（托盘「退出」/ 更新安装后的重启替换）。
  Future<void> Function() quitApp,

  /// 系统级退出请求（macOS Cmd+Q / Linux 应用 quit）的唯一入口。
  ///
  /// 空闲时启动 [quitApp] 并返回 `cancel`，让落盘先完成；进入销毁窗口阶段
  /// 后返回 `exit`，让原生终止请求继续。保存期间重复请求继续返回 `cancel`，
  /// 不会提前杀掉进程。
  AppExitResponse Function() handleExitRequest,

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

  // 统一退出路径（托盘「退出」/ 更新安装后的重启替换 / 系统退出请求）：
  // 先 await 播放会话提交（与壳层 paused 同一个挂起入口，最多等 2s），再
  // 收尾音频设备，然后触发统计落盘，最后销毁窗口。会话提交不 await 就销毁
  // 窗口，进程会在写请求落盘前退出——恢复态丢掉最后一段进度；平台通道挂起
  // 则超时继续退出（见 commitBeforeQuit）。
  //
  // 退出分成「保存中 / 销毁中 / 已完成」三段：系统级退出请求（macOS Cmd+Q、
  // Linux 应用 quit）在保存中返回 cancel，等到真正销毁窗口前再切到「销毁中」。
  // 这样 `WindowChrome.quit()` 关闭窗口时触发的第二次系统退出请求会返回
  // exit，而不是把已经开始的退出又取消掉。并发调用复用同一个 future，避免
  // 托盘退出 / 更新重启 / Cmd+Q 同时落盘两遍。
  final quitController = AppQuitController(
    (onBeforeQuitWindow) => commitBeforeQuit(
      commitSession: playback.suspendPlaybackSession,
      shutdownAudio: shutdownAudio,
      flushStatistics: playStatisticsService.flush,
      onBeforeQuitWindow: onBeforeQuitWindow,
      quitWindow: _quitPlatformApp,
    ),
  );
  final quitApp = quitController.quit;

  // 定时关闭勾选「退出应用」时也走同一条退出路径：会话提交、音频收尾、
  // 统计落盘完成后才真正退出。provider 建好后回填（此时 quitApp 已可用）。
  playback.attachQuitApp(quitApp);

  // 关闭请求（顶栏关闭键 / 系统关闭按钮 / 任务栏「关闭窗口」）→ 按设置
  // 分流：隐藏到托盘或退出。
  //
  // 隐藏的三个前提缺一不可：用户勾选了关闭到托盘、托盘图标确实创建成功、
  // 系统有托盘宿主。无托盘宿主（GNOME 未装 AppIndicator 扩展、无面板的裸
  // WM）或图标创建失败时藏起来就没有找回入口，退回直接退出（设置页对
  // Linux 有同一提示）。
  //
  // 关闭流程是异步的（等休眠帧），期间用户可能从托盘恢复，也可能连点关闭
  // 触发第二次请求：用 [handlingClose] 串行化，并在隐藏前重新确认仍处于
  // 托盘态，避免把刚恢复的窗口又藏回去。
  var handlingClose = false;
  WindowChrome.setCloseHandler(() async {
    // 退出流程已经接管窗口：销毁阶段的 close 请求不能再走「隐藏到托盘」。
    if (handlingClose || quitController.isActive) return;
    handlingClose = true;
    try {
      if (traySettings.closeToTray &&
          AppTray.isActive &&
          await AppTray.detectHost()) {
        // 先置休眠态并等这一帧把界面卸下来（窗口还可见、帧还开着），再隐藏：
        // 隐藏后平台会停帧，休眠树若没建成就要等恢复窗口才建，托盘期省不下来。
        // endOfFrame 自带超时兜底，异常路径不把「点关闭」卡死。
        AppPresence.instance.markTrayHidden();
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        // 等帧期间用户可能已经点了托盘图标：恢复态下不能再隐藏。
        if (!AppPresence.instance.isTrayHidden) return;
        await WindowChrome.hideIfTrayHidden();
      } else {
        await quitApp();
      }
    } catch (error, stackTrace) {
      // 隐藏失败时不能把界面留在「已休眠、窗口仍在」的半状态：恢复存在态
      // 后走统一退出，至少不会让用户面对一棵没有交互的窗口。
      _quitLog.warning('关闭到托盘失败，改为退出', error, stackTrace);
      AppPresence.instance.markVisible();
      await quitApp();
    } finally {
      handlingClose = false;
    }
  });

  // 菜单动作全部落到既有 provider；文案 / tooltip / 菜单可用性跟随播放、
  // 收藏、语言与品牌名变化。
  void syncTray() {
    final snapshot = playback.snapshot;
    final track = snapshot.current;
    final brand = AppBrandingService.titleNotifier.value;
    final labels = _trayLabels();
    final isFavorite =
        track != null &&
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
    final leftVisible =
        lastPresence == AppPresenceState.visible &&
        !AppPresence.instance.isVisible;
    lastPresence = presence;
    if (leftVisible) unawaited(playback.suspendPlaybackSession());
  });
  syncTray();

  return (
    traySettings: traySettings,
    quitApp: quitApp,
    handleExitRequest: quitController.handleExitRequest,
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

/// 平台最终退出动作（落盘由 [commitBeforeQuit] 在此之前完成）。
///
/// - 桌面：销毁窗口（Linux / Windows / macOS）；
/// - Android：结束当前 Activity；
/// - iOS：程序化退出（`SystemNavigator.pop` 对根 FlutterViewController 是
///   no-op，必须 `exit(0)` 才能让「退出应用」真正生效）；
/// - Web / 其它平台：只完成落盘与暂停，不做强制退出。
Future<void> _quitPlatformApp() async {
  if (kIsWeb) return;
  if (WindowChrome.isSupported) {
    await WindowChrome.quit();
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    await SystemNavigator.pop();
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    exit(0);
  }
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

  /// 真正销毁窗口前的同步钩子（退出状态机切到「销毁中」）。
  void Function()? onBeforeQuitWindow,
  Duration sessionTimeout = const Duration(seconds: 2),
  Duration audioTimeout = const Duration(milliseconds: 500),
  Duration statisticsTimeout = const Duration(milliseconds: 500),
}) async {
  final sessionWatch = Stopwatch()..start();
  try {
    await commitSession().timeout(sessionTimeout);
  } on TimeoutException {
    debugPrint('[Molia] 退出前落盘播放会话超时（${sessionTimeout.inMilliseconds}ms，继续退出）');
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
      debugPrint('[Molia] 退出前音频收尾超时（${audioTimeout.inMilliseconds}ms，继续退出）');
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
  onBeforeQuitWindow?.call();
  await quitWindow();
}

/// 托盘菜单文案：按当前界面语言解析（未选择语言时跟随系统；与
/// `app_shell.dart` 的品牌名解析同一规则）。
TrayMenuLabels _trayLabels() {
  final effective =
      LanguageService.localeNotifier.value ??
      WidgetsBinding.instance.platformDispatcher.locale;
  final resolved =
      LanguageService.supportedLocales.any(
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
