/// 登记键总表：键名、同步类别、默认值、存放盒的唯一声明处。
///
/// 划分原则（与 ADR-0003 §5 一致）：
/// - **跟人走** → [SyncCategory.settings]：主题 / 语言 / 导航 / 歌词显示 /
///   默认播放模式 / 统计开关 / App 标题 / AI 功能开关…；
/// - **音源** → [SyncCategory.sources]：渠道顺序、停用、默认音质、
///   any-listen 连接（LX 脚本本体由 ScriptSyncAdapter 处理）；
/// - **凭证** → [SyncCategory.credentials]：AI Key / any-listen token，
///   随快照加密传输（加入同步即互信，见 ADR-0003）；
/// - **设备相关项不登记**：省流模式、缓存策略、桌面歌词悬浮窗开关、全局字体、
///   AI 待处理批次、播放会话、曲库数据等 —— 只有一位消费者，留在各自模块。
///
/// 「一个键一个家」：键名字面量只准出现在本文件（另有 registry 读写与
/// reload 钩子），由 test/architecture/settings_key_literals_test.dart 扫描强制。
library;

import '../../domain/models/ai_dj.dart';
import '../../domain/models/device_sync.dart';
import 'settings_key.dart';

// ── 跟人走：主题 / 外观 ──────────────────────────────────────────────
const kThemeMode = SettingsKey<String>(
  'theme_mode',
  'system',
  category: SyncCategory.settings,
);

/// 基础配色：默认壁纸（桌面优先壁纸图取色，其次系统强调色；都不可用时回退自定义种子色）。
const kColorBase = SettingsKey<String>(
  'color_base',
  'wallpaper',
  category: SyncCategory.settings,
);
const kFollowArtworkEnabled = SettingsKey<bool>(
  'follow_artwork_enabled',
  true,
  category: SyncCategory.settings,
);
const kPureBlackEnabled = SettingsKey<bool>(
  'pure_black_enabled',
  false,
  category: SyncCategory.settings,
);
const kSeedColor = SettingsKey<int>(
  'seed_color',
  0xFF2196F3,
  category: SyncCategory.settings,
);

// ── 跟人走：壳 / 语言 / 歌词显示 / 播放偏好 ──────────────────────────
const kAppDisplayTitle = SettingsKey<String?>(
  'app_display_title',
  null,
  category: SyncCategory.settings,
);
const kSelectedLanguage = SettingsKey<String?>(
  'selected_language',
  null,
  category: SyncCategory.settings,
);
const kShellNavOrder = SettingsKey<List<String>>(
  'shell_nav_order',
  ['library', 'nowPlaying', 'favorites'],
  category: SyncCategory.settings,
);
const kShellNavHidden = SettingsKey<List<String>>(
  'shell_nav_hidden',
  <String>[],
  category: SyncCategory.settings,
);

/// 启动首页（跟人走，随设置同步）。值 = ShellDestination.name；非法值回退默认。
const kShellHomeDestination = SettingsKey<String>(
  'shell_home_destination',
  'nowPlaying',
  category: SyncCategory.settings,
);

/// 软件内快捷键总开关（窗口聚焦时生效；默认开）。
const kShortcutsEnabled = SettingsKey<bool>(
  'shortcuts_enabled',
  true,
  category: SyncCategory.settings,
);

/// 全局快捷键总开关（系统级热键，默认关：避免与系统/其它应用抢热键）。
const kGlobalShortcutsEnabled = SettingsKey<bool>(
  'global_shortcuts_enabled',
  false,
  category: SyncCategory.settings,
);

/// 软件内快捷键的自定义绑定（JSON：动作 → 组合；空串 = 全默认）。
const kShortcutBindings = SettingsKey<String>(
  'shortcut_bindings',
  '',
  category: SyncCategory.settings,
);

/// 全局快捷键的自定义绑定（同上）。
const kGlobalShortcutBindings = SettingsKey<String>(
  'global_shortcut_bindings',
  '',
  category: SyncCategory.settings,
);
const kDefaultPlayMode = SettingsKey<String>(
  'default_play_mode',
  'listLoop',
  category: SyncCategory.settings,
);

/// 启动时恢复上次播放（曲目 / 队列 / 进度）；关闭后冷启动不进入恢复态。
const kRestoreSessionEnabled = SettingsKey<bool>(
  'restore_session_enabled',
  true,
  category: SyncCategory.settings,
);
const kPlayStatisticsEnabled = SettingsKey<bool>(
  'play_statistics_enabled',
  true,
  category: SyncCategory.settings,
);
const kLyricsDisplaySettings = SettingsKey<String?>(
  'lyrics_display_settings_v1',
  null,
  category: SyncCategory.settings,
);

