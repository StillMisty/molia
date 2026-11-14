import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_access.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/providers/update_provider.dart';
import 'package:molia/services/audio_focus_settings.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/library/library_add_settings.dart';
import 'package:molia/services/lyrics_display/lyrics_output.dart';
import 'package:molia/services/play_statistics_service.dart';
import 'package:molia/services/scrobble/scrobble_service.dart';
import 'package:molia/services/source_swap/source_swap_settings.dart';
import 'package:molia/services/window/tray_settings.dart';
import 'package:molia/widgets/settings/library_storage_section_model.dart';
import 'package:molia/widgets/settings/settings_section_availability.dart';

import '../support/settings_test_support.dart';

/// 设置卡可用性探针：每类可选子系统「在」与「不在」两种取值下的行决定。
///
/// 依赖都用替身：探针只关心 `!= null`，重服务的真实构造与设置页无关。
void main() {
  group('SettingsSectionAvailability', () {
    test('可选服务全部缺省：没有一行依赖它们', () {
      final availability = SettingsSectionAvailability(
        platform: TargetPlatform.android,
      );

      expect(availability.hasDataSaver, isFalse);
      expect(availability.hasSourceSwap, isFalse);
      expect(availability.hasSources, isFalse);
      expect(availability.hasScrobble, isFalse);
      expect(availability.hasLibraryAdd, isFalse);
      expect(availability.hasStatistics, isFalse);
      expect(availability.hasSync, isFalse);
      expect(availability.hasUpdate, isFalse);
      expect(availability.hasNav, isFalse);
      expect(availability.audioFocusRowVisible, isFalse);
      expect(availability.desktopLyricsVisible, isFalse);
      expect(availability.systemMediaLyricsVisible, isFalse);
      expect(availability.noLyricsOutputs, isTrue);
      expect(availability.mediaSessionLyricsHintVisible, isFalse);
      expect(availability.trayRowsVisible, isFalse);
      expect(availability.trayLinuxHintVisible, isFalse);
    });

    test('可选服务齐备：可用性逐项为真', () {
      final availability = _allAvailable(
        platform: TargetPlatform.android,
        traySupported: true,
        lyricsCapabilities: {
          LyricsOutputIds.desktop: LyricsOutputCapability.ready,
          LyricsOutputIds.media: LyricsOutputCapability.needsPermission,
        },
      );

      expect(availability.hasDataSaver, isTrue);
      expect(availability.hasSourceSwap, isTrue);
      expect(availability.hasSources, isTrue);
      expect(availability.hasScrobble, isTrue);
      expect(availability.hasLibraryAdd, isTrue);
      expect(availability.hasStatistics, isTrue);
      expect(availability.hasSync, isTrue);
      expect(availability.hasUpdate, isTrue);
      expect(availability.hasNav, isTrue);
      expect(availability.audioFocusRowVisible, isTrue);
      expect(availability.desktopLyricsVisible, isTrue);
      expect(availability.systemMediaLyricsVisible, isTrue);
      expect(availability.noLyricsOutputs, isFalse);
      expect(availability.trayRowsVisible, isTrue);
    });

    test('音频焦点行只在非桌面平台出现', () {
      expect(
        _allAvailable(platform: TargetPlatform.android).audioFocusRowVisible,
        isTrue,
      );
      expect(
        _allAvailable(platform: TargetPlatform.linux).audioFocusRowVisible,
        isFalse,
      );
    });

    test('音乐文件夹行在 iOS 隐藏', () {
      expect(
        SettingsSectionAvailability(platform: TargetPlatform.iOS)
            .musicFoldersRowVisible,
        isFalse,
      );
      expect(
        SettingsSectionAvailability(platform: TargetPlatform.android)
            .musicFoldersRowVisible,
        isTrue,
      );
    });

    test('歌词入口按输出能力显隐，两路都不可用时给解释', () {
      final desktopOnly = SettingsSectionAvailability(
        platform: TargetPlatform.android,
        lyricsDisplay: _FakeLyricsDisplayProvider(
          capabilities: {LyricsOutputIds.desktop: LyricsOutputCapability.ready},
        ),
      );
      expect(desktopOnly.desktopLyricsVisible, isTrue);
      expect(desktopOnly.systemMediaLyricsVisible, isFalse);
      expect(desktopOnly.noLyricsOutputs, isFalse);
      expect(desktopOnly.mediaSessionLyricsHintVisible, isFalse);

      final unsupported = SettingsSectionAvailability(
        platform: TargetPlatform.android,
        lyricsDisplay: _FakeLyricsDisplayProvider(),
      );
      expect(unsupported.desktopLyricsVisible, isFalse);
      expect(unsupported.systemMediaLyricsVisible, isFalse);
      expect(unsupported.noLyricsOutputs, isTrue);
    });

    test('系统媒体会话初始化失败：支持但给可见提示', () {
      final availability = SettingsSectionAvailability(
        platform: TargetPlatform.android,
        lyricsDisplay: _FakeLyricsDisplayProvider(
          capabilities: {LyricsOutputIds.media: LyricsOutputCapability.ready},
          mediaSessionInitFailed: true,
        ),
      );
      expect(availability.systemMediaLyricsVisible, isTrue);
      expect(availability.mediaSessionLyricsHintVisible, isTrue);

      // 输出端本身不支持时，失败标记不额外提示（否则会提示一个不存在的入口）。
      final unsupported = SettingsSectionAvailability(
        platform: TargetPlatform.android,
        lyricsDisplay: _FakeLyricsDisplayProvider(mediaSessionInitFailed: true),
      );
      expect(unsupported.mediaSessionLyricsHintVisible, isFalse);
    });

    test('托盘行同时需要平台能力与偏好实例', () {
      final tray = TraySettings();
      addTearDown(tray.dispose);

      expect(
        SettingsSectionAvailability(
          platform: TargetPlatform.linux,
          tray: tray,
          traySupported: false,
        ).trayRowsVisible,
        isFalse,
      );
      expect(
        SettingsSectionAvailability(
          platform: TargetPlatform.linux,
          tray: null,
          traySupported: true,
        ).trayRowsVisible,
        isFalse,
      );
      final supported = SettingsSectionAvailability(
        platform: TargetPlatform.linux,
        tray: tray,
        traySupported: true,
      );
      expect(supported.trayRowsVisible, isTrue);
      expect(supported.trayLinuxHintVisible, isTrue);
      expect(
        SettingsSectionAvailability(
          platform: TargetPlatform.windows,
          tray: tray,
          traySupported: true,
        ).trayLinuxHintVisible,
        isFalse,
      );
    });
  });

  group('LibraryStorageSectionModel', () {
    late _MemorySettingsAccess access;
    late LibraryAddSettings addSettings;

    setUp(() async {
      access = _MemorySettingsAccess();
      addSettings = LibraryAddSettings(settings: access);
      await addSettings.init();
    });

    tearDown(() => addSettings.dispose());

    test('值从服务读：加入位置解析持久化值', () async {
      access.values[kLibraryAddPosition.name] = LibraryAddPosition.bottom.name;
      await addSettings.init();

      final model = LibraryStorageSectionModel(
        addSettings: addSettings,
        platform: TargetPlatform.android,
      );
      expect(model.addPositionAvailable, isTrue);
      expect(model.addPosition, LibraryAddPosition.bottom);
    });

    test('写入落到登记键（持久化不搬进模型）', () async {
      final model = LibraryStorageSectionModel(
        addSettings: addSettings,
        platform: TargetPlatform.android,
      );

      await model.setAddPosition(LibraryAddPosition.bottom);

      expect(model.addPosition, LibraryAddPosition.bottom);
      expect(
        access.values[kLibraryAddPosition.name],
        LibraryAddPosition.bottom.name,
      );
    });

    test('重载读回外部写入值（应用远端值后的路径）', () async {
      final model = LibraryStorageSectionModel(
        addSettings: addSettings,
        platform: TargetPlatform.android,
      );
      expect(model.addPosition, LibraryAddPosition.top);

      access.values[kLibraryAddPosition.name] = LibraryAddPosition.bottom.name;
      await model.reload();

      expect(model.addPosition, LibraryAddPosition.bottom);
    });

    test('服务缺省：加入位置行隐藏，读 / 写 / 重载安全', () async {
      final model = LibraryStorageSectionModel(
        addSettings: null,
        platform: TargetPlatform.android,
      );

      expect(model.addPositionAvailable, isFalse);
      expect(model.addPosition, LibraryAddPosition.top);
      expect(model.visibleRows, isNot(contains(LibraryStorageRow.addPosition)));

      await model.setAddPosition(LibraryAddPosition.bottom);
      await model.reload();
      expect(model.addPosition, LibraryAddPosition.top, reason: '缺省时没有可写的家');
    });

    test('行集合与行序：iOS 去掉音乐文件夹，其余入口保持顺序', () {
      const remaining = [
        LibraryStorageRow.addPosition,
        LibraryStorageRow.downloadSettings,
        LibraryStorageRow.downloadsManage,
        LibraryStorageRow.cacheManagement,
      ];

      final ios = LibraryStorageSectionModel(
        addSettings: addSettings,
        platform: TargetPlatform.iOS,
      );
      expect(ios.musicFoldersAvailable, isFalse);
      expect(ios.visibleRows, remaining);

      final android = LibraryStorageSectionModel(
        addSettings: addSettings,
        platform: TargetPlatform.android,
      );
      expect(android.visibleRows, [
        LibraryStorageRow.addPosition,
        LibraryStorageRow.musicFolders,
        ...remaining.skip(1),
      ]);
    });
  });
}

