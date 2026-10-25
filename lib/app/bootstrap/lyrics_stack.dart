/// 歌词会话栈：LyricsProvider（取词 → 缓存 → 解析 → 预取的唯一实现）
/// 与「下一首歌词预载」接线。
///
/// 歌词服务在本地数据栈构建（歌词服务与下载服务互为依赖，
/// 见 `local_data_stack.dart` 的说明）；这里只装配会话层。
library;

import 'dart:async';

import '../../providers/lyrics_provider.dart';
import '../../providers/playback_provider.dart';
import '../../playback/playback_power_policy.dart';
import '../../services/bili_account_service.dart';
import '../../sources/source_manager.dart';
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

/// B 站登录（本地扫码或同步到达）→ 清 B 站原生取词缓存 → 刷新当前歌词。
///
/// `BuiltinLyricDispatch` 会把「无字幕」的 null 缓存 5 分钟；不清的话登录后
/// 当前曲目仍会命中旧结果，继续显示网易云。
void wireBiliLoginLyricsRefresh({
  required BiliAccountService account,
  required SourceManager sourceManager,
  required LyricsProvider lyricsProvider,
}) {
  account.onLoggedIn = () {
    sourceManager.invalidateLyricCacheFor('bili');
    unawaited(lyricsProvider.refreshAfterBiliLogin());
  };
}

/// 下一首歌词预载：统一挂在这里，不依赖歌词组件是否挂载/展开；
/// 去重与缓存写入由 [LyricsProvider.preload] 负责。
///
/// 调用点在歌词显示装配之后（与原组合根同一时机）。
///
/// [powerPolicy] 非空时只在「后台仍有歌词输出」或前台才取词；退后台且没有
/// 任何输出时先记下待预载曲目，回前台 / 打开输出后补一次。
void wireNextTrackLyricsPreload({
  required PlaybackProvider playback,
  required LyricsProvider lyricsProvider,
  PlaybackPowerPolicy? powerPolicy,
}) {
  String? preloadedNextLyricsId;
  void syncNextTrackLyricsPreload() {
    if (powerPolicy != null && !powerPolicy.shouldLoadLyrics) return;
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
  powerPolicy?.addListener(syncNextTrackLyricsPreload);
  syncNextTrackLyricsPreload();
}

/// 曲目变化 → 歌词会话的唯一加载入口。
///
/// 挂在播放快照上而不是歌词页 build：歌词页未挂载（或从未打开）时也按
/// 当前曲目加载；页面只渲染会话状态。去重 / 过期响应 / 空结果重试都由
/// [LyricsProvider.ensureForTrack] 承担。
///
/// [powerPolicy] 非空时后台没有歌词输出就不取词（切歌只为看不见的页面
/// 拉网络没有意义）；回前台 / 打开输出后由策略通知补一次。
void wireLyricsSession({
  required PlaybackProvider playback,
  required LyricsProvider lyricsProvider,
  PlaybackPowerPolicy? powerPolicy,
}) {
  void syncCurrentTrack() {
    if (powerPolicy != null && !powerPolicy.shouldLoadLyrics) return;
    unawaited(lyricsProvider.ensureForTrack(playback.snapshot.current));
  }

  playback.addListener(syncCurrentTrack);
  powerPolicy?.addListener(syncCurrentTrack);
  syncCurrentTrack();
}
