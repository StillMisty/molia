/// 功能栈：桌面壳 / AI 推歌 / 歌词会话 / 歌词显示与主题。
///
/// 三组互不依赖：桌面壳的异步初始化与 AI、歌词会话同步装配并行推进
/// （不 await 完桌面壳再开始下一步）；歌词显示与桌面壳也并行，最后一起等。
library;

import 'dart:async';

import 'app_dependencies.dart';
import 'ai_stack.dart';
import 'desktop_stack.dart';
import 'lyrics_display_stack.dart';
import 'lyrics_stack.dart';
import 'startup_trace.dart';

/// 装配桌面 / AI / 歌词会话 / 歌词显示（含 runApp 前的主题预解析）。
Future<FeatureStacks> buildFeatureStacks({
  required PlatformBootstrap platform,
  required CoreStacks core,
}) async {
  final catalog = core.catalog;
  final local = core.local;
  final library = core.library;
  final playback = core.playback;

  // ⑤ 桌面壳（异步：prefs / 托盘落地）与 ⑥ AI 推歌 / ⑦ 歌词会话：
  // 三组互不依赖；桌面壳的异步初始化与后面两组同步装配并行推进。
  final desktopWatch = Stopwatch()..start();
  final desktopFuture = buildDesktopStack(
    playback: playback.playbackProvider,
    libraryProvider: core.libraryProvider,
    playStatisticsService: library.playStatisticsService,
    // 退出前先让音频设备停下来，再销毁窗口（Windows 上避免爆音）。
    shutdownAudio: playback.localPlaybackService?.shutdownAudioForQuit,
    // 桌面正常退出不一定触发生命周期 `onDetach`（托盘退出 / 更新重启 /
    // 系统退出请求）；在销毁窗口前补写「已正常关闭」，避免下次启动误报
    // 异常退出。`onDetach` 仍保留兜底。
    beforeQuit: () => platform.diagnostics.service.session.onDetached(),
  ).whenComplete(() => markStartupStep('sub.desktop.build', desktopWatch));
  final ai = buildAiStack(
    catalog: catalog,
    library: library,
    playback: playback.playbackProvider,
    libraryProvider: core.libraryProvider,
  );
  final lyrics = buildLyricsStack(local: local);
  wireBiliLoginLyricsRefresh(
    account: catalog.biliAccount,
    sourceManager: catalog.sourceManager,
    lyricsProvider: lyrics.lyricsProvider,
  );
  // ⑧ 歌词显示与主题（含 runApp 前的启动预解析：首帧即封面色）。
  // 与桌面壳并行：两者互不依赖，串行会白等 tray settings 的 prefs 读取。
  final displayWatch = Stopwatch()..start();
  final displayFuture = buildLyricsDisplayStack(
    catalog: catalog,
    playback: playback.playbackProvider,
    lyricsProvider: lyrics.lyricsProvider,
    audioHandler: playback.audioHandler,
    powerPolicy: platform.powerPolicy,
    customCovers: local.customCovers,
  );
  final desktop = await desktopFuture;
  final display = await displayFuture;
  markStartupStep('sub.lyricsDisplay.build', displayWatch);
  markStartupStep('主题/歌词显示', platform.startup);

  return (desktop: desktop, ai: ai, lyrics: lyrics, display: display);
}
