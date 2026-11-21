/// 设备本地设置键总表：迁移到 [DeviceSettings] 的键只在这里声明。
///
/// 键名字符串与迁移前逐字一致（无数据迁移）；默认值也集中在此，store 的
/// 公开常量引用这里，避免同一默认值出现两份。JSON 键在这里同时声明字段
/// 形状（decode / encode），store 不再各自解析原始 Map。
///
/// 这些键**不**进入 `settings_keys.dart` / `kAllSettingsKeys`：设备本地
/// 状态（听感、音量、首次引导）不跟人走，也不进完整备份。
library;

import 'dart:ui' show Rect;

import '../../domain/models/music_folder.dart';
import '../../domain/models/playback_feel.dart';
import 'device_settings.dart';

/// 播放手感（淡入淡出 / 智能随机）合并键。
const String kPlaybackFeelStateKeyName = 'playback_feel_state_v1';

/// 音量与静音合并键。
const String kPlaybackVolumeStateKeyName = 'playback_volume_state_v1';

/// 旧版音量两键：只读兜底，新键缺失时才读。
const String kPlaybackVolumeKeyName = 'playback_volume';
const String kPlaybackMutedKeyName = 'playback_muted';

/// 首次引导完成标记。
const String kOnboardingCompletedKeyName = 'onboarding_completed_v1';

/// 播放手感的默认值（store 的公开常量引用这里）。
const bool kDefaultSmartShuffle = true;

/// 音量的默认值（store 的公开常量引用这里）。
const double kDefaultPlaybackVolume = 1.0;
const bool kDefaultPlaybackMuted = false;

/// 播放手感 JSON 的字段解释：非有限毫秒值视为损坏（`1e999` 会解码成
/// Infinity，直接 `toInt()` 会抛 `UnsupportedError`）。
({PlaybackFadePreset fade, bool smartShuffle})? _decodePlaybackFeel(
  Map<String, dynamic> json,
) {
  final fadeMs = json['fadeMs'];
  final smartShuffle = json['smartShuffle'];
  if (fadeMs is! num || smartShuffle is! bool) return null;
  final milliseconds = fadeMs.toDouble();
  if (!milliseconds.isFinite) return null;
  return (
    fade: PlaybackFadePreset.fromMilliseconds(milliseconds.toInt()),
    smartShuffle: smartShuffle,
  );
}

Map<String, Object?> _encodePlaybackFeel(
  ({PlaybackFadePreset fade, bool smartShuffle}) value,
) => {
  'fadeMs': value.fade.duration.inMilliseconds,
  'smartShuffle': value.smartShuffle,
};

/// 音量 JSON 的字段解释：非有限值视为损坏，越界值仍收进 0..1。
({double volume, bool muted})? _decodePlaybackVolume(
  Map<String, dynamic> json,
) {
  final volume = json['volume'];
  final muted = json['muted'];
  if (volume is! num || muted is! bool) return null;
  final value = volume.toDouble();
  if (!value.isFinite) return null;
  return (volume: value.clamp(0.0, 1.0), muted: muted);
}

Map<String, Object?> _encodePlaybackVolume(
  ({double volume, bool muted}) value,
) => {'volume': value.volume, 'muted': value.muted};

const DeviceJsonSettingKey<({PlaybackFadePreset fade, bool smartShuffle})>
kPlaybackFeelStateKey = DeviceJsonSettingKey(
  kPlaybackFeelStateKeyName,
  (fade: PlaybackFadePreset.ms200, smartShuffle: kDefaultSmartShuffle),
  decode: _decodePlaybackFeel,
  encode: _encodePlaybackFeel,
);

const DeviceJsonSettingKey<({double volume, bool muted})>
kPlaybackVolumeStateKey = DeviceJsonSettingKey(
  kPlaybackVolumeStateKeyName,
  (volume: kDefaultPlaybackVolume, muted: kDefaultPlaybackMuted),
  decode: _decodePlaybackVolume,
  encode: _encodePlaybackVolume,
);

