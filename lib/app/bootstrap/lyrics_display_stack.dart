/// 歌词显示与主题栈：主题 / 导航偏好 / 封面取色服务 → 歌词显示调度
/// （桌面歌词 / 通知·锁屏 / 蓝牙）→ 取色接线 → 启动预解析（首帧配色）。
///
/// 顺序与原组合根一致：主题实例先建（桌面歌词「跟随主题」「跟随封面」的颜色
/// 都从 ThemeProvider 取），显示调度随后接线，最后 `await preferencesReady`
/// 做 runApp 前的启动预解析。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../providers/lyrics_display_provider.dart';
import '../../providers/lyrics_provider.dart';
import '../../providers/nav_provider.dart';
import '../../providers/playback_provider.dart';
import '../../providers/theme_provider.dart';
import '../../playback/local_audio_handler.dart';
import '../../data/settings/settings_keys.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/lyrics_display/audio_route_monitor.dart';
import '../../services/lyrics_display/desktop_lyrics_output.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/lyrics_display/media_lyric_output.dart';
import '../../services/system_wallpaper_service.dart';
import '../../theme/scheme_builder.dart';
import '../../utils/responsive.dart';
import 'catalog_stack.dart';
import 'lyrics_stack.dart';
import 'startup_trace.dart';

/// 歌词显示与主题栈产物（构造顺序见 [buildLyricsDisplayStack]）。
typedef LyricsDisplayStack = ({
  ThemeProvider themeProvider,
  NavProvider navProvider,
  ArtworkPaletteService artworkPaletteService,
  LyricsDisplaySettings lyricsDisplaySettings,
  LyricsDisplayProvider lyricsDisplay,
});

