/// runApp 前挂载的 Provider 树：所有子系统产物在这里一次性暴露给 UI。
///
/// provider 的**构造顺序即依赖顺序**（与原组合根一致）：
/// 上面的 `create:` provider 会 `context.read` 下面已有的实例
/// （PlaybackProvider / LibraryProvider / SearchProvider …），顺序不能随意调整。
library;

import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../../data/catalog/album_service.dart';
import '../../data/catalog/artist_service.dart';
import '../../data/catalog/catalog_service.dart';
import '../../data/play_statistics_repository.dart';
import '../../domain/ports/source_registry.dart';
import '../../managers/artwork_cache.dart';
import '../../providers/comments_provider.dart';
import '../../providers/discover_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../providers/play_statistics_provider.dart';
import '../../providers/search_provider.dart';
import '../../providers/source_swap_provider.dart';
import '../../providers/sources_provider.dart';
import '../../services/ai/ai_recommendation_service.dart';
import '../../services/ai/ai_settings_store.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/cache_service.dart';
import '../../services/notification_service.dart';
import '../../services/play_statistics_service.dart';
import '../../services/save_as.dart';
import '../../services/shortcut_settings.dart';
import '../../services/track_local_data_service.dart';
import 'ai_stack.dart';
import 'catalog_stack.dart';
import 'desktop_stack.dart';
import 'library_stack.dart';
import 'lyrics_display_stack.dart';
import 'lyrics_stack.dart';
import 'local_data_stack.dart';
import 'playback_stack.dart';
import 'sync_stack.dart';
import 'update_stack.dart';

