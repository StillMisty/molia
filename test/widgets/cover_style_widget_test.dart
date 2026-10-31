import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// 测试用内存 CacheManager，不触网、不落盘、不排清理计时器。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/cover_style.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/covers/cover_style_cache.dart';
import 'package:molia/services/covers/cover_style_processor.dart';
import 'package:molia/services/covers/cover_style_settings.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/cover_style_sheet.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:molia/widgets/styled_cover_image.dart';
import 'package:molia/widgets/track_artwork.dart';

import '../support/fakes.dart';
import '../support/memory_cache_storage.dart';
import '../support/settings_test_support.dart';

Uint8List _png(int shade) {
  final source = image.Image(width: 8, height: 8);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      source.setPixelRgb(x, y, shade, shade, shade);
    }
  }
  return Uint8List.fromList(image.encodePng(source));
}

class _OfflineCacheManager extends CacheManager {
  _OfflineCacheManager()
    : super(
        Config(
          'cover_style_offline',
          repo: NonStoringObjectProvider(),
          fileSystem: MemoryCacheSystem(),
          fileService: HttpFileService(),
        ),
      );

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    throw Exception('offline');
  }
}

/// 原样返回 PNG 的处理器：测试只验证接线，不重复跑像素算法。
class _PassThroughProcessor implements CoverStyleProcessorPort {
  @override
  Future<Uint8List?> process(
    Uint8List source, {
    required CoverStyle style,
    required int edge,
  }) async => source;
}

CoverStyleCache _fakeCache() => CoverStyleCache(
  processor: _PassThroughProcessor(),
  sourceLoader: (_) async => _png(120),
);

