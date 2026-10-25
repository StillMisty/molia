/// 本地数据栈：省流模式与封面网关 → 下载设置 / 下载服务 → 歌词服务 →
/// 音频缓存字节写入器 + 缓存启动维护。
///
/// **为什么歌词服务在这里**：歌词服务（在线取词）与下载服务互为依赖——
/// 下载动作要在线取词（`DownloadService.lyricsResolver` → `LyricsService`），
/// 本地曲目取词要读下载的离线歌词（`LyricsService.trackLyricLoader` →
/// `readDownloadedLyrics`）。把「读离线歌词」收在存储级函数里、并让歌词服务
/// 先于下载服务构建，两个方向都变成普通参数：没有前向引用，也没有跨 builder
/// 回填（原组合根是 `late final lyricsService` + 六十行后回填）。
library;

import 'dart:async';

import '../../data/downloads/download_notifications.dart';
import '../../data/downloads/download_storage.dart';
import '../../data/downloads/downloads_publisher.dart';
import '../../data/downloads/downloads_repository.dart';
import '../../data/downloads/local_lyrics.dart';
import '../../data/mapping/track_mapper.dart';
import '../../domain/models/download.dart' show kLocalSourceKey;
import '../../domain/models/track.dart';
import '../../managers/artwork_cache.dart';
import '../../playback/audio_predownloader.dart';
import '../../services/cache_service.dart';
import '../../services/covers/custom_cover_store.dart';
import '../../services/data_saver_service.dart';
import '../../services/download/download_service.dart';
import '../../services/download/download_settings.dart';
import '../../services/lyrics_cache.dart';
import '../../services/lyrics_service.dart';
import 'catalog_stack.dart';
import 'startup_trace.dart';

/// 本地数据栈产物（构造顺序见 [buildLocalDataStack]）。
typedef LocalDataStack = ({
  DataSaverService dataSaver,
  DownloadSettings downloadSettings,
  DownloadService downloadService,
  LyricsService lyricsService,
  AudioPredownloader audioCacheWriter,
  CustomCoverStore customCovers,
});

