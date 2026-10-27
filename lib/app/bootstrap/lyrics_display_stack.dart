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
import '../../playback/playback_power_policy.dart';
import '../../data/settings/settings_keys.dart';
import '../../services/artwork_palette_seed_store.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/covers/custom_cover_store.dart';
import '../../services/lyrics_display/audio_route_monitor.dart';
import '../../services/lyrics_display/desktop_lyrics_output.dart';
import '../../services/lyrics_display/lyrics_channel.dart';
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
///
/// [powerPolicy] 与播放栈共享同一实例：桌面歌词开关变化要即时反映到
/// 位置采样（后台开着悬浮窗仍按 5Hz，关掉后降为 1s）。
Future<LyricsDisplayStack> buildLyricsDisplayStack({
  required CatalogStack catalog,
  required PlaybackProvider playback,
  required LyricsProvider lyricsProvider,
  required LocalAudioHandler? audioHandler,
  required PlaybackPowerPolicy powerPolicy,
  CustomCoverStore? customCovers,
}) async {
  final covers = (customCovers ?? CustomCoverStore.instance).resolution;
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
  // seed 持久化按封面内容身份（URL + 文件大小 + 修改时间），设备本地派生
  // 缓存，不参与同步；启动命中时不必再解码封面。
  final artworkPaletteService = ArtworkPaletteService(
    seedStore: ArtworkPaletteSeedStore(),
  );
  final artworkThemeSync = ArtworkThemeSync(
    load: artworkPaletteService.load,
    onPalette: (palette) => themeProvider.applyArtworkSeed(palette.seed),
    onCleared: themeProvider.clearArtworkSeed,
    // 移动端退后台且没有桌面歌词：取色没有消费面，先记 URL，回前台再取。
    mobilePowerPolicy: powerPolicy,
  );
  // 歌词显示（桌面歌词 / 通知·锁屏 / 蓝牙）：配置 + 输出 + 调度。
  // 输出端能力由平台决定；媒体输出依赖系统媒体会话（audioHandler）。
  final lyricsDisplaySettings = LyricsDisplaySettings(
    settings: catalog.settings.scope([kLyricsDisplaySettings]),
  );
  await lyricsDisplaySettings.init();
  // 桌面歌词是否可能展示 = 平台支持 ∩ 用户开启（未授予悬浮窗权限也算：
  // 最多多付一次 5Hz 采样，换授权后歌词 / 颜色不必等下一次切换）。
  // 监听设置在 init 之后挂：设置页开关、跨设备同步应用远端配置都会通知。
  void syncDesktopLyricsActive() {
    powerPolicy.setDesktopLyricsActive(
      LyricsChannel.isSupportedPlatform && lyricsDisplaySettings.desktopEnabled,
    );
    powerPolicy.setLyricsOutputActive(
      lyricsDisplaySettings.desktopEnabled ||
          lyricsDisplaySettings.notificationEnabled ||
          lyricsDisplaySettings.bluetoothEnabled,
    );
  }

  syncDesktopLyricsActive();
  lyricsDisplaySettings.addListener(syncDesktopLyricsActive);
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
  lyricsDisplay.syncLyrics(lyricsProvider.state);

  // 曲目变化 → 歌词会话唯一加载入口：页面 / 输出都不再各自触发取词，
  // 是否启用桌面歌词也不影响（会话只负责把当前曲目的状态准备好）。
  wireLyricsSession(
    playback: playback,
    lyricsProvider: lyricsProvider,
    powerPolicy: powerPolicy,
  );

  // 下一首歌词预载接线：紧跟歌词显示接线之后、取色接线之前
  // （与原组合根同一顺序：显示 → 预载 → 取色 → 启动预解析）。
  wireNextTrackLyricsPreload(
    playback: playback,
    lyricsProvider: lyricsProvider,
    powerPolicy: powerPolicy,
  );

  // 封面取色接线：任何页面/后台切歌都经同一链路（稳态延迟 + 过期丢弃）。
  // 无封面 → 清空 seed，主题回退基础配色；取色失败保持现色。
  void syncArtworkPalette() {
    final artwork = covers.realOf(playback.snapshot.current).url;
    artworkThemeSync.onArtworkChanged(artwork);
  }

  playback.addListener(syncArtworkPalette);
  // 自定义封面替换 / 恢复：当前曲目的主题色立即重算（默认封面不参与）。
  covers.addChangeListener(syncArtworkPalette);
  syncArtworkPalette();

  // 启动预解析（runApp 前，决定首帧配色）：先按平台亮度定亮度，再解析恢复
  // 会话的当前封面——进入应用即最终配色，不再先出基础配色再渐变；未命中不
  // 等待网络，回退上面的稳态链路（settleDelay 后取色再过渡）。
  // 主题偏好 / 播放偏好（恢复会话解析）/ 导航偏好（启动首页）互不依赖：
  // 并行等待——启动首页必须在首帧前就绪，否则会先亮默认页再跳。
  final prefsWatch = Stopwatch()..start();
  await (
    themeProvider.preferencesReady,
    playback.preferencesReady,
    navProvider.preferencesReady,
  ).wait;
  markStartupStep('sub.theme/nav/playback.prefs', prefsWatch);
  themeProvider.applyPlatformBrightness(
    WidgetsBinding.instance.platformDispatcher.platformBrightness,
  );
  // 先查封面：命中持久 seed 时只读 prefs、不解码图片，是首帧最便宜的一档。
  // seed 由图片内容决定，封面命中后首帧已经是封面色——即使基础配色是壁纸 /
  // 自定义档，也不必再解析壁纸，把桌面壁纸取色整段移出启动路径。
  final coverWatch = Stopwatch()..start();
  ArtworkPalette? startupPalette;
  if (themeProvider.followArtworkEnabled) {
    startupPalette = await artworkPaletteService.loadCachedTrack(
      playback.snapshot.current,
      covers: covers,
    );
    if (startupPalette != null) {
      themeProvider.applyArtworkSeed(startupPalette.seed);
    }
  }
  markStartupStep('sub.startupCover', coverWatch);

  // 封面未命中才回退壁纸（顺序：封面 → 壁纸）。桌面系统壁纸（B-lite）：
  // 只探测桌面平台（移动端壁纸档 = 莫奈，探测无意义、warning 是噪音）。
  // - 壁纸档：await 解析后注入，首帧即壁纸色；
  // - 自定义档：unawaited 后台解析，不增加启动延迟（服务内部吞异常，不抛）。
  // 拿不到壁纸（非 GNOME / 文件缺失 / 解码失败）保持 null，由 DynamicColorBuilder
  // 的强调色兜底。
  //
  // 已知取舍：封面命中但用户之后切到壁纸档时，本次启动没有壁纸 seed（壁纸
  // future 根本没创建）；重启或下次封面未命中时再按本段逻辑解析。
  // `followArtworkEnabled == false` 时 startupPalette 恒为 null，保持原壁纸逻辑。
  if (startupPalette == null && isDesktopPlatform()) {
    final wallpaperWatch = Stopwatch()..start();
    final wallpaperSeeds = _resolveWallpaperSeeds(
      SystemWallpaperSource(),
      artworkPaletteService,
    );
    if (themeProvider.baseColorSource == ColorBaseSource.wallpaper) {
      final seeds = await wallpaperSeeds;
      themeProvider.updateSystemWallpaperSeed(seeds.$1, seeds.$2);
      markStartupStep('sub.startupWallpaper', wallpaperWatch);
    } else {
      unawaited(
        wallpaperSeeds.then((seeds) {
          themeProvider.updateSystemWallpaperSeed(seeds.$1, seeds.$2);
          markStartupStep('sub.startupWallpaper', wallpaperWatch);
        }),
      );
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