Future<CoverStyleSettings> _settings({
  CoverStyle style = CoverStyle.original,
  CoverStyleScope scope = CoverStyleScope.player,
}) async {
  final registry = testSettingsRegistry();
  await registry.write(kCoverStyle, style.id);
  await registry.write(kCoverStyleScope, scope.id);
  final settings = CoverStyleSettings(
    settings: registry.scope([kCoverStyle, kCoverStyleScope]),
  );
  await settings.init();
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zh = lookupAppLocalizations(const Locale('zh'));

  final track = Track(
    id: const TrackId('kw', 'a'),
    title: 'Title',
    origin: TrackOrigin.builtin,
    artwork: Artwork(uri: Uri.parse('https://img.example/original.jpg')),
  );

  late Directory tempDir;
  late CustomCoverStore store;
  late ArtworkCache artworkCache;
  late String previewFileUrl;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('molia_cover_style_');
    store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    CustomCoverStore.overrideInstance(store);
    artworkCache = ArtworkCache(
      cacheService: CacheService(storage: MemoryCacheStorage()),
      managerOverride: _OfflineCacheManager(),
    );
    await store.load();
    final preview = File('${tempDir.path}/preview.png');
    await preview.writeAsBytes(_png(80));
    previewFileUrl = Uri.file(preview.path).toString();
  });

  tearDown(() async {
    CustomCoverStore.overrideInstance(null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget host(
    Widget child, {
    CoverStyleSettings? settings,
    CoverStyleCache? cache,
  }) {
    return MaterialApp(
      home: MultiProvider(
        providers: [
          Provider<CustomCoverStore>.value(value: store),
          if (settings != null)
            ChangeNotifierProvider<CoverStyleSettings>.value(value: settings),
          if (cache != null)
            ChangeNotifierProvider<CoverStyleCache>.value(value: cache),
        ],
        child: Scaffold(body: Center(child: child)),
      ),
    );
  }

  group('TrackArtwork 风格接线', () {
    testWidgets('scope=player 保持原图路径', (tester) async {
      final settings = await _settings(
        style: CoverStyle.lineArt,
        scope: CoverStyleScope.player,
      );
      await tester.pumpWidget(
        host(
          TrackArtwork(
            track: track,
            size: 44,
            artworkCache: artworkCache,
            coverStyleCache: _fakeCache(),
          ),
          settings: settings,
          cache: _fakeCache(),
        ),
      );
      expect(find.byType(StyledCoverImage), findsNothing);
      final image = tester.widget<AppNetworkImage>(
        find.byType(AppNetworkImage),
      );
      expect(image.url, track.artwork!.uri.toString());
    });

    testWidgets('scope=all 使用选定风格', (tester) async {
      final settings = await _settings(
        style: CoverStyle.lineArt,
        scope: CoverStyleScope.all,
      );
      await tester.pumpWidget(
        host(
          TrackArtwork(
            track: track,
            size: 44,
            artworkCache: artworkCache,
            coverStyleCache: _fakeCache(),
          ),
          settings: settings,
          cache: _fakeCache(),
        ),
      );
      final styled = tester.widget<StyledCoverImage>(
        find.byType(StyledCoverImage),
      );
      expect(styled.style, CoverStyle.lineArt);
    });

    testWidgets('applyCoverStyle=false 的非展示面保持原图', (tester) async {
      final settings = await _settings(
        style: CoverStyle.ink,
        scope: CoverStyleScope.all,
      );
      await tester.pumpWidget(
        host(
          TrackArtwork(
            track: track,
            size: 44,
            applyCoverStyle: false,
            artworkCache: artworkCache,
            coverStyleCache: _fakeCache(),
          ),
          settings: settings,
          cache: _fakeCache(),
        ),
      );
      expect(find.byType(StyledCoverImage), findsNothing);
    });

    testWidgets('Provider 缺失回退原图', (tester) async {
      await tester.pumpWidget(
        host(
          TrackArtwork(
            track: track,
            size: 44,
            artworkCache: artworkCache,
            coverStyleCache: _fakeCache(),
          ),
        ),
      );
      expect(find.byType(StyledCoverImage), findsNothing);
      expect(find.byType(AppNetworkImage), findsOneWidget);
    });
  });

  group('PlayerCoverDeck 风格接线', () {
    testWidgets('中心与左右邻位都使用当前风格（scope=player 也生效）', (tester) async {
      final backend = FakePlaybackBackend();
      final playback = buildTestPlaybackProvider(backend: backend);
      addTearDown(playback.dispose);
      final previous = Track(
        id: const TrackId('kw', 'prev'),
        title: 'Previous',
        origin: TrackOrigin.builtin,
        artwork: Artwork(uri: Uri.parse('https://img.example/prev.jpg')),
      );
      final next = Track(
        id: const TrackId('kw', 'next'),
        title: 'Next',
        origin: TrackOrigin.builtin,
        artwork: Artwork(uri: Uri.parse('https://img.example/next.jpg')),
      );
      backend.emit(
        BackendSnapshot(
          current: track,
          queue: [previous, track, next],
          currentIndex: 1,
          next: next,
          previous: previous,
          isPlaying: true,
          position: const Duration(seconds: 3),
          duration: const Duration(seconds: 30),
        ),
      );
      final settings = await _settings(
        style: CoverStyle.pencil,
        scope: CoverStyleScope.player,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
              ChangeNotifierProvider<CoverStyleSettings>.value(value: settings),
              ChangeNotifierProvider<CoverStyleCache>.value(
                value: _fakeCache(),
              ),
              Provider<CustomCoverStore>.value(value: store),
            ],
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  height: 260,
                  child: PlayerCoverDeck(
                    displayTrack: track,
                    artDimension: 240,
                    stackDimension: 360,
                    stackHeight: 254.4,
                    fullCoverKey: GlobalKey(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final styled = tester.widgetList<StyledCoverImage>(
        find.byType(StyledCoverImage),
      );
      expect(styled.length, greaterThanOrEqualTo(3));
      expect(styled.every((item) => item.style == CoverStyle.pencil), isTrue);
    });

    testWidgets('Provider 缺失回退原图', (tester) async {
      final playback = buildTestPlaybackProvider();
      addTearDown(playback.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
              Provider<CustomCoverStore>.value(value: store),
            ],
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  height: 260,
                  child: PlayerCoverDeck(
                    displayTrack: track,
                    artDimension: 240,
                    stackDimension: 360,
                    stackHeight: 254.4,
                    fullCoverKey: GlobalKey(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(StyledCoverImage), findsNothing);
    });
  });

  group('封面风格弹层', () {
    Future<CoverStyleSheet> pumpSheet(
      WidgetTester tester,
      CoverStyleSettings settings, {
      String? previewUrl,
    }) async {
      final themedData = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      );
      final sheet = CoverStyleSheet(
        settings: settings,
        cache: _fakeCache(),
        previewUrl: previewUrl,
      );
      await tester.pumpWidget(
        M3EMaterialApp(
          data: M3EThemeData.fromMaterial(themedData),
          theme: themedData,
          darkTheme: themedData,
          autoTheming: false,
          dynamicColoring: false,
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(body: SizedBox(height: 800, child: sheet)),
        ),
      );
      await tester.pump();
      return sheet;
    }

    Future<void> pumpLauncher(
      WidgetTester tester,
      CoverStyleSettings settings,
      PlaybackProvider playback,
    ) async {
      final themedData = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      );
      await tester.pumpWidget(
        // Provider 必须包在 MaterialApp 外层（与生产组合根一致），弹层的
        // root overlay 才能读到 PlaybackProvider 并跟随切歌。
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
            ChangeNotifierProvider<CoverStyleSettings>.value(value: settings),
            ChangeNotifierProvider<CoverStyleCache>.value(value: _fakeCache()),
            Provider<CustomCoverStore>.value(value: store),
          ],
          child: M3EMaterialApp(
            data: M3EThemeData.fromMaterial(themedData),
            theme: themedData,
            darkTheme: themedData,
            autoTheming: false,
            dynamicColoring: false,
            locale: const Locale('zh'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: const [Locale('zh')],
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: M3EButton.filled(
                    key: const Key('openCoverStyleSheet'),
                    onPressed: () => unawaited(showCoverStyleSheet(context)),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('选择风格 / 切换范围立即写入，卡片保持选中', (tester) async {
      final settings = await _settings();
      await pumpSheet(tester, settings, previewUrl: previewFileUrl);

      expect(find.byKey(const Key('coverStyleGrid')), findsOneWidget);
      for (final style in CoverStyle.values) {
        expect(
          find.byKey(Key('coverStyleCard_${style.id}')),
          findsOneWidget,
          reason: style.id,
        );
      }

      final playerDescription = tester.widget<Text>(
        find.byKey(const Key('coverStyleScopeDescription_player')),
      );
      final allDescription = tester.widget<Text>(
        find.byKey(const Key('coverStyleScopeDescription_all')),
      );
      expect(find.text(zh.coverStyleScopePlayerSubtitle), findsOneWidget);
      expect(find.text(zh.coverStyleScopeAllSubtitle), findsOneWidget);
      final selectedColor = playerDescription.style!.color;
      final unselectedColor = allDescription.style!.color;
      expect(selectedColor, isNot(unselectedColor));

      // 先切范围：分段控件在网格上方，ensureVisible 滚动到风格卡后会被
      // 滚出视口（点击落到屏幕外）。
      await tester.tap(find.text(zh.coverStyleScopeAll));
      await tester.pump();
      expect(settings.scope, CoverStyleScope.all);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('coverStyleScopeDescription_all')),
            )
            .style!
            .color,
        selectedColor,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('coverStyleScopeDescription_player')),
            )
            .style!
            .color,
        unselectedColor,
      );

      await tester.ensureVisible(
        find.byKey(const Key('coverStyleCard_oneLastKiss')),
      );
      await tester.tap(find.byKey(const Key('coverStyleCard_oneLastKiss')));
      await tester.pump();
      expect(settings.style, CoverStyle.oneLastKiss);
      final selected = tester.widget<M3ECard>(
        find.byKey(const Key('coverStyleCard_oneLastKiss')),
      );
      expect(selected.border?.width, 2);
      expect(find.byType(CoverStyleSheet), findsOneWidget);
    });

    testWidgets('没有可预览封面时显示占位与提示', (tester) async {
      final settings = await _settings();
      await pumpSheet(tester, settings);
      expect(find.byKey(const Key('coverStyleNoPreview')), findsOneWidget);
      expect(find.byKey(const Key('coverStyleCard_original')), findsOneWidget);
    });

    testWidgets('从设置入口打开弹层，完成后关闭', (tester) async {
      final settings = await _settings();
      final playback = buildTestPlaybackProvider();
      addTearDown(playback.dispose);
      await pumpLauncher(tester, settings, playback);
      await tester.tap(find.byKey(const Key('openCoverStyleSheet')));
      await tester.pumpAndSettle();
      expect(find.byType(CoverStyleSheet), findsOneWidget);
      await tester.tap(find.byKey(const Key('coverStyleDone')));
      await tester.pumpAndSettle();
      expect(find.byType(CoverStyleSheet), findsNothing);
    });

    testWidgets('切歌后预览跟随当前曲目', (tester) async {
      final settings = await _settings();
      final backend = FakePlaybackBackend();
      final playback = buildTestPlaybackProvider(backend: backend);
      addTearDown(playback.dispose);
      final nextTrack = Track(
        id: const TrackId('kw', 'b'),
        title: 'Next',
        origin: TrackOrigin.builtin,
        artwork: Artwork(uri: Uri.parse('https://img.example/b.jpg')),
      );
      backend.emit(
        BackendSnapshot(
          current: track,
          queue: [track, nextTrack],
          currentIndex: 0,
          next: nextTrack,
          isPlaying: true,
          position: Duration.zero,
          duration: const Duration(seconds: 30),
        ),
      );
      await pumpLauncher(tester, settings, playback);
      await tester.tap(find.byKey(const Key('openCoverStyleSheet')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CoverStyleSheet>(find.byType(CoverStyleSheet)).previewUrl,
        track.artwork!.uri.toString(),
      );

      backend.emit(
        BackendSnapshot(
          current: nextTrack,
          queue: [track, nextTrack],
          currentIndex: 1,
          previous: track,
          isPlaying: true,
          position: Duration.zero,
          duration: const Duration(seconds: 30),
        ),
      );
      // 快照通知经 PlaybackProvider 的合并节流（~188ms）后落地。
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<CoverStyleSheet>(find.byType(CoverStyleSheet)).previewUrl,
        nextTrack.artwork!.uri.toString(),
      );
    });
  });
}
