import '../../domain/models/device_sync.dart';
import 'adapters/prefs_sync_adapter.dart';

/// 可同步设置键的总表（唯一事实来源：同步类别、存储位置、默认值）。
///
/// 划分原则：
/// - **跟人走**：主题 / 语言 / 导航 / 歌词显示 / 默认播放模式 / 统计开关 /
///   App 标题 → `settings`；
/// - **音源**：渠道顺序、停用、音质、any-listen 连接 → `sources`
///   （LX 脚本本体由 ScriptSyncAdapter 处理）；
/// - **凭证**：AI Key / any-listen token / AI DJ 配置 → `credentials`
///   （随快照加密传输，加入同步即互信，见 ADR-0003）；
/// - **设备相关项不同步**：省流模式、缓存策略、桌面歌词的悬浮窗开关、
///   全局字体（字体来自本机已装字体）、AI 待处理批次等。
const List<SyncSettingSpec> kSyncSettingSpecs = [
  SyncSettingSpec(
    key: 'theme_mode',
    category: SyncCategory.settings,
    defaultValue: 'system',
  ),
  SyncSettingSpec(
    key: 'color_base',
    category: SyncCategory.settings,
    defaultValue: 'custom',
  ),
  SyncSettingSpec(
    key: 'follow_artwork_enabled',
    category: SyncCategory.settings,
    kind: SyncValueKind.bool,
    defaultValue: true,
  ),
  SyncSettingSpec(
    key: 'pure_black_enabled',
    category: SyncCategory.settings,
    kind: SyncValueKind.bool,
    defaultValue: false,
  ),
  SyncSettingSpec(
    key: 'seed_color',
    category: SyncCategory.settings,
    kind: SyncValueKind.int,
    defaultValue: 0xFF2196F3,
  ),
  SyncSettingSpec(
    key: 'app_display_title',
    category: SyncCategory.settings,
  ),
  SyncSettingSpec(
    key: 'selected_language',
    category: SyncCategory.settings,
  ),
  SyncSettingSpec(
    key: 'shell_nav_order',
    category: SyncCategory.settings,
    kind: SyncValueKind.stringList,
    defaultValue: ['library', 'nowPlaying', 'favorites'],
  ),
  SyncSettingSpec(
    key: 'shell_nav_hidden',
    category: SyncCategory.settings,
    kind: SyncValueKind.stringList,
    defaultValue: <String>[],
  ),
  SyncSettingSpec(
    key: 'default_play_mode',
    category: SyncCategory.settings,
    defaultValue: 'sequential',
  ),
  SyncSettingSpec(
    key: 'play_statistics_enabled',
    category: SyncCategory.settings,
    kind: SyncValueKind.bool,
    defaultValue: true,
  ),
  SyncSettingSpec(
    key: 'lyrics_display_settings_v1',
    category: SyncCategory.settings,
  ),
  SyncSettingSpec(
    key: 'copy_lyrics_single_line',
    category: SyncCategory.settings,
    store: SyncValueStore.secure,
  ),

  SyncSettingSpec(
    key: 'lx_default_quality',
    category: SyncCategory.sources,
    defaultValue: '320k',
  ),
  SyncSettingSpec(
    key: 'lx_source_order',
    category: SyncCategory.sources,
    kind: SyncValueKind.stringList,
    defaultValue: <String>[],
  ),
  SyncSettingSpec(
    key: 'lx_channel_disabled',
    category: SyncCategory.sources,
    kind: SyncValueKind.stringList,
    defaultValue: <String>[],
  ),
  SyncSettingSpec(
    key: 'any_listen_server_url',
    category: SyncCategory.sources,
    defaultValue: '',
  ),
  SyncSettingSpec(
    key: 'any_listen_enabled',
    category: SyncCategory.sources,
    kind: SyncValueKind.bool,
    defaultValue: false,
  ),

  SyncSettingSpec(
    key: 'any_listen_token',
    category: SyncCategory.credentials,
    defaultValue: '',
  ),
  SyncSettingSpec(
    key: 'ai_dj_base_url',
    category: SyncCategory.credentials,
    store: SyncValueStore.secure,
    defaultValue: '',
  ),
  SyncSettingSpec(
    key: 'ai_dj_api_key',
    category: SyncCategory.credentials,
    store: SyncValueStore.secure,
    defaultValue: '',
  ),
  SyncSettingSpec(
    key: 'ai_dj_model',
    category: SyncCategory.credentials,
    store: SyncValueStore.secure,
    defaultValue: '',
  ),
  SyncSettingSpec(
    key: 'ai_dj_consent_v1',
    category: SyncCategory.credentials,
    kind: SyncValueKind.bool,
    defaultValue: false,
  ),
];
