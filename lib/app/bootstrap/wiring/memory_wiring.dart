/// 内存守卫接线：低内存观察者、可重建缓存清单、低内存落盘与托盘 trim。
///
/// 只注册入口，[AppMemoryManager] 不反向依赖这些业务类型；普通退后台不释放
/// 列表，只有托盘隐藏、移动端后台与系统低内存才触发（见各段注释）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../providers/library_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../services/app_presence.dart';
import '../../../services/memory/app_memory_manager.dart';
import '../../../sources/builtin/builtin_search.dart';
import '../catalog_stack.dart';
import '../library_stack.dart';
import '../local_data_stack.dart';
import '../playback_stack.dart';
import '../sync_stack.dart';

/// 系统低内存信号：只有在这种情况下释放可重建的浏览 / 搜索 / 目录缓存。
///
/// 普通退后台不释放列表——恢复时用户会看到空列表并被迫重读；系统明确报告
/// 内存压力时才值得用「恢复后重读」换一次释放。Android 的 lifecycle trim
/// （UI_HIDDEN / BACKGROUND）已在 `MainActivity.onTrimMemory` 过滤，这里只会
/// 收到真正的 running-low 或其它平台的内存警告。
class _MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() => AppMemoryManager.instance.onMemoryPressure();
}

/// 注册系统低内存观察者（平台装配阶段调用一次）。
void installMemoryPressureObserver() {
  WidgetsBinding.instance.addObserver(_MemoryPressureObserver());
}

/// 注册托盘 / 系统低内存时可释放的业务缓存与低内存落盘动作。
///
/// 不动收藏、历史、脚本与当前播放队列：搜索结果是本次会话的瞬时数据；列表
/// 曲目与目录分页页退出后按需重取；内置平台响应 / 原生取词取图 / 封面补取 /
/// 统计导出都是可重读的派生缓存，同步轮次的收集与快照缓存也只在轮间复用。
void wireMemoryReclaim({
  required CatalogStack catalog,
  required LocalDataStack local,
  required LibraryStack library,
  required PlaybackStack playback,
  required SyncStack sync,
  required LibraryProvider libraryProvider,
  required SearchProvider searchProvider,
}) {
  final reclaimableCaches = <void Function()>[
    libraryProvider.releaseBrowseCaches,
    searchProvider.releaseSearchResults,
    catalog.catalogService.clearSearchCache,
    catalog.albumService.clearCache,
    catalog.artistService.clearCache,
    catalog.commentsService.clearCache,
    library.statisticsSyncStore.releaseExportCaches,
    BuiltinSearch.clearCachedResponses,
    catalog.sourceManager.releaseBuiltinLyricCache,
    catalog.sourceManager.releaseBuiltinPicCache,
    local.coverBackfill.clearCache,
    sync.engine.releaseIdleCaches,
  ];
  for (final releaser in reclaimableCaches) {
    AppMemoryManager.instance
      ..addReleaser(releaser)
      ..addLowMemoryReleaser(releaser);
  }
  // 真实低内存时先把「现场」落盘：系统可能在随后几秒内查杀进程（含 OEM
  // 的内存治理），播放队列 / 进度 / 统计不该等下一次 pause。保存与上面的
  // 缓存释放并发，失败只记日志。
  AppMemoryManager.instance.addLowMemoryFlusher(() async {
    await playback.playbackProvider.suspendPlaybackSession();
    await library.playStatisticsService.flush();
  });
}

/// 托盘隐藏 / 最小化 / 恢复时的 trim 与暂停后归还工作集。
///
/// 桌面托盘 / 最小化不一定走 `AppLifecycleState`：窗口层置位 [AppPresence]
/// 时补一次；`minimized` 同样算不可见（用户随时可能从任务栏恢复）。
void wireTrayTrim({required PlaybackStack playback}) {
  // 托盘内暂停后补一次 trim：播放中暂停会让音频 / 解码线程把页重新触回
  // 工作集，暂停稳定后再归还；播放恢复 / 窗口可见时取消。
  Future<void> releaseIdlePlayer() =>
      playback.localPlaybackService?.releasePlayerForIdle() ?? Future.value();
  var lastPlaying = playback.playbackProvider.isPlaying;
  var lastTrackId = playback.playbackProvider.snapshot.current?.id.uri;
  void syncTrayTrimTimers() {
    final playing = playback.playbackProvider.isPlaying;
    final trackId = playback.playbackProvider.snapshot.current?.id.uri;
    final playingChanged = playing != lastPlaying;
    final trackChanged = trackId != lastTrackId;
    lastPlaying = playing;
    lastTrackId = trackId;
    if (playingChanged) {
      if (playing) {
        AppMemoryManager.instance.cancelTrayPausedTrim();
      } else if (AppPresence.instance.isTrayHidden) {
        AppMemoryManager.instance.scheduleTrayPausedTrim(
          onIdle: releaseIdlePlayer,
        );
      }
    }
    if (trackChanged && AppPresence.instance.isTrayHidden) {
      AppMemoryManager.instance.scheduleTrayTrackChangeTrim();
    }
  }

  playback.playbackProvider.addListener(syncTrayTrimTimers);
  AppPresence.instance.addListener(() {
    if (AppPresence.instance.isTrayHidden) {
      if (!playback.playbackProvider.isPlaying) {
        AppMemoryManager.instance.scheduleTrayPausedTrim(
          onIdle: releaseIdlePlayer,
        );
      }
    } else {
      AppMemoryManager.instance
        ..cancelTrayPausedTrim()
        ..cancelTrayTrackChangeTrim();
    }
  });
}