const DeviceSettingKey<double> kPlaybackVolumeKey = DeviceSettingKey(
  kPlaybackVolumeKeyName,
  kDefaultPlaybackVolume,
);
const DeviceSettingKey<bool> kPlaybackMutedKey = DeviceSettingKey(
  kPlaybackMutedKeyName,
  kDefaultPlaybackMuted,
);
const DeviceSettingKey<bool> kOnboardingCompletedKey = DeviceSettingKey(
  kOnboardingCompletedKeyName,
  false,
);

// ---------------------------------------------------------------------------
// 触感（设备能力）
// ---------------------------------------------------------------------------

/// 触感反馈总开关。
const String kHapticsEnabledKeyName = 'haptics_enabled';
const bool kDefaultHapticsEnabled = true;
const DeviceSettingKey<bool> kHapticsEnabledKey = DeviceSettingKey(
  kHapticsEnabledKeyName,
  kDefaultHapticsEnabled,
);

// ---------------------------------------------------------------------------
// 下载（本机路径 / 平台能力）
// ---------------------------------------------------------------------------

/// 下载保存目录、文件名模板、标签嵌入、公共目录发布与下载通知。
const String kDownloadSaveDirKeyName = 'download_save_dir';
const String kDownloadFilenameTemplateKeyName = 'download_filename_template';
const String kDownloadEmbedTagsKeyName = 'download_embed_tags';
const String kDownloadPublishPublicDirKeyName = 'download_publish_public_dir';
const String kDownloadNotificationsKeyName = 'download_notifications';

/// 默认文件名模板：`{artist} - {title}`（无歌手时只留歌名）。
const String kDefaultDownloadFilenameTemplate = '{artist} - {title}';

const DeviceSettingKey<String> kDownloadSaveDirKey = DeviceSettingKey(
  kDownloadSaveDirKeyName,
  '',
);
const DeviceSettingKey<String> kDownloadFilenameTemplateKey = DeviceSettingKey(
  kDownloadFilenameTemplateKeyName,
  kDefaultDownloadFilenameTemplate,
);
const DeviceSettingKey<bool> kDownloadEmbedTagsKey = DeviceSettingKey(
  kDownloadEmbedTagsKeyName,
  true,
);
const DeviceSettingKey<bool> kDownloadPublishPublicDirKey = DeviceSettingKey(
  kDownloadPublishPublicDirKeyName,
  true,
);
const DeviceSettingKey<bool> kDownloadNotificationsKey = DeviceSettingKey(
  kDownloadNotificationsKeyName,
  true,
);

// ---------------------------------------------------------------------------
// 缓存策略（容量相关，缺键时按设备容量建议上限）
// ---------------------------------------------------------------------------

const String kCacheAudioEnabledKeyName = 'cache_audio_enabled';
const String kCacheAudioMaxMbKeyName = 'cache_audio_max_mb';
const String kCacheLyricsTtlDaysKeyName = 'cache_lyrics_ttl_days';
const String kCacheArtworkMaxObjectsKeyName = 'cache_artwork_max_objects';
const String kCacheArtworkStaleDaysKeyName = 'cache_artwork_stale_days';

const bool kDefaultCacheAudioEnabled = true;

/// 容量不可知（设备容量通道不可用 / 查询失败）时的音频上限回退值（MB）。
const int kDefaultCacheAudioMaxMb = 1024;
const int kDefaultCacheLyricsTtlDays = 30;
const int kDefaultCacheArtworkMaxObjects = 1500;
const int kDefaultCacheArtworkStaleDays = 365;

const DeviceSettingKey<bool> kCacheAudioEnabledKey = DeviceSettingKey(
  kCacheAudioEnabledKeyName,
  kDefaultCacheAudioEnabled,
);
const DeviceSettingKey<int> kCacheAudioMaxMbKey = DeviceSettingKey(
  kCacheAudioMaxMbKeyName,
  kDefaultCacheAudioMaxMb,
);
const DeviceSettingKey<int> kCacheLyricsTtlDaysKey = DeviceSettingKey(
  kCacheLyricsTtlDaysKeyName,
  kDefaultCacheLyricsTtlDays,
);
const DeviceSettingKey<int> kCacheArtworkMaxObjectsKey = DeviceSettingKey(
  kCacheArtworkMaxObjectsKeyName,
  kDefaultCacheArtworkMaxObjects,
);
const DeviceSettingKey<int> kCacheArtworkStaleDaysKey = DeviceSettingKey(
  kCacheArtworkStaleDaysKeyName,
  kDefaultCacheArtworkStaleDays,
);

