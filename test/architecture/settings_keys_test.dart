import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/providers/collection_mode.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:molia/services/artwork_palette_seed_store.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/download/download_settings.dart';
import 'package:molia/services/haptics.dart';
import 'package:molia/services/library/playlist_folder_prefs.dart';
import 'package:molia/services/local/music_folders.dart';
import 'package:molia/services/onboarding_store.dart';
import 'package:molia/services/playback_feel_store.dart';
import 'package:molia/services/playback_volume_store.dart';
import 'package:molia/services/scrobble/scrobble_preferences.dart';
import 'package:molia/services/update/update_preferences.dart';
import 'package:molia/services/window/tray_settings.dart';
import 'package:molia/services/window/window_bounds_store.dart';
import 'package:molia/services/window/window_settings.dart';

/// 「一个键一个家」：登记键的名字字面量只准出现在 `settings_keys.dart`。
///
/// 键名只在 `settings_keys.dart` 定义；组件与同步适配器一律引用登记键，
/// 这条扫描强制它只有一个落脚点（见 ADR-0003 决策 6）。
///
/// 只扫 `'名字'` 形式的字符串字面量：注释里用反引号提及键名是允许的。
void main() {
  test('快捷键四键已登记且跟人走（同步类别 settings）', () {
    const shortcutKeys = <SettingsKey<Object?>>[
      kShortcutsEnabled,
      kGlobalShortcutsEnabled,
      kShortcutBindings,
      kGlobalShortcutBindings,
    ];

    for (final key in shortcutKeys) {
      expect(
        kAllSettingsKeys,
        contains(key),
        reason: '${key.name} 必须在登记键总表里，否则永远不会同步',
      );
      expect(
        key.category,
        SyncCategory.settings,
        reason: '${key.name} 是跟人走的快捷键配置',
      );
    }
  });

  test('海报样式三键已登记且跟人走（同步类别 settings）', () {
    const posterKeys = <SettingsKey<Object?>>[
      kPosterColorSourceKey,
      kPosterSeedColor,
      kPosterFontFamily,
    ];

    for (final key in posterKeys) {
      expect(
        kAllSettingsKeys,
        contains(key),
        reason: '${key.name} 必须在登记键总表里，否则换设备会丢海报样式',
      );
      expect(
        key.category,
        SyncCategory.settings,
        reason: '${key.name} 是跟人走的海报外观偏好',
      );
    }
  });

  test('登记键名在 lib/ 中只出现在 settings_keys.dart', () {
    final files = _libFiles();
    expect(files, contains('lib/main.dart'), reason: '确认扫描到了 lib/**');

    final violations = <String>[];
    for (final key in kAllSettingsKeys) {
      final literal = "'${key.name}'";
      for (final path in files) {
        if (path == 'lib/data/settings/settings_keys.dart') continue;
        if (File(path).readAsStringSync().contains(literal)) {
          violations.add('$path 出现 $literal');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          '登记键名只能在 lib/data/settings/settings_keys.dart 声明：\n'
          '${violations.join('\n')}',
    );
  });

  test('听歌同步的开关 / 同意标记不进登记表（设备本地）', () {
    final registered = kAllSettingsKeys.map((key) => key.name).toSet();
    const deviceLocal = [
      ScrobblePreferences.keyMasterEnabled,
      ScrobblePreferences.keyListenBrainzEnabled,
      ScrobblePreferences.keyLastFmEnabled,
      ScrobblePreferences.keyListenBrainzConsent,
      ScrobblePreferences.keyLastFmConsent,
      ScrobblePreferences.keyListenBrainzAccount,
      ScrobblePreferences.keyLastFmAccount,
    ];
    for (final name in deviceLocal) {
      expect(
        registered,
        isNot(contains(name)),
        reason: '$name 是设备本地决策，不能被同步 / 备份改写',
      );
    }
  });

  test('首次引导完成标记不进登记表（设备本地）', () {
    expect(
      kAllSettingsKeys.map((key) => key.name),
      isNot(contains(kOnboardingCompletedV1)),
      reason: '同步 / 备份不能替用户跳过或重新触发引导',
    );
  });

  test('听歌同步凭证是凭证类别的凭据键', () {
    for (final key in [kListenBrainzToken, kLastFmSessionKey]) {
      expect(kAllSettingsKeys, contains(key));
      expect(key.category, SyncCategory.credentials);
      expect(key.store, SettingsValueStore.secure);
    }
  });

  test('设备本地偏好不登记：同步 / 备份不覆盖设备能力与 UI 状态', () {
    final registered = kAllSettingsKeys.map((key) => key.name).toSet();
    final deviceLocal = <String, String>{
      PlaybackFeelStore.keyState: '播放手感（听感随设备）',
      PlaybackVolumeStore.keyState: '音量（随设备）',
      HapticsService.keyEnabled: '触感（设备能力）',
      CacheService.keyAudioEnabled: '缓存策略（容量）',
      DataSaverService.keyEnabled: '省流（网络）',
      DownloadSettings.keySaveDir: '下载目录（本机文件）',
      MusicFoldersStore.prefsKey: '本地曲库文件夹（本机文件）',
      WindowBoundsStore.keyBounds: '窗口位置（屏幕）',
      WindowBoundsStore.keyMaximized: '窗口最大化（屏幕）',
      WindowSettings.keyRememberBounds: '窗口记忆开关（屏幕）',
      TraySettings.keyCloseToTray: '关闭到托盘（桌面平台）',
      UpdatePreferences.keyAutoCheck: '更新检查（安装渠道）',
      AiRecommendationStore.indexKey: 'AI 推荐历史（整批 LWW 会互相覆盖）',
      CollectionModeStore.prefsKey: '曲库浏览模式（UI 状态）',
      LibraryCollections.orderKey: '合集顺序（UI 状态）',
      PlaylistFolderCollapseController.prefsKey: '分组折叠（UI 状态）',
      ArtworkPaletteSeedStore.storageKey: '封面取色缓存（可重算）',
    };
    for (final entry in deviceLocal.entries) {
      expect(
        registered,
        isNot(contains(entry.key)),
        reason: '${entry.key}（${entry.value}）应留在设备本地，不进同步 / 备份',
      );
    }
  });

  test('登记键名唯一', () {
    final names = kAllSettingsKeys.map((key) => key.name).toSet();
    expect(names.length, kAllSettingsKeys.length);
  });
}

List<String> _libFiles() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path)
        .where((path) => path.endsWith('.dart'))
        .toList();
