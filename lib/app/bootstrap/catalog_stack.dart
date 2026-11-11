/// 音源与目录栈：设置注册表（登记键的唯一家）→ SourceManager →
/// 音源注册表与各取数服务（目录 / 评论 / 专辑 / 歌手）。
///
/// 组合根的第一阶段：全部同步构造，无 await、不触碰平台插件；
/// 设置注册表的「模块自绑 reload」也在这里完成装配。
library;

import 'dart:async';

import '../../data/catalog/album_service.dart';
import '../../data/catalog/artist_service.dart';
import '../../data/catalog/catalog_service.dart';
import '../../data/catalog/comments_service.dart';
import '../../data/catalog/source_registry_impl.dart';
import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_module.dart';
import '../../data/settings/settings_registry.dart';
import '../../domain/ports/source_registry.dart';
import '../../services/app_branding_service.dart';
import '../../services/bili_account_service.dart';
import '../../services/language_service.dart';
import '../../services/shortcut_settings.dart';
import '../../services/source_swap/swap_query_planner.dart';
import '../../sources/source_manager.dart';

/// 目录栈产物（字段即子系统的对外面；构造顺序见 [buildCatalogStack]）。
typedef CatalogStack = ({
  SettingsRegistry settings,
  SourceManager sourceManager,
  SourceRegistry sourceRegistry,
  SwapQueryPlanner swapQueryPlanner,
  CatalogService catalogService,
  CommentsService commentsService,
  AlbumService albumService,
  ArtistService artistService,
  BiliAccountService biliAccount,
});

/// 装配设置注册表与音源/目录服务。
///
/// 「数据源维护」不在这里：脚本加载是启动后的
/// `sourceManager.init()`（首帧回调，见 `post_frame_init.dart`）。
CatalogStack buildCatalogStack() {
  // 设置注册表（登记键的唯一家）：读 / 写 / 同步往返 / 应用远端后的 reload
  // 钩子都走它；键的声明见 data/settings/settings_keys.dart。
  final settingsRegistry = SettingsRegistry(keys: kAllSettingsKeys);
  // 每个模块一次 mount：作用域键 + 应用远端值后的 reload 同屋；漏绑 reload
  // 会在 SettingsModule 构造时直接失败（见 data/settings/settings_module.dart）。
  //
  // 全静态服务（语言 / 品牌名 / 快捷键）：attach 注入按键作用域，模块面
  // 拿不到整表。
  final languageSettings = settingsRegistry.mount(
    SettingsModule(
      keys: [kSelectedLanguage],
      reload: LanguageService.reloadFromPreferences,
    ),
  );
  LanguageService.attachSettings(languageSettings);
  final brandingSettings = settingsRegistry.mount(
    SettingsModule(keys: [kAppDisplayTitle], reload: AppBrandingService.load),
  );
  AppBrandingService.attachSettings(brandingSettings);
  // 快捷键：attach 顺带触发一次异步载入；四个键任一被远端同步改写都整表重读
  // （reload 幂等，重复绑定同一钩子只执行一次）。
  final shortcutSettings = settingsRegistry.mount(
    SettingsModule(
      keys: [
        kShortcutsEnabled,
        kGlobalShortcutsEnabled,
        kShortcutBindings,
        kGlobalShortcutBindings,
      ],
      reload: ShortcutSettings.reload,
    ),
  );
  ShortcutSettings.attachSettings(shortcutSettings);

  // B 站账号：凭据是凭证类别（默认随同步 / 备份），初始化放后台，取词链路
  // 会 await `BiliSession.ready`，不阻塞首帧。
  late final BiliAccountService biliAccount;
  final biliSettings = settingsRegistry.mount(
    SettingsModule(
      keys: [kBiliAccountCookie],
      reload: () => biliAccount.reloadFromSettings(),
    ),
  );
  biliAccount = BiliAccountService(settings: biliSettings);
  unawaited(biliAccount.init());

  // 音源管理器的按键作用域：any-listen 连接 3 键 + 渠道偏好 3 键。两组
  // 重载路径不同（连接配置回读 / 渠道偏好整表重读），但同属一个挂载点。
  late final SourceManager sourceManager;
  final sourceSettings = settingsRegistry.mount(
    SettingsModule.withReloads(
      keys: [
        kAnyListenServerUrl,
        kAnyListenToken,
        kAnyListenEnabled,
        kLxDefaultQuality,
        kLxSourceOrder,
        kLxChannelDisabled,
      ],
      reloads: [
        (
          keys: [kAnyListenServerUrl, kAnyListenToken, kAnyListenEnabled],
          reload: () => sourceManager.reloadAnyListenConfig(),
        ),
        (
          keys: [kLxDefaultQuality, kLxSourceOrder, kLxChannelDisabled],
          reload: () => sourceManager.reloadPreferences(),
        ),
      ],
    ),
  );
  sourceManager = SourceManager(settings: sourceSettings);

  // 适配层：SourceManager → SourceRegistry → CatalogService。
  // SearchProvider 只依赖后两者（搜索缓存 single-flight + LRU + TTL 5min）。
  final sourceRegistry = SourceRegistryImpl(sourceManager);
  // 换源查询规划：手动换源、自动换源与封面补取共用同一实例，关键词口径
  // 与候选来源不再各拼一份。
  final swapQueryPlanner = SwapQueryPlanner(registry: sourceRegistry);
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
        sourceManager.fetchArtist(
          sourceKey,
          artistId,
          page: page,
          limit: limit,
        ),
  );

  return (
    settings: settingsRegistry,
    sourceManager: sourceManager,
    sourceRegistry: sourceRegistry,
    swapQueryPlanner: swapQueryPlanner,
    catalogService: catalogService,
    commentsService: commentsService,
    albumService: albumService,
    artistService: artistService,
    biliAccount: biliAccount,
  );
}