// ---------------------------------------------------------------------------
// 省流（移动网络）
// ---------------------------------------------------------------------------

const String kDataSaverEnabledKeyName = 'data_saver_enabled';
const String kDataSaverQualityKeyName = 'data_saver_quality';
const String kDataSaverCoversKeyName = 'data_saver_covers';

const bool kDefaultDataSaverEnabled = false;
const String kDefaultDataSaverQuality = '128k';
const bool kDefaultDataSaverCovers = true;

const DeviceSettingKey<bool> kDataSaverEnabledKey = DeviceSettingKey(
  kDataSaverEnabledKeyName,
  kDefaultDataSaverEnabled,
);
const DeviceSettingKey<String> kDataSaverQualityKey = DeviceSettingKey(
  kDataSaverQualityKeyName,
  kDefaultDataSaverQuality,
);
const DeviceSettingKey<bool> kDataSaverCoversKey = DeviceSettingKey(
  kDataSaverCoversKeyName,
  kDefaultDataSaverCovers,
);

// ---------------------------------------------------------------------------
// 应用内更新（安装渠道）
// ---------------------------------------------------------------------------

const String kUpdateAutoCheckKeyName = 'update_auto_check';
const String kUpdateChannelKeyName = 'update_channel';
const String kUpdateManifestOverrideKeyName = 'update_manifest_override';
const String kUpdateDownloadPrefixKeyName = 'update_download_prefix';
const String kUpdateLastCheckAtKeyName = 'update_last_check_at';
const String kUpdatePendingVersionKeyName = 'update_pending_version';
const String kUpdatePendingBuildKeyName = 'update_pending_build';

/// 自动检查默认关闭：更新是低频行为，且桌面端会自动替换文件。
const bool kDefaultUpdateAutoCheck = false;

/// 更新渠道缺键回稳定版；未知值同样由 `UpdateChannel.fromWire` 回退。
const String kDefaultUpdateChannelWireName = 'stable';
const String kDefaultUpdateText = '';
const int kDefaultUpdateLastCheckAt = 0;
const int kDefaultUpdatePendingBuild = 0;

const DeviceSettingKey<bool> kUpdateAutoCheckKey = DeviceSettingKey(
  kUpdateAutoCheckKeyName,
  kDefaultUpdateAutoCheck,
);
const DeviceSettingKey<String> kUpdateChannelKey = DeviceSettingKey(
  kUpdateChannelKeyName,
  kDefaultUpdateChannelWireName,
);
const DeviceSettingKey<String> kUpdateManifestOverrideKey = DeviceSettingKey(
  kUpdateManifestOverrideKeyName,
  kDefaultUpdateText,
);
const DeviceSettingKey<String> kUpdateDownloadPrefixKey = DeviceSettingKey(
  kUpdateDownloadPrefixKeyName,
  kDefaultUpdateText,
);
const DeviceSettingKey<int> kUpdateLastCheckAtKey = DeviceSettingKey(
  kUpdateLastCheckAtKeyName,
  kDefaultUpdateLastCheckAt,
);
const DeviceSettingKey<String> kUpdatePendingVersionKey = DeviceSettingKey(
  kUpdatePendingVersionKeyName,
  kDefaultUpdateText,
);
const DeviceSettingKey<int> kUpdatePendingBuildKey = DeviceSettingKey(
  kUpdatePendingBuildKeyName,
  kDefaultUpdatePendingBuild,
);

// ---------------------------------------------------------------------------
// 窗口 / 托盘（屏幕与桌面平台）
// ---------------------------------------------------------------------------

