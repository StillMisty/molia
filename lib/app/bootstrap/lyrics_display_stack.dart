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
import '../../services/artwork_palette_service.dart';
import '../../services/lyrics_display/audio_route_monitor.dart';
import '../../services/lyrics_display/desktop_lyrics_output.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/lyrics_display/media_lyric_output.dart';
import 'catalog_stack.dart';
import 'lyrics_stack.dart';

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
  // 都从 ThemeProvider 取（取色链路在下方接线）。
  final themeProvider = ThemeProvider(settings: catalog.settings);
  // 导航偏好提前创建：跨设备同步应用远端设置后需要定向重载。
  final navProvider = NavProvider(settings: catalog.settings);
  // 封面取色服务：全局主题、桌面歌词、海报共用的唯一取色入口。
  final artworkPaletteService = ArtworkPaletteService();
  final artworkThemeSync = ArtworkThemeSync(
    load: artworkPaletteService.load,
    onPalette: (palette) => themeProvider.applyArtworkSeed(palette.seed),
    onCleared: themeProvider.clearArtworkSeed,
  );
  // 歌词显示（桌面歌词 / 通知·锁屏 / 蓝牙）：配置 + 输出 + 调度。
  // 输出端能力由平台决定；媒体输出依赖系统媒体会话（audioHandler）。
  final lyricsDisplaySettings =
      LyricsDisplaySettings(settings: catalog.settings);
  await lyricsDisplaySettings.init();
  final audioRouteMonitor = AudioRouteMonitor();
  unawaited(audioRouteMonitor.init());
  final lyricsDisplay = LyricsDisplayProvider(
    settings: lyricsDisplaySettings,
    outputs: [
      DesktopLyricsOutput(
        colorScheme: () => themeProvider.colorScheme,
        artworkColorScheme: () => themeProvider.artworkColorScheme,
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
  playback.addListener(() => lyricsDisplay.syncPlayback(playback.snapshot));
  playback.position.addListener(
    () => lyricsDisplay.updatePosition(playback.currentPosition),
  );
  lyricsProvider.addListener(
    () => lyricsDisplay.syncLyrics(lyricsProvider.state),
  );
  lyricsDisplay.syncPlayback(playback.snapshot);

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

  // 启动预解析（runApp 前，决定首帧配色）：先按平台亮度定亮度，再在恢复
  // 会话的当前封面已在本地缓存时取色——进入应用即封面色，不再先出基础
  // 配色（莫奈）再渐变；未命中不等待网络，回退上面的稳态链路（settleDelay
  // 后取色再过渡）。
  // 主题偏好与播放偏好（恢复会话解析）互不依赖：并行等待。
  await (themeProvider.preferencesReady, playback.preferencesReady).wait;
  themeProvider.applyPlatformBrightness(
    WidgetsBinding.instance.platformDispatcher.platformBrightness,
  );
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
