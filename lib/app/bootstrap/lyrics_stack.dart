/// 歌词会话栈：LyricsProvider（取词 → 缓存 → 解析 → 预取的唯一实现）
/// 与「下一首歌词预载」接线。
///
/// 歌词服务在本地数据栈构建（歌词服务与下载服务互为依赖，
/// 见 `local_data_stack.dart` 的说明）；这里只装配会话层。
library;

import 'dart:async';

import '../../providers/lyrics_provider.dart';
import '../../providers/playback_provider.dart';
import 'local_data_stack.dart';

/// 歌词会话栈产物。
typedef LyricsStack = ({
  LyricsProvider lyricsProvider,
});

/// 装配歌词会话（与播放页共享同一实例：去重 / 预取行为不变）。
LyricsStack buildLyricsStack({
  required LocalDataStack local,
}) {
  return (lyricsProvider: LyricsProvider(service: local.lyricsService),);
}

/// 下一首歌词预载：统一挂在这里，不依赖歌词组件是否挂载/展开；
/// 去重与缓存写入由 [LyricsProvider.preload] 负责。
///
/// 调用点在歌词显示装配之后（与原组合根同一时机）。
void wireNextTrackLyricsPreload({
  required PlaybackProvider playback,
  required LyricsProvider lyricsProvider,
}) {
  String? preloadedNextLyricsId;
  void syncNextTrackLyricsPreload() {
    final snapshot = playback.snapshot;
    final next = snapshot.next ??
        (snapshot.upNext.isNotEmpty ? snapshot.upNext.first : null);
    final id = next?.id.uri;
    if (next == null ||
        id == null ||
        id.isEmpty ||
        id == preloadedNextLyricsId) {
      return;
    }
    preloadedNextLyricsId = id;
    unawaited(lyricsProvider.preload(next));
  }

  playback.addListener(syncNextTrackLyricsPreload);
  syncNextTrackLyricsPreload();
}