/// 全量可用性快照：只用于断言「都挂上时」的行决定。
SettingsSectionAvailability _allAvailable({
  required TargetPlatform platform,
  bool traySupported = false,
  Map<String, LyricsOutputCapability> lyricsCapabilities = const {},
}) {
  return SettingsSectionAvailability(
    dataSaver: DataSaverService(),
    sourceSwap: SourceSwapSettings(settings: testSettingsRegistry()),
    audioFocus: AudioFocusSettings(settings: testSettingsRegistry()),
    sources: _FakeSourcesProvider(),
    lyricsDisplay: _FakeLyricsDisplayProvider(capabilities: lyricsCapabilities),
    scrobble: _FakeScrobbleService(),
    libraryAdd: LibraryAddSettings(settings: testSettingsRegistry()),
    statistics: _FakePlayStatisticsService(),
    sync: _FakeSyncProvider(),
    tray: TraySettings(),
    update: _FakeUpdateProvider(),
    nav: NavProvider(settings: testSettingsRegistry()),
    platform: platform,
    traySupported: traySupported,
  );
}

/// 内存设置访问面：记录写入并模拟持久化（binding 测试不碰 prefs）。
class _MemorySettingsAccess implements SettingsAccess {
  final Map<String, Object?> values = {};

  @override
  Future<T> read<T extends Object?>(SettingsKey<T> key) async =>
      (values[key.name] ?? key.defaultValue) as T;