const String kTrayCloseToTrayKeyName = 'tray_close_to_tray';
const String kWindowRememberBoundsKeyName = 'window_remember_bounds';
const String kWindowMaximizedKeyName = 'window_maximized';
const String kWindowBoundsKeyName = 'window_bounds';
const String kWindowBoundsByDesktopKeyName = 'window_bounds_by_desktop';
const String kWindowMaximizedByDesktopKeyName = 'window_maximized_by_desktop';

/// 旧版四键：只读兜底，新键缺失时才读。
const String kLegacyWindowBoundsXKeyName = 'window_bounds_x';
const String kLegacyWindowBoundsYKeyName = 'window_bounds_y';
const String kLegacyWindowBoundsWidthKeyName = 'window_bounds_width';
const String kLegacyWindowBoundsHeightKeyName = 'window_bounds_height';

const bool kDefaultTrayCloseToTray = true;
const bool kDefaultWindowRememberBounds = true;
const bool kDefaultWindowMaximized = false;

/// 按虚拟桌面分组的几何；`savedAt` 用于淘汰最久未用的桌面。
typedef WindowDesktopBounds = ({Rect bounds, int savedAt});
typedef WindowDesktopMaximized = ({bool maximized, int savedAt});

const DeviceSettingKey<bool> kTrayCloseToTrayKey = DeviceSettingKey(
  kTrayCloseToTrayKeyName,
  kDefaultTrayCloseToTray,
);
const DeviceSettingKey<bool> kWindowRememberBoundsKey = DeviceSettingKey(
  kWindowRememberBoundsKeyName,
  kDefaultWindowRememberBounds,
);
const DeviceSettingKey<bool> kWindowMaximizedKey = DeviceSettingKey(
  kWindowMaximizedKeyName,
  kDefaultWindowMaximized,
);

Rect? _decodeWindowBounds(Map<String, dynamic> json) {
  final x = json['x'];
  final y = json['y'];
  final width = json['w'];
  final height = json['h'];
  if (x is! num || y is! num || width is! num || height is! num) return null;
  final bounds = Rect.fromLTWH(
    x.toDouble(),
    y.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );
  if (!bounds.isFinite || bounds.width <= 0 || bounds.height <= 0) return null;
  return bounds;
}

Map<String, Object?> _encodeWindowBounds(Rect bounds) => {
  'x': bounds.left,
  'y': bounds.top,
  'w': bounds.width,
  'h': bounds.height,
};

Map<String, WindowDesktopBounds>? _decodeWindowBoundsByDesktop(
  Map<String, dynamic> json,
) {
  final result = <String, WindowDesktopBounds>{};
  for (final entry in json.entries) {
    final value = entry.value;
    if (entry.key.isEmpty || value is! Map<String, dynamic>) continue;
    final bounds = _decodeWindowBounds(value);
    if (bounds == null) continue;
    final savedAt = value['savedAt'];
    result[entry.key] = (
      bounds: bounds,
      savedAt: savedAt is num ? savedAt.toInt() : 0,
    );
  }
  return result;
}

Map<String, Object?> _encodeWindowBoundsByDesktop(
  Map<String, WindowDesktopBounds> value,
) => {
  for (final entry in value.entries)
    entry.key: {
      ..._encodeWindowBounds(entry.value.bounds),
      'savedAt': entry.value.savedAt,
    },
};

Map<String, WindowDesktopMaximized>? _decodeWindowMaximizedByDesktop(
  Map<String, dynamic> json,
) {
  final result = <String, WindowDesktopMaximized>{};
  for (final entry in json.entries) {
    final value = entry.value;
    if (entry.key.isEmpty || value is! Map<String, dynamic>) continue;
    final maximized = value['maximized'];
    if (maximized is! bool) continue;
    final savedAt = value['savedAt'];
    result[entry.key] = (
      maximized: maximized,
      savedAt: savedAt is num ? savedAt.toInt() : 0,
    );
  }
  return result;
}

Map<String, Object?> _encodeWindowMaximizedByDesktop(
  Map<String, WindowDesktopMaximized> value,
) => {
  for (final entry in value.entries)
    entry.key: {
      'maximized': entry.value.maximized,
      'savedAt': entry.value.savedAt,
    },
};

