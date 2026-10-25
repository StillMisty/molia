import 'dart:io';
import 'dart:typed_data';

// 测试用内存 CacheManager，不触网、不落盘、不排清理计时器。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/track.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/track_artwork.dart';

import '../support/memory_cache_storage.dart';

Uint8List _png(int shade) {
  final source = image.Image(width: 2, height: 2);
  image.fill(source, color: image.ColorRgb8(shade, shade, shade));
  return Uint8List.fromList(image.encodePng(source));
}

class _OfflineCacheManager extends CacheManager {
  _OfflineCacheManager()
      : super(Config(
          'track_artwork_offline',
          repo: NonStoringObjectProvider(),
          fileSystem: MemoryCacheSystem(),
          fileService: HttpFileService(),
        ));

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final track = Track(
    id: const TrackId('kw', 'a'),
    title: 'Title',
    origin: TrackOrigin.builtin,
    artwork: Artwork(uri: Uri.parse('https://img.example/original.jpg')),
  );

  late Directory tempDir;
  late CustomCoverStore store;
  late ArtworkCache artworkCache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('molia_track_artwork_');
    store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    CustomCoverStore.overrideInstance(store);
    // 固定走内存 CacheManager：避免共享单例在未解析时调用 path_provider，
    // 也避免真实缓存清理计时器留在 fake async 里导致用例顺序相关。
    artworkCache = ArtworkCache(
      cacheService: CacheService(storage: MemoryCacheStorage()),
      managerOverride: _OfflineCacheManager(),
    );
    await store.load();
  });

  tearDown(() async {
    CustomCoverStore.overrideInstance(null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget host(Track track) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackArtwork(
              track: track,
              size: 44,
              artworkCache: artworkCache,
            ),
          ),
        ),
      );

  AppNetworkImage imageOf(WidgetTester tester) =>
      tester.widget<AppNetworkImage>(find.byType(AppNetworkImage));

  testWidgets('自定义封面 revision 后自动换图；恢复后回到原始封面', (tester) async {
    await tester.pumpWidget(host(track));
    expect(imageOf(tester).url, 'https://img.example/original.jpg');
    expect(imageOf(tester).fallbackUrl, isNull);

    await tester.runAsync(() => store.setTrackCover(track.id, _png(10)));
    await tester.pump();

    final customUrl = store.trackCoverUrl(track.id);
    expect(customUrl, isNotNull);
    expect(imageOf(tester).url, customUrl);

    await tester.runAsync(() => store.resetTrackCover(track.id));
    await tester.pump();
    expect(imageOf(tester).url, 'https://img.example/original.jpg');
  });

  testWidgets('默认封面只作为回退：无真实封面时主图为空、回退默认图', (tester) async {
    await tester.runAsync(() => store.setDefaultCover(_png(20)));
    await tester.pumpWidget(host(const Track(
      id: TrackId('kw', 'none'),
      title: 'No artwork',
      origin: TrackOrigin.builtin,
    )));

    final image = imageOf(tester);
    expect(image.url, isNull, reason: '默认封面不是真实主图');
    expect(image.fallbackUrl, store.defaultCoverUrl);
  });

  testWidgets('默认封面 revision 后回退图立即刷新', (tester) async {
    await tester.pumpWidget(host(const Track(
      id: TrackId('kw', 'none'),
      title: 'No artwork',
      origin: TrackOrigin.builtin,
    )));
    expect(imageOf(tester).fallbackUrl, isNull);

    await tester.runAsync(() => store.setDefaultCover(_png(30)));
    await tester.pump();
    expect(imageOf(tester).fallbackUrl, store.defaultCoverUrl);

    await tester.runAsync(store.resetDefaultCover);
    await tester.pump();
    expect(imageOf(tester).fallbackUrl, isNull);
  });
}