  @override
  Future<void> write<T extends Object?>(SettingsKey<T> key, T value) async {
    values[key.name] = value;
  }

  @override
  Future<void> clear(SettingsKey<Object?> key) async {
    values.remove(key.name);
  }
}

/// 探针只关心是否存在；重服务的成员用 noSuchMethod 兜底，避免为一次
/// 「在不在树上」搭真实引擎。
mixin _PresenceOnly {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('可用性探针不应调用 ${invocation.memberName}');
}

class _FakeSyncProvider extends ChangeNotifier
    with _PresenceOnly
    implements SyncProvider {}

class _FakeSourcesProvider extends ChangeNotifier
    with _PresenceOnly
    implements SourcesProvider {}

class _FakeScrobbleService extends ChangeNotifier
    with _PresenceOnly
    implements ScrobbleService {}

class _FakeUpdateProvider extends ChangeNotifier
    with _PresenceOnly
    implements UpdateProvider {}

class _FakePlayStatisticsService
    with _PresenceOnly
    implements PlayStatisticsService {}

class _FakeLyricsDisplayProvider extends ChangeNotifier
    with _PresenceOnly
    implements LyricsDisplayProvider {
  _FakeLyricsDisplayProvider({
    this.capabilities = const {},
    this.mediaSessionInitFailed = false,
  });

  final Map<String, LyricsOutputCapability> capabilities;

  @override
  final bool mediaSessionInitFailed;

  @override
  LyricsOutputCapability capabilityOf(String outputId) =>
      capabilities[outputId] ?? LyricsOutputCapability.unsupported;
}