const DeviceJsonSettingKey<Rect> kWindowBoundsKey = DeviceJsonSettingKey(
  kWindowBoundsKeyName,
  Rect.zero,
  decode: _decodeWindowBounds,
  encode: _encodeWindowBounds,
);
const DeviceJsonSettingKey<Map<String, WindowDesktopBounds>>
kWindowBoundsByDesktopKey = DeviceJsonSettingKey(
  kWindowBoundsByDesktopKeyName,
  <String, WindowDesktopBounds>{},
  decode: _decodeWindowBoundsByDesktop,
  encode: _encodeWindowBoundsByDesktop,
);
const DeviceJsonSettingKey<Map<String, WindowDesktopMaximized>>
kWindowMaximizedByDesktopKey = DeviceJsonSettingKey(
  kWindowMaximizedByDesktopKeyName,
  <String, WindowDesktopMaximized>{},
  decode: _decodeWindowMaximizedByDesktop,
  encode: _encodeWindowMaximizedByDesktop,
);

const DeviceSettingKey<double> kLegacyWindowBoundsXKey = DeviceSettingKey(
  kLegacyWindowBoundsXKeyName,
  0,
);
const DeviceSettingKey<double> kLegacyWindowBoundsYKey = DeviceSettingKey(
  kLegacyWindowBoundsYKeyName,
  0,
);
const DeviceSettingKey<double> kLegacyWindowBoundsWidthKey = DeviceSettingKey(
  kLegacyWindowBoundsWidthKeyName,
  0,
);
const DeviceSettingKey<double> kLegacyWindowBoundsHeightKey = DeviceSettingKey(
  kLegacyWindowBoundsHeightKeyName,
  0,
);

// ---------------------------------------------------------------------------
// 曲库 UI 状态 / 本地音乐文件夹
// ---------------------------------------------------------------------------

const String kLibraryBrowseModeKeyName = 'library_browse_mode_v1';
const String kPlaylistFolderCollapsedKeyName = 'playlist_folder_collapsed_v1';
const String kMusicFoldersKeyName = 'music_folders_v1';

/// 曲库默认浏览专辑；未知值由 store 回退到这里。
const String kDefaultLibraryBrowseModeName = 'albums';

const DeviceSettingKey<String> kLibraryBrowseModeKey = DeviceSettingKey(
  kLibraryBrowseModeKeyName,
  kDefaultLibraryBrowseModeName,
);
const DeviceSettingKey<List<String>> kPlaylistFolderCollapsedKey =
    DeviceSettingKey(kPlaylistFolderCollapsedKeyName, <String>[]);
Object? _encodeMusicFolder(MusicFolder folder) => folder.toJson();

const DeviceJsonListSettingKey<MusicFolder> kMusicFoldersKey =
    DeviceJsonListSettingKey(
      kMusicFoldersKeyName,
      <MusicFolder>[],
      decode: MusicFolder.fromJson,
      encode: _encodeMusicFolder,
    );

// ---------------------------------------------------------------------------
// 听歌同步（设备本地开关 / 同意 / 账号；凭证走 secure 盒）
// ---------------------------------------------------------------------------

const String kScrobbleMasterEnabledKeyName = 'scrobble_master_enabled_v1';
const String kScrobbleListenBrainzEnabledKeyName =
    'scrobble_listenbrainz_enabled_v1';
const String kScrobbleLastFmEnabledKeyName = 'scrobble_lastfm_enabled_v1';
const String kScrobbleListenBrainzConsentKeyName =
    'scrobble_listenbrainz_consent_v1';
const String kScrobbleLastFmConsentKeyName = 'scrobble_lastfm_consent_v1';
const String kScrobbleListenBrainzAccountKeyName =
    'scrobble_listenbrainz_account_v1';
const String kScrobbleLastFmAccountKeyName = 'scrobble_lastfm_account_v1';