/// 组装 Provider 树（顺序敏感，见文件头）。
List<SingleChildWidget> buildAppProviders({
  required CatalogStack catalog,
  required LocalDataStack local,
  required LibraryStack library,
  required PlaybackStack playback,
  required LibraryProvider libraryProvider,
  required DesktopStack desktop,
  required AiStack ai,
  required LyricsStack lyrics,
  required LyricsDisplayStack display,
  required SyncStack sync,
  required UpdateStack update,
  required NotificationService notifications,
}) {
  final sourceManager = catalog.sourceManager;
  final sourceRegistry = catalog.sourceRegistry;
  final catalogService = catalog.catalogService;
  final playbackProvider = playback.playbackProvider;
  final downloadService = local.downloadService;
  // “另存目录”服务：下载设置里的桌面自选目录同时作用于导出；未设置时用
  // 各平台公共下载目录。页面经 Provider 读取，测试注入 fake。
  final saveAs = createSaveAs(
    customRoot: () => local.downloadSettings.saveDir,
  );
  return [
    Provider<SaveAs>.value(value: saveAs),
    ChangeNotifierProvider.value(value: sourceManager),
    // 音源管理 UI 门面：订阅同一个 SourceManager，生命周期与其一致
    // （不负责 dispose manager）。
    ChangeNotifierProvider(
      create: (_) => SourcesProvider(sourceManager),
    ),
    Provider<SourceRegistry>.value(value: sourceRegistry),
    Provider<CatalogService>.value(value: catalogService),
    // 专辑页取数（缓存/错误边界在服务内；页面只消费领域 Album）。
    Provider<AlbumService>.value(value: catalog.albumService),
    // 歌手页取数（同上，服务内收敛缓存与错误边界）。
    Provider<ArtistService>.value(value: catalog.artistService),
    // 评论页状态：热门 / 最新分页 + 刷新（评论缓存走 CommentsService）。
    ChangeNotifierProvider(
      create: (_) => CommentsProvider(
        service: catalog.commentsService,
        registry: sourceRegistry,
      ),
    ),
    ChangeNotifierProvider.value(value: playbackProvider),
    // 音频焦点偏好（设置 › 播放）：播放服务已订阅同一实例，开关即时生效。
    ChangeNotifierProvider.value(value: playback.audioFocusSettings),
    ChangeNotifierProvider.value(value: display.themeProvider),
    // 封面取色服务（海报「跟随封面」按需查询；主题链路已在上方接线）。
    Provider<ArtworkPaletteService>.value(value: display.artworkPaletteService),
    ChangeNotifierProvider.value(value: display.navProvider),
    ChangeNotifierProvider(
      create: (context) => SearchProvider(
        context.read<PlaybackProvider>(),
        catalogService: catalogService,
        sourceRegistry: sourceRegistry,
      ),
    ),
    ChangeNotifierProvider.value(value: library.localDatabaseProvider),
    // 资料库（收藏/历史/列表）：顶层创建（AI 推歌读取收藏作为反馈）。
    ChangeNotifierProvider.value(value: libraryProvider),
    // 换源：跨音源搜索 + 原位替换 + 队列跟随（收藏页 / 播放页入口）。
    ChangeNotifierProvider(
      create: (context) => SourceSwapProvider(
        catalogService: catalogService,
        sourceRegistry: sourceRegistry,
        libraryProvider: context.read<LibraryProvider>(),
        playbackProvider: context.read<PlaybackProvider>(),
      ),
    ),
    // AI 推歌：模式控制器 + 配置存储 + 生成服务。
    ChangeNotifierProvider.value(value: ai.djProvider),
    Provider<AiSettingsStore>.value(value: ai.settingsStore),
    Provider<AiRecommendationService>.value(value: ai.recommendationService),
    // 听歌统计：仓库（查询）与采集服务（开关）；统计页读取这两个实例。
    Provider<PlayStatisticsRepository>.value(
      value: library.playStatisticsRepository,
    ),
    Provider<PlayStatisticsService>.value(
      value: library.playStatisticsService,
    ),
    // 听歌统计页状态（范围 / 加载 / 清空 / 导出）；页面打开期间
    // 自行订阅仓库变更，关闭后取消。
    ChangeNotifierProvider(
      create: (_) => PlayStatisticsProvider(
        repository: library.playStatisticsRepository,
      ),
    ),
    // 发现页：热榜 / 歌单 / 热搜；播放与收藏复用上面两个 provider。
    // 渠道变化 → 搜索源跟随的唯一规则点（页面不自行同步两个 provider）。
    ChangeNotifierProvider(
      create: (context) => DiscoverProvider(
        playbackProvider: context.read<PlaybackProvider>(),
        libraryProvider: context.read<LibraryProvider>(),
        onChannelChanged: (key) {
          final search = context.read<SearchProvider>();
          if (search.sourceOptions
              .any((option) => option.key == key && option.canSearch)) {
            search.selectSource(key);
          }
        },
      ),
    ),
    ChangeNotifierProvider.value(value: lyrics.lyricsProvider),
    // 歌词显示：配置（设置页读写）+ 调度（桌面/通知/蓝牙输出）。
    ChangeNotifierProvider.value(value: display.lyricsDisplaySettings),
    ChangeNotifierProvider.value(value: display.lyricsDisplay),
    // 统一缓存门面（音频/歌词/封面）：设置页缓存管理读写策略与用量。
    Provider<CacheService>.value(value: CacheService.instance),
    // 单曲本地数据门面（下载记录 + 音频/歌词/封面/取链缓存）：
    // 播放页「本地数据」行与其子页消费（两档词表的唯一读取口）。
    Provider<TrackLocalDataService>(
      create: (_) => TrackLocalDataService(
        cacheService: CacheService.instance,
        artworkCache: ArtworkCache.instance,
        catalogService: catalogService,
        downloadService: downloadService,
      ),
    ),
    // 本地下载：信息页「本地数据」页与「已下载」列表共用同一状态源。
    // 与缓存门面是两套东西：清缓存不触碰 downloads/，删下载是独立动作。
    ChangeNotifierProvider.value(value: downloadService),
    // 下载设置：保存位置 / 文件名格式 / 标签嵌入（设置页读写）。
    ChangeNotifierProvider.value(value: local.downloadSettings),
    Provider<NotificationService>.value(value: notifications),
    // 省流模式：设置页读写开关/音质上限；取链与封面网关已在上方接线。
    ChangeNotifierProvider.value(value: local.dataSaver),
    // 跨设备数据同步：设置页读写。
    ChangeNotifierProvider.value(value: sync.provider),
    // 换源偏好（自动换源开关）：设置页读写；播放链路已在上方接线。
    ChangeNotifierProvider.value(value: library.sourceSwapSettings),
    // 加入收藏 / 列表的位置偏好：设置页读写；写入网关已按它取排序位。
    ChangeNotifierProvider.value(value: library.libraryAddSettings),
    // 托盘行为（关闭时最小化到托盘）：设置页读写；关闭策略已在上方接线。
    ChangeNotifierProvider.value(value: desktop.traySettings),
    // 快捷键设置：软件内 / 全局两组开关与绑定（设置页读写并订阅；桌面
    // 快捷键处理器直读同一单例，不依赖本 provider）。
    ChangeNotifierProvider.value(value: ShortcutSettings.instance),
    // 应用内更新：设置页读写（渠道 / 自动检查 / 下载安装）。
    ChangeNotifierProvider.value(value: update.provider),
  ];
}