/// 装配省流模式、下载链路、歌词服务与音频缓存写入器。
Future<LocalDataStack> buildLocalDataStack({
  required CatalogStack catalog,
}) async {
  final sourceManager = catalog.sourceManager;

  // 歌词缓存的文件后端只在生产组合根显式启用：默认 `LyricsCache()` 保持
  // prefs-only，避免 widget 测试 / 降级平台在 fake async 下等待平台通道与文件
  // Future。`appSupport()` 只登记惰性 resolver，不在这里解析目录，首帧不受影响。
  // 取词服务与缓存页统计必须共享同一实例，否则一边写文件、一边读/清 prefs。
  final lyricsCache = LyricsCache.appSupport();
  CacheService.instance.attachLyricsCache(lyricsCache);

  // 省流模式（仅移动数据生效）：必须在解析/播放/封面链路创建前就绪，
  // 供取链回调、封面网关与播放 provider 共享同一实例。
  // 下载设置（设备本地：保存位置 / 文件名格式 / 标签嵌入开关）与省流
  // 互不依赖：两者并行初始化（纯 prefs 读，等待时间取最大值）。
  final dataSaverWatch = Stopwatch()..start();
  final dataSaver = DataSaverService();
  final downloadSettings = DownloadSettings();
  // 省流只读偏好、不探测网络：connectivity_plus 的探测与订阅由首帧后的
  // `startMonitoring` 启动（见 post_frame_init.dart）。
  await (dataSaver.init(monitor: false), downloadSettings.init()).wait;
  markStartupStep('sub.dataSaver/downloadSettings', dataSaverWatch);
  // 封面统一咽喉：省流生效时只用本地缓存，不发网络请求
  // （AppNetworkImage / artworkImageProvider / 取色共用）。
  ArtworkCache.instance.networkImageBlocked =
      () => dataSaver.blockNetworkArtwork;

  final downloadStorage = createDownloadStorage(
    customRoot: () => downloadSettings.saveDir,
  );

  // 自定义封面（每曲 + 默认）：设备本地文件 + prefs 索引。启动只读索引 /
  // 剔除丢失文件，不解码图片；下载与播放共用同一实例。
  final customCoversWatch = Stopwatch()..start();
  final customCovers = CustomCoverStore.instance;
  await customCovers.load();
  markStartupStep('sub.customCovers.load', customCoversWatch);

  // 歌词服务提前创建（见文件头：与下载服务互为依赖的构建顺序）。
  // 曲目原生取词经 SourceManager 统一路由：脚本 lyric action →
  // any-listen → 内置平台原生实现（wy/tx/kg/kw/mg/bili，精确平台 ID）。
  final lyricsService = LyricsService(
    // 与 `CacheService.instance` 共享同一个文件后端实例（见上）。
    lyricsCache: lyricsCache,
    // 本地下载曲目：离线歌词缺失时不回退网络（离线播放全程不触网）。
    networkFallbackAllowed: (track) => track.id.sourceKey != kLocalSourceKey,
    trackLyricLoader: (track) async {
      // 本地下载曲目：读 downloads/lyrics/ 的离线歌词（不触网）；
      // 无离线歌词返回 null，交给既有歌词源（在线时仍可补全）。
      if (track.id.sourceKey == kLocalSourceKey) {
        return readDownloadedLyrics(downloadStorage, track);
      }
      final result =
          await sourceManager.fetchLyric(sourceTrackFromTrack(track));
      if (result == null || result.lyric.trim().isEmpty) return null;
      return LyricsResult(
        lyric: result.lyric,
        translation: result.tlyric,
        roma: result.rlyric,
        lxlyric: result.lxlyric,
        provider: track.id.sourceKey,
      );
    },
  );

  // 本地下载：持久副本 + 离线歌词/封面 + 音频标签嵌入。
  // 存储不可用（无文件系统 / 目录解析失败）时 supported=false，UI 隐藏下载
  // 入口；初始化失败不阻断
  // 启动（init 内部已吞错）。下载时的取词/取图**缓存优先**：歌词与播放页
  // 共用同一个 LyricsService（缓存 → 原生 → 跨平台回退），封面经 ArtworkCache
  // 命中直读、未命中取图后回填；音频命中完整缓存时直接拷贝，不触网。
  final downloadService = DownloadService(
    catalog: catalog.catalogService,
    repository: DownloadsRepository(),
    storage: downloadStorage,
    cacheService: CacheService.instance,
    artworkCache: ArtworkCache.instance,
    settings: downloadSettings,
    publisher: createDownloadsPublisher(),
    notifications: createDownloadNotifications(),
    lyricsResolver: (track) => _resolveDownloadLyrics(lyricsService, track),
    artworkResolver: (track) =>
        sourceManager.fetchPic(sourceTrackFromTrack(track)),
    customCoverResolver: (track) => customCovers.readTrackCover(track.id),
    preferredQuality: () =>
        dataSaver.effectiveQuality(sourceManager.preferredQuality),
  );
  // 下载记录 / `.part` 清扫后移到首帧之后：存储根解析、全量记录读取与目录
  // 扫描都不参与首帧内容。服务先构造好交给 Provider 树，`post_frame_init`
  // 调 `init()`；依赖记录的方法经 `ready` 自行等待就绪。
  //
  // 音频缓存字节写入器：两处复用同一实例——
  // 1) 下一首字节预取（`NextTrackPreloader`，起播后预热下一首）；
  // 2) 当前曲目后台缓存（`PlayingTrackCacheWriter`，桌面等播放侧不写缓存的
  //    平台由它补齐缓存，重播经 `localUriFor` 命中 file://）。
  // 省流实际生效（移动数据 + 已开启）时两边都跳过，只预热直链。
  final audioCacheWriter = CacheAudioPredownloader(
    cacheService: CacheService.instance,
    allowed: () => !dataSaver.active,
  );

  return (
    dataSaver: dataSaver,
    downloadSettings: downloadSettings,
    downloadService: downloadService,
    lyricsService: lyricsService,
    audioCacheWriter: audioCacheWriter,
    customCovers: customCovers,
  );
}

/// 下载时的取词：与播放页共享同一个 `LyricsService` 实例（缓存优先）。
Future<DownloadLyrics?> _resolveDownloadLyrics(
  LyricsService lyricsService,
  Track track,
) async {
  final result = await lyricsService.getLyrics(
    track.title,
    track.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .join(', '),
    track.id.uri,
    track: track,
  );
  if (result == null || result.lyric.trim().isEmpty) return null;
  return DownloadLyrics(
    lyric: result.lyric,
    translation: result.translation,
  );
}
