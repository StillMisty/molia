import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
// 测试直接用 flutter_cache_manager 的内存实现（传递依赖，不触网）。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/cache_service.dart';
import '../support/memory_cache_storage.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 永远失败的 CacheManager：离线验证 error 回退。
class _FailingCacheManager extends CacheManager {
  _FailingCacheManager()
      : super(Config(
          'app_network_image_test_fail',
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

/// 永不结束的 CacheManager：离线验证加载中占位。
class _PendingCacheManager extends CacheManager {
  _PendingCacheManager()
      : super(Config(
          'app_network_image_test_pending',
          repo: NonStoringObjectProvider(),
          fileSystem: MemoryCacheSystem(),
          fileService: HttpFileService(),
        ));

  final StreamController<FileResponse> _controller =
      StreamController<FileResponse>();

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      _controller.stream;

  Future<void> close() => _controller.close();
}

ArtworkCache _cacheWith(CacheManager manager) => ArtworkCache(
      cacheService: CacheService(storage: MemoryCacheStorage()),
      managerOverride: manager,
    );

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
          ),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );

File _localPng() {
  final dir = Directory.systemTemp.createTempSync('molia_network_image_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final bytes = image.encodePng(image.Image(width: 4, height: 4));
  final file = File('${dir.path}/cover.png');
  file.writeAsBytesSync(bytes);
  return file;
}

void main() {
  testWidgets('url 为空：直接显示 Molia 标志回退，不创建网络加载', (tester) async {
    await tester.pumpWidget(_host(const AppNetworkImage(
      url: null,
      width: 40,
      height: 40,
      fallbackIconSize: 20,
    )));

    expect(find.byType(MoliaMark), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('url 为空：有 fallbackUrl 时先显示默认封面', (tester) async {
    final file = _localPng();
    await tester.pumpWidget(
      _host(
        AppNetworkImage(
          url: null,
          width: 40,
          height: 40,
          fallbackUrl: file.uri.toString(),
          fallbackIconSize: 20,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(MoliaMark), findsNothing);
  });

  testWidgets('主图加载失败：先落 fallbackUrl，再失败才回退 Molia', (tester) async {
    final file = _localPng();
    await tester.pumpWidget(
      _host(
        AppNetworkImage(
          url: 'https://p1.music.126.net/failing-fallback.jpg',
          width: 40,
          height: 40,
          fallbackUrl: file.uri.toString(),
          fallbackIconSize: 20,
          artworkCache: _cacheWith(_FailingCacheManager()),
        ),
      ),
    );
    for (var i = 0; i < 20 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(MoliaMark), findsNothing);
  });

  testWidgets('fallbackUrl 也失败：回到 Molia，不递归', (tester) async {
    await tester.pumpWidget(
      _host(
        AppNetworkImage(
          url: 'https://p1.music.126.net/failing-fallback-2.jpg',
          width: 40,
          height: 40,
          fallbackUrl: 'https://p1.music.126.net/fallback-also-fails.jpg',
          fallbackIconSize: 20,
          artworkCache: _cacheWith(_FailingCacheManager()),
        ),
      ),
    );
    for (var i = 0; i < 20 && find.byType(MoliaMark).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(MoliaMark), findsOneWidget);
  });

  testWidgets('加载中：显示占位（不触网）', (tester) async {
    final manager = _PendingCacheManager();
    addTearDown(manager.close);

    await tester.pumpWidget(_host(AppNetworkImage(
      url: 'https://p1.music.126.net/pending.jpg',
      width: 40,
      height: 40,
      placeholder: const SizedBox(key: ValueKey('placeholder')),
      artworkCache: _cacheWith(manager),
    )));
    // 等待 manager Future 完成并挂载 CachedNetworkImage。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('placeholder')), findsOneWidget);
    expect(find.byType(MoliaMark), findsNothing);
  });

  testWidgets('加载失败：回退 Molia 标志（不触网）', (tester) async {
    await tester.pumpWidget(_host(AppNetworkImage(
      url: 'https://p1.music.126.net/failing.jpg',
      width: 40,
      height: 40,
      fallbackIconSize: 20,
      artworkCache: _cacheWith(_FailingCacheManager()),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MoliaMark), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manager 已解析：不经过 FutureBuilder（重建不回到占位分支）', (tester) async {
    final manager = _PendingCacheManager();
    addTearDown(manager.close);
    final cache = _cacheWith(manager);

    Widget build() => _host(AppNetworkImage(
          url: 'https://p1.music.126.net/frame-rebuild.jpg',
          width: 40,
          height: 40,
          placeholder: const SizedBox(key: ValueKey('placeholder')),
          artworkCache: cache,
        ));

    await tester.pumpWidget(build());
    // manager Future 必须身份稳定：每次 build 新建会让 FutureBuilder 重置为
    // waiting 渲染占位；切歌动画逐帧重建封面 → 整段动画都是深色占位。
    expect(find.byType(FutureBuilder<CacheManager?>), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);

    // 模拟动画/切歌触发的重建：仍直接构建，不回到占位分支。
    await tester.pumpWidget(build());
    expect(find.byType(FutureBuilder<CacheManager?>), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });

  testWidgets('file:// 封面也按 memCacheWidth 缩略解码', (tester) async {
    await tester.pumpWidget(_host(const AppNetworkImage(
      url: 'file:///tmp/molia-perf-cover.png',
      width: 44,
      height: 44,
      memCacheWidth: 44,
    )));

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
  });

  testWidgets('file:// 封面双轴只保留一轴（双轴会按精确尺寸拉伸）', (tester) async {
    await tester.pumpWidget(_host(const AppNetworkImage(
      url: 'file:///tmp/molia-perf-cover.png',
      width: 44,
      height: 44,
      memCacheWidth: 120,
      memCacheHeight: 80,
    )));

    final image = tester.widget<Image>(find.byType(Image));
    final resize = image.image as ResizeImage;
    expect(resize.width, 120);
    expect(resize.height, isNull, reason: '双轴会拉伸封面，只保留较大的一轴');
  });

  testWidgets('远端封面未显式给尺寸时按布局宽度 × DPR 兜底，且只给一轴',
      (tester) async {
    final manager = _PendingCacheManager();
    addTearDown(manager.close);
    final cache = _cacheWith(manager);

    await tester.pumpWidget(_host(AppNetworkImage(
      url: 'https://p1.music.126.net/header.jpg',
      width: 96,
      height: 96,
      artworkCache: cache,
    )));

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    final dpr = MediaQuery.devicePixelRatioOf(
      tester.element(find.byType(CachedNetworkImage)),
    );
    expect(image.memCacheWidth, (96 * dpr).round());
    expect(image.memCacheHeight, isNull, reason: '双轴会拉伸封面，只给一轴');
  });

  testWidgets('远端封面显式双轴也只保留较大的一轴', (tester) async {
    final manager = _PendingCacheManager();
    addTearDown(manager.close);
    final cache = _cacheWith(manager);

    await tester.pumpWidget(_host(AppNetworkImage(
      url: 'https://p1.music.126.net/explicit.jpg',
      width: 100,
      height: 100,
      memCacheWidth: 120,
      memCacheHeight: 80,
      artworkCache: cache,
    )));

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.memCacheWidth, 120);
    expect(image.memCacheHeight, isNull);
  });

  testWidgets('淡入淡出走 M3E effects token（占位层快速让位）', (tester) async {
    final manager = _PendingCacheManager();
    addTearDown(manager.close);

    await tester.pumpWidget(_host(AppNetworkImage(
      url: 'https://p1.music.126.net/fade.jpg',
      width: 40,
      height: 40,
      artworkCache: _cacheWith(manager),
    )));

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.fadeInDuration, M3EMotion.short4);
    expect(image.fadeInCurve, M3EMotion.emphasizedDecelerate);
    expect(image.fadeOutDuration, M3EMotion.short2);
    expect(image.fadeOutCurve, M3EMotion.emphasizedAccelerate);
    expect(
      image.placeholderFadeInDuration,
      isNull,
      reason: '占位淡入保持 CachedNetworkImage 默认，只收紧占位淡出',
    );
  });

  testWidgets('减弱动效：淡入淡出时长为零（硬切）', (tester) async {
    final manager = _PendingCacheManager();
    addTearDown(manager.close);

    await tester.pumpWidget(_host(
      AppNetworkImage(
        url: 'https://p1.music.126.net/reduced-motion.jpg',
        width: 40,
        height: 40,
        artworkCache: _cacheWith(manager),
      ),
      disableAnimations: true,
    ));

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.fadeInDuration, Duration.zero);
    expect(image.fadeOutDuration, Duration.zero);
  });
}
