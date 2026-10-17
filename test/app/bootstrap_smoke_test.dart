/// 组合根 stack builders 的冒烟测试：用假依赖调用**可注入**的 builder，
/// 断言「依赖进、装好的对象出」与关键接线。
///
/// 覆盖范围与边界：
/// - `buildCatalogStack` / `buildLocalDataStack` / `buildLibraryStack`：
///   真实对象（只依赖 SharedPreferences mock，不触碰插件）；
/// - `buildPlaybackStack`：注入假后端（`FakePlaybackBackend`）跳过 just_audio，
///   注入 `mediaSessionFactory: null` 跳过系统媒体会话插件；
/// - 真实插件依赖（WindowChrome / 托盘 / 媒体会话 / drift 库）不在本测试内，
///   由端到端集成测试覆盖（`tool/agent/test.sh`）。
///
/// 断言的核心是拆分前需要 `late` / 可变槽位才能表达的三处接线：
/// 歌词服务 ↔ 下载服务（构建顺序）、provider ↔ 观察者、provider ↔ 后端。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/app/bootstrap/catalog_stack.dart';
import 'package:molia/app/bootstrap/library_stack.dart';
import 'package:molia/app/bootstrap/local_data_stack.dart';
import 'package:molia/app/bootstrap/playback_stack.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/download.dart' show kLocalSourceKey;
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/app_branding_service.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/playback_session_store.dart';

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 每个进程只装一次：`LanguageService` / `AppBrandingService` 的 attach
  // 是静态 `late final`（生产里组合根也只跑一次），重复装配会抛已初始化。
  late CatalogStack catalog;
  late Directory tempDir;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('molia_bootstrap_');
    // path_provider 通道替身：drift 库 / 下载存储 / 缓存维护在测试里落到
    // 临时目录（与 test/update/update_downloader_test.dart 同一做法），
    // 组合根的 `unawaited` 启动维护因此与生产同路径执行。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    catalog = buildCatalogStack();
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('catalogStack：设置注册表承接语言/品牌 reload，目录服务同源装配', () async {
    // 键的登记：注册表持有全部登记键。
    expect(catalog.settings.keys.length, kAllSettingsKeys.length);
    expect(
      catalog.settings.keys.map((key) => key.name),
      contains(kSelectedLanguage.name),
    );

    // attach + bindReload 确实把静态服务接到了注册表上（原 main 的两行装配）。
    await catalog.settings.write(kAppDisplayTitle, '测试品牌');
    await catalog.settings.reloadKeys([kAppDisplayTitle.name]);
    expect(AppBrandingService.titleNotifier.value, '测试品牌');

    await catalog.settings.write(kSelectedLanguage, 'en');
    await catalog.settings.reloadKeys([kSelectedLanguage.name]);
    expect(LanguageService.localeNotifier.value, const Locale('en'));

    // 目录 / 评论 / 专辑 / 歌手服务与同一个音源注册表同源装配。
    expect(catalog.sourceRegistry.forTrack(_track()), isNotNull);
    expect(catalog.catalogService, isNotNull);
    expect(catalog.commentsService, isNotNull);
    expect(catalog.albumService, isNotNull);
    expect(catalog.artistService, isNotNull);
  });

  test('localDataStack：歌词服务 → 下载服务的构建顺序，本地离线歌词可取', () async {
    final local = await buildLocalDataStack(catalog: catalog);

    // `payload.lyricPath` 原样读文件（下载时写入的绝对路径），测试无需触网。
    final lyricFile = File('${tempDir.path}/track.lrc')
      ..writeAsStringSync('[00:01.00]离线歌词');
    final translationFile = File('${tempDir.path}/track.t.lrc')
      ..writeAsStringSync('[00:01.00]offline');
    final localTrack = _track(
      sourceKey: kLocalSourceKey,
      origin: TrackOrigin.localFile,
      payload: {
        'lyricPath': lyricFile.path,
        'translationLyricPath': translationFile.path,
      },
    );

    // 歌词服务（先于下载服务构建）经存储读离线歌词：前向引用消失后仍可用。
    final lyrics = await local.lyricsService.getLyrics(
      localTrack.title,
      '歌手',
      localTrack.id.uri,
      track: localTrack,
    );
    expect(lyrics?.lyric, '[00:01.00]离线歌词');
    expect(lyrics?.translation, '[00:01.00]offline');
    expect(lyrics?.provider, kLocalSourceKey);

    // 下载服务的公开入口走同一份实现（读取逻辑抽成存储级函数，不复制）。
    final viaDownload = await local.downloadService.localLyricsFor(localTrack);
    expect(viaDownload?.lyric, lyrics?.lyric);
    expect(viaDownload?.translation, lyrics?.translation);

    // 省流链路与缓存写入器一起装好（取链 / 播放 / 封面共用同一实例）。
    expect(local.dataSaver, isNotNull);
    expect(local.downloadSettings, isNotNull);
    expect(local.audioCacheWriter, isNotNull);
  });

  test('playbackStack：假后端进、facade/provider/观察者出，媒体会话可跳过', () async {
    final local = await buildLocalDataStack(catalog: catalog);
    final library = await buildLibraryStack(catalog: catalog);
    final backend = FakePlaybackBackend();
    final playback = await buildPlaybackStack(
      catalog: catalog,
      local: local,
      library: library,
      messenger: FakeMessenger(),
      // 注入假后端时没有真实本地播放服务，媒体会话 seam 传 null 跳过插件。
      mediaSessionFactory: null,
      backend: backend,
    );

    expect(playback.localPlaybackService, isNull);
    expect(playback.audioHandler, isNull);

    // 依赖进 → 对象出：provider 的快照来自注入的后端（经真实 facade）。
    final track = _track(
      artwork: Artwork(uri: Uri.parse('https://example.com/cover.jpg')),
    );
    backend.emit(BackendSnapshot(
      current: track,
      queue: [track],
      currentIndex: 0,
      duration: const Duration(minutes: 3),
      position: const Duration(seconds: 1),
    ));
    expect(playback.playbackProvider.snapshot.current?.id, track.id);
    expect(playback.facade.snapshot.value.current?.id, track.id);

    // provider 拿到观察者：`flushPlaybackSession` 转发到观察者并落盘会话；
    // 观察者同时挂在同一个 facade 上（最后播放信息同步更新）。
    playback.playbackProvider.flushPlaybackSession();
    await pumpEventQueue();
    final saved = await PlaybackSessionStore().load();
    expect(saved?.current?.id, track.id);
    expect(playback.observer.lastPlayedTrackName, track.title);
  });
}

/// 测试曲目：默认是内置平台曲目（`local` 音源用 [kLocalSourceKey]）。
Track _track({
  String sourceKey = 'kw',
  String id = 'song-1',
  TrackOrigin origin = TrackOrigin.builtin,
  Artwork? artwork,
  Map<String, Object?> payload = const {},
}) {
  return Track(
    id: TrackId(sourceKey, id),
    title: '测试歌曲',
    artists: const [Artist(name: '歌手')],
    duration: const Duration(minutes: 3),
    artwork: artwork,
    origin: origin,
    payload: payload,
  );
}
