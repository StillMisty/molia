/// 音源与目录栈：设置注册表（登记键的唯一家）→ SourceManager →
/// 音源注册表与各取数服务（目录 / 评论 / 专辑 / 歌手）。
///
/// 组合根的第一阶段：全部同步构造，无 await、不触碰平台插件；
/// 设置注册表的「模块自绑 reload」也在这里完成装配。
library;

import '../../data/catalog/album_service.dart';
import '../../data/catalog/artist_service.dart';
import '../../data/catalog/catalog_service.dart';
import '../../data/catalog/comments_service.dart';
import '../../data/catalog/source_registry_impl.dart';
import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_registry.dart';
import '../../domain/models/catalog.dart' show SearchQuery;
import '../../domain/ports/source_registry.dart';
import '../../services/app_branding_service.dart';
import '../../services/language_service.dart';
import '../../services/shortcut_settings.dart';
import '../../sources/source_manager.dart';

/// 目录栈产物（字段即子系统的对外面；构造顺序见 [buildCatalogStack]）。
typedef CatalogStack = ({
  SettingsRegistry settings,
  SourceManager sourceManager,
  SourceRegistry sourceRegistry,
  CatalogService catalogService,
  CommentsService commentsService,
  AlbumService albumService,
  ArtistService artistService,
});

/// 装配设置注册表与音源/目录服务。
///
/// 「数据源维护」不在这里：脚本加载是启动后的
/// `sourceManager.init()`（首帧回调，见 `post_frame_init.dart`）。
CatalogStack buildCatalogStack() {
  // 设置注册表（登记键的唯一家）：读 / 写 / 同步往返 / 应用远端后的 reload
  // 钩子都走它；键的声明见 data/settings/settings_keys.dart。
  final settingsRegistry = SettingsRegistry(keys: kAllSettingsKeys);
  // 全静态服务（语言 / 品牌名 / 快捷键）：attach 注入按键作用域，模块面
  // 拿不到整表；reload 由组合根在完整注册表上代绑。
  LanguageService.attachSettings(
    settingsRegistry.scope([kSelectedLanguage]),
  );
  AppBrandingService.attachSettings(
    settingsRegistry.scope([kAppDisplayTitle]),
  );
  // 快捷键：attach 顺带触发一次异步载入；四个键任一被远端同步改写都整表重读
  // （reload 幂等，重复绑定同一钩子只执行一次）。
  final shortcutSettingsScope = settingsRegistry.scope([
    kShortcutsEnabled,
    kGlobalShortcutsEnabled,
    kShortcutBindings,
    kGlobalShortcutBindings,
  ]);
  ShortcutSettings.attachSettings(shortcutSettingsScope);
  settingsRegistry.bindReload(
      kSelectedLanguage, LanguageService.reloadFromPreferences);
  settingsRegistry.bindReload(kAppDisplayTitle, AppBrandingService.load);
  settingsRegistry.bindReload(kShortcutsEnabled, ShortcutSettings.reload);
  settingsRegistry.bindReload(kGlobalShortcutsEnabled, ShortcutSettings.reload);
  settingsRegistry.bindReload(kShortcutBindings, ShortcutSettings.reload);
  settingsRegistry.bindReload(kGlobalShortcutBindings, ShortcutSettings.reload);

  // 音源管理器的按键作用域：any-listen 连接 3 键 + 渠道偏好 3 键
  // （SourcePreferences 在管理器的通知下自绑重载）。
  final sourceSettings = settingsRegistry.scope([
    kAnyListenServerUrl,
    kAnyListenToken,
    kAnyListenEnabled,
    kLxDefaultQuality,
    kLxSourceOrder,
    kLxChannelDisabled,
  ]);
  final sourceManager = SourceManager(settings: sourceSettings);

  // 适配层：SourceManager → SourceRegistry → CatalogService。
  // SearchProvider 只依赖后两者（搜索缓存 single-flight + LRU + TTL 5min）。
  final sourceRegistry = SourceRegistryImpl(sourceManager);
  final catalogService = CatalogService(registry: sourceRegistry);
  // 评论：与目录服务同构的缓存层（single-flight + LRU + 5min TTL，
  // key = comments:{source}:{songId}:{kind}:{page}）。
  final commentsService = CommentsService(registry: sourceRegistry);
  // 专辑：同一取数模式（single-flight + LRU + 10min TTL，
  // key = album:{source}:{albumId}:{page}）；取数注入 SourceManager.fetchAlbum，
  // 服务本身不依赖 sources 层。
  final albumService = AlbumService(
    fetch: (sourceKey, albumId, {required page, required limit}) =>
        sourceManager.fetchAlbum(sourceKey, albumId, page: page, limit: limit),
  );
  // 歌手：同一取数模式（key = artist:{source}:{artistId}:{page}）；
  // 取数注入 SourceManager.fetchArtist。
  final artistService = ArtistService(
    fetch: (sourceKey, artistId, {required page, required limit}) =>
        sourceManager.fetchArtist(sourceKey, artistId,
            page: page, limit: limit),
    // 历史收藏 / 导入列表没有 raw 歌手 id：按名字回退检索（精确匹配在服务内）。
    search: (sourceKey, name) async => (await catalogService.searchArtists(
      sourceKey,
      SearchQuery(keyword: name, limit: 10),
    ))
        .items,
  );

  return (
    settings: settingsRegistry,
    sourceManager: sourceManager,
    sourceRegistry: sourceRegistry,
    catalogService: catalogService,
    commentsService: commentsService,
    albumService: albumService,
    artistService: artistService,
  );
}