/// 默认关闭：另一台设备同步凭证也不能悄悄开始上报。
const bool kDefaultScrobbleEnabled = false;
const int kDefaultScrobbleConsentVersion = 0;
const String kDefaultScrobbleAccount = '';

const DeviceSettingKey<bool> kScrobbleMasterEnabledKey = DeviceSettingKey(
  kScrobbleMasterEnabledKeyName,
  kDefaultScrobbleEnabled,
);
const DeviceSettingKey<bool> kScrobbleListenBrainzEnabledKey = DeviceSettingKey(
  kScrobbleListenBrainzEnabledKeyName,
  kDefaultScrobbleEnabled,
);
const DeviceSettingKey<bool> kScrobbleLastFmEnabledKey = DeviceSettingKey(
  kScrobbleLastFmEnabledKeyName,
  kDefaultScrobbleEnabled,
);
const DeviceSettingKey<int> kScrobbleListenBrainzConsentKey = DeviceSettingKey(
  kScrobbleListenBrainzConsentKeyName,
  kDefaultScrobbleConsentVersion,
);
const DeviceSettingKey<int> kScrobbleLastFmConsentKey = DeviceSettingKey(
  kScrobbleLastFmConsentKeyName,
  kDefaultScrobbleConsentVersion,
);
const DeviceSettingKey<String> kScrobbleListenBrainzAccountKey =
    DeviceSettingKey(
      kScrobbleListenBrainzAccountKeyName,
      kDefaultScrobbleAccount,
    );
const DeviceSettingKey<String> kScrobbleLastFmAccountKey = DeviceSettingKey(
  kScrobbleLastFmAccountKeyName,
  kDefaultScrobbleAccount,
);

// ---------------------------------------------------------------------------
// 全局应用字体（本机已装字体）
// ---------------------------------------------------------------------------

const String kAppFontFamilyKeyName = 'app_font_family';

const DeviceSettingKey<String> kAppFontFamilyKey = DeviceSettingKey(
  kAppFontFamilyKeyName,
  '',
);

/// 已迁移的设备本地键（顺序即登记顺序；唯一性由测试核对）。
const List<DeviceSettingEntry> kDeviceSettingsKeys = [
  kPlaybackFeelStateKey,
  kPlaybackVolumeStateKey,
  kPlaybackVolumeKey,
  kPlaybackMutedKey,
  kOnboardingCompletedKey,
  kHapticsEnabledKey,
  kDownloadSaveDirKey,
  kDownloadFilenameTemplateKey,
  kDownloadEmbedTagsKey,
  kDownloadPublishPublicDirKey,
  kDownloadNotificationsKey,
  kCacheAudioEnabledKey,
  kCacheAudioMaxMbKey,
  kCacheLyricsTtlDaysKey,
  kCacheArtworkMaxObjectsKey,
  kCacheArtworkStaleDaysKey,
  kDataSaverEnabledKey,
  kDataSaverQualityKey,
  kDataSaverCoversKey,
  kUpdateAutoCheckKey,
  kUpdateChannelKey,
  kUpdateManifestOverrideKey,
  kUpdateDownloadPrefixKey,
  kUpdateLastCheckAtKey,
  kUpdatePendingVersionKey,
  kUpdatePendingBuildKey,
  kTrayCloseToTrayKey,
  kWindowRememberBoundsKey,
  kWindowMaximizedKey,
  kWindowBoundsKey,
  kWindowBoundsByDesktopKey,
  kWindowMaximizedByDesktopKey,
  kLegacyWindowBoundsXKey,
  kLegacyWindowBoundsYKey,
  kLegacyWindowBoundsWidthKey,
  kLegacyWindowBoundsHeightKey,
  kLibraryBrowseModeKey,
  kPlaylistFolderCollapsedKey,
  kMusicFoldersKey,
  kScrobbleMasterEnabledKey,
  kScrobbleListenBrainzEnabledKey,
  kScrobbleLastFmEnabledKey,
  kScrobbleListenBrainzConsentKey,
  kScrobbleLastFmConsentKey,
  kScrobbleListenBrainzAccountKey,
  kScrobbleLastFmAccountKey,
  kAppFontFamilyKey,
];