/// 装配主题 / 导航 / 取色与歌词显示，并完成 runApp 前的启动预解析。
///
/// [audioHandler] 为系统媒体会话（媒体歌词输出与「初始化失败」提示的判据）。
Future<LyricsDisplayStack> buildLyricsDisplayStack({
  required CatalogStack catalog,
  required PlaybackProvider playback,
  required LyricsProvider lyricsProvider,
  required LocalAudioHandler? audioHandler,
}) async {
  // 主题实例提前创建：封面覆盖 / 桌面歌词「跟随主题」「跟随封面」的颜色
  // 都从 ThemeProvider 取（取色链路在下方接线）。作用域 = 主题自己的 5 个键。
  final themeSettings = catalog.settings.scope([
    kThemeMode,
    kColorBase,
    kFollowArtworkEnabled,
    kPureBlackEnabled,
    kSeedColor,
  ]);
  final themeProvider = ThemeProvider(settings: themeSettings);
  // 导航偏好提前创建：跨设备同步应用远端设置后需要定向重载。
  final navSettings = catalog.settings.scope([
    kShellNavOrder,
    kShellNavHidden,
    kShellHomeDestination,
  ]);
  final navProvider = NavProvider(settings: navSettings);
  // 封面取色服务：全局主题、桌面歌词、海报共用的唯一取色入口。
  final artworkPaletteService = ArtworkPaletteService();
  final artworkThemeSync = ArtworkThemeSync(
    load: artworkPaletteService.load,
    onPalette: (palette) => themeProvider.applyArtworkSeed(palette.seed),
    onCleared: themeProvider.clearArtworkSeed,
  );
  // 歌词显示（桌面歌词 / 通知·锁屏 / 蓝牙）：配置 + 输出 + 调度。
  // 输出端能力由平台决定；媒体输出依赖系统媒体会话（audioHandler）。
  final lyricsDisplaySettings = LyricsDisplaySettings(
    settings: catalog.settings.scope([kLyricsDisplaySettings]),
  );
  await lyricsDisplaySettings.init();
  final audioRouteMonitor = AudioRouteMonitor();
  unawaited(audioRouteMonitor.init());
  final lyricsDisplay = LyricsDisplayProvider(
    settings: lyricsDisplaySettings,
    outputs: [
      DesktopLyricsOutput(
        colorScheme: () => themeProvider.colorScheme,
        artworkColorScheme: () => themeProvider.artworkColorScheme,
        // 悬浮窗文本跟随「应用字体」：字体变化同样经 themeProvider 通知
        // （LyricsDisplayProvider 的 themeListenable）重下发配置。
        appFontFamily: () => themeProvider.appFontFamily,
      ),
      MediaLyricOutput(
        supported: () => audioHandler != null,
        applyOverride: (override) =>
            audioHandler?.setLyricMetadataOverride(override),
        a2dpConnected: () => audioRouteMonitor.connected,
      ),
    ],
    // 平台支持媒体会话但初始化失败（initSystemMediaSession 返回 null）：
    // 歌词显示设置页据此给出可见提示，而不是静默隐藏输出分组。
    mediaSessionInitFailed:
        isSystemMediaSessionSupported && audioHandler == null,
    audioRoute: audioRouteMonitor,
    themeListenable: themeProvider,
    ensureLyrics: (track) => lyricsProvider.load(track),
    onPlaybackCommand: (command) {
      switch (command) {
        case LyricsPlaybackCommand.playPause:
          unawaited(playback.togglePlayPause());
        case LyricsPlaybackCommand.previous:
          unawaited(playback.skipToPrevious());
        case LyricsPlaybackCommand.next:
          unawaited(playback.skipToNext());
      }
    },
  );
  // 状态接线：播放快照 / 进度 / 歌词状态 → 调度；冷启动恢复态也走同一路径。
  // 快照变化时同时补一次当前位置：冷启动恢复 / 暂停中 seek / 切曲可能让
  // 位置值在订阅建立前就位（ValueListenable 不补发），只靠进度通道路由会
  // 停在旧行（桌面歌词表现为冷启动显示第 0 行）。
  playback.addListener(() {
    lyricsDisplay.syncPlayback(playback.snapshot);
    lyricsDisplay.updatePosition(playback.currentPosition);
  });
  playback.position.addListener(
    () => lyricsDisplay.updatePosition(playback.currentPosition),
  );
  lyricsProvider.addListener(
    () => lyricsDisplay.syncLyrics(lyricsProvider.state),
  );
  lyricsDisplay.syncPlayback(playback.snapshot);
  lyricsDisplay.updatePosition(playback.currentPosition);

  // 下一首歌词预载接线：紧跟歌词显示接线之后、取色接线之前
  // （与原组合根同一顺序：显示 → 预载 → 取色 → 启动预解析）。
  wireNextTrackLyricsPreload(
    playback: playback,
    lyricsProvider: lyricsProvider,
  );

  // 封面取色接线：任何页面/后台切歌都经同一链路（稳态延迟 + 过期丢弃）。
  // 无封面 → 清空 seed，主题回退基础配色；取色失败保持现色。
  void syncArtworkPalette() {
    final artwork = playback.snapshot.current?.artwork?.uri.toString();
    artworkThemeSync.onArtworkChanged(artwork);
  }

  playback.addListener(syncArtworkPalette);
  syncArtworkPalette();

  // 启动预解析（runApp 前，决定首帧配色）：先按平台亮度定亮度，再依次解析
  // 系统壁纸图与恢复会话的当前封面——进入应用即最终配色，不再先出基础配色
  // 再渐变；未命中不等待网络，回退上面的稳态链路（settleDelay 后取色再过渡）。
  // 主题偏好 / 播放偏好（恢复会话解析）/ 导航偏好（启动首页）互不依赖：
  // 并行等待——启动首页必须在首帧前就绪，否则会先亮默认页再跳。
  final prefsWatch = Stopwatch()..start();
  await (
    themeProvider.preferencesReady,
    playback.preferencesReady,
    navProvider.preferencesReady
  ).wait;
  markStartupStep('sub.theme/nav/playback.prefs', prefsWatch);
  themeProvider.applyPlatformBrightness(
    WidgetsBinding.instance.platformDispatcher.platformBrightness,
  );
  // 桌面系统壁纸（B-lite）：只探测桌面平台（移动端壁纸档 = 莫奈，探测无意义、
  // warning 是噪音）；且无论当前是否壁纸档都解析一次——启动时是自定义档的
  // 用户之后切回壁纸 / 同步推来 wallpaper 时 seed 已在位，不必重启，
  // 冷启动与会话内切档行为一致。
  // - 壁纸档：await 解析后注入，首帧即壁纸色（不回归）；
  // - 自定义档：unawaited 后台解析，不增加启动延迟（服务内部吞异常，不抛）；
  //   若晚于封面预解析完成才落地，[_schemeForBrightness] 封面优先，不会被盖回。
  // 拿不到壁纸（非 GNOME / 文件缺失 / 解码失败）保持 null，由 DynamicColorBuilder
  // 的强调色兜底。
  if (isDesktopPlatform()) {
    final wallpaperSource = SystemWallpaperSource();
    final wallpaperSeeds =
        _resolveWallpaperSeeds(wallpaperSource, artworkPaletteService);
    if (themeProvider.baseColorSource == ColorBaseSource.wallpaper) {
      final seeds = await wallpaperSeeds;
      themeProvider.updateSystemWallpaperSeed(seeds.$1, seeds.$2);
    } else {
      unawaited(wallpaperSeeds.then(
        (seeds) => themeProvider.updateSystemWallpaperSeed(seeds.$1, seeds.$2),
      ));
    }
  }
  if (themeProvider.followArtworkEnabled) {
    final startupArtwork = playback.snapshot.current?.artwork?.uri.toString();
    if (startupArtwork != null && startupArtwork.isNotEmpty) {
      final startupPalette =
          await artworkPaletteService.loadCached(startupArtwork);
      if (startupPalette != null) {
        themeProvider.applyArtworkSeed(startupPalette.seed);
      }
    }
  }

  return (
    themeProvider: themeProvider,
    navProvider: navProvider,
    artworkPaletteService: artworkPaletteService,
    lyricsDisplaySettings: lyricsDisplaySettings,
    lyricsDisplay: lyricsDisplay,
  );
}

/// 浅 / 深壁纸 seed（并发解析；浅深同文件时经 LRU / 并发合并只读一次盘）。
Future<(Color?, Color?)> _resolveWallpaperSeeds(
  SystemWallpaperSource source,
  ArtworkPaletteService paletteService,
) async {
  final seeds = await Future.wait([
    _wallpaperSeed(source, paletteService, Brightness.light),
    _wallpaperSeed(source, paletteService, Brightness.dark),
  ]);
  return (seeds[0], seeds[1]);
}

/// 亮度 → 壁纸文件路径 → 壁纸图 seed；无壁纸 / 读取 / 解码失败返回 null。
///
/// 浅 / 深常是同一文件：走 [ArtworkPaletteService.loadLocalFile] 的并发合并与
/// LRU，只读一次盘、只解码一次。
Future<Color?> _wallpaperSeed(
  SystemWallpaperSource source,
  ArtworkPaletteService paletteService,
  Brightness brightness,
) async {
  final path = await source.resolvePath(brightness);
  if (path == null || path.isEmpty) return null;
  return (await paletteService.loadLocalFile(path))?.seed;
}