// ── 跟人走：AI 推歌开关与偏好（连接信息见凭证区） ────────────────────
const kAiDjEnabled = SettingsKey<bool>(
  'ai_dj_enabled',
  false,
  category: SyncCategory.settings,
);
const kAiDjCacheTtlDays = SettingsKey<int>(
  'ai_dj_cache_ttl_days',
  kAiDefaultCacheTtlDays,
  category: SyncCategory.settings,
);

/// 推荐偏好（JSON：批次大小 / 自动补歌 / 风格 / 场景 / 发送范围 / 渠道…）。
const kAiDjPreferences = SettingsKey<String>(
  'ai_dj_preferences_v1',
  '',
  category: SyncCategory.settings,
);

/// 跨重启反馈记忆（JSON：不感兴趣 / 喜欢 / 种子）。
const kAiDjFeedbackMemory = SettingsKey<String>(
  'ai_dj_feedback_memory_v1',
  '',
  category: SyncCategory.settings,
);

// ── 跟人走：自动换源（播放失败后的自动行为） ────────────────────────
const kSourceSwapAutoEnabled = SettingsKey<bool>(
  'source_swap_auto_enabled',
  true,
  category: SyncCategory.settings,
);

// ── 跟人走：资料库（加入收藏 / 列表的位置） ──────────────────────────

/// 新曲目加入收藏 / 自建列表时放的位置：`top` = 列表开头（默认），
/// `bottom` = 列表末尾。
const kLibraryAddPosition = SettingsKey<String>(
  'library_add_position',
  'top',
  category: SyncCategory.settings,
);

// ── 音源：LX 质量 / 顺序 / 停用与 any-listen 连接 ─────────────────────
const kLxDefaultQuality = SettingsKey<String>(
  'lx_default_quality',
  '320k',
  category: SyncCategory.sources,
);
const kLxSourceOrder = SettingsKey<List<String>>(
  'lx_source_order',
  <String>[],
  category: SyncCategory.sources,
);
const kLxChannelDisabled = SettingsKey<List<String>>(
  'lx_channel_disabled',
  <String>[],
  category: SyncCategory.sources,
);
const kAnyListenServerUrl = SettingsKey<String>(
  'any_listen_server_url',
  '',
  category: SyncCategory.sources,
);
const kAnyListenEnabled = SettingsKey<bool>(
  'any_listen_enabled',
  false,
  category: SyncCategory.sources,
);

// ── 凭证：随快照加密传输 ────────────────────────────────────────────
const kAnyListenToken = SettingsKey<String>(
  'any_listen_token',
  '',
  category: SyncCategory.credentials,
);
const kAiDjBaseUrl = SettingsKey<String>(
  'ai_dj_base_url',
  '',
  category: SyncCategory.credentials,
  store: SettingsValueStore.secure,
);
const kAiDjApiKey = SettingsKey<String>(
  'ai_dj_api_key',
  '',
  category: SyncCategory.credentials,
  store: SettingsValueStore.secure,
);
const kAiDjModel = SettingsKey<String>(
  'ai_dj_model',
  '',
  category: SyncCategory.credentials,
  store: SettingsValueStore.secure,
);
const kAiDjConsent = SettingsKey<bool>(
  'ai_dj_consent_v1',
  false,
  category: SyncCategory.credentials,
);

/// 全表（顺序即同步收集顺序）：组合根据此构造注册表，扫描测试据此核对键序。
const List<SettingsKey<Object?>> kAllSettingsKeys = [
  kThemeMode,
  kColorBase,
  kFollowArtworkEnabled,
  kPureBlackEnabled,
  kSeedColor,
  kAppDisplayTitle,
  kSelectedLanguage,
  kShellNavOrder,
  kShellNavHidden,
  kShellHomeDestination,
  kShortcutsEnabled,
  kGlobalShortcutsEnabled,
  kShortcutBindings,
  kGlobalShortcutBindings,
  kDefaultPlayMode,
  kRestoreSessionEnabled,
  kPlayStatisticsEnabled,
  kLyricsDisplaySettings,
  kAiDjEnabled,
  kAiDjCacheTtlDays,
  kAiDjPreferences,
  kAiDjFeedbackMemory,
  kSourceSwapAutoEnabled,
  kLibraryAddPosition,
  kLxDefaultQuality,
  kLxSourceOrder,
  kLxChannelDisabled,
  kAnyListenServerUrl,
  kAnyListenEnabled,
  kAnyListenToken,
  kAiDjBaseUrl,
  kAiDjApiKey,
  kAiDjModel,
  kAiDjConsent,
];
