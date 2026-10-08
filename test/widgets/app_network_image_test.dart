import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
// 测试直接用 flutter_cache_manager 的内存实现（传递依赖，不触网）。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_stub.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/molia_mark.dart';
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

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

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

  testWidgets('manager 已解析：不经过 FutureBuilder（重建不回到占位分支）',
      (tester) async {
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
    // 旧实现每次 build 都新建 managerOrNull() Future，FutureBuilder 会重置为
    // waiting 渲染占位；切歌动画逐帧重建封面 → 整段动画都是深色占位。
    expect(find.byType(FutureBuilder<CacheManager?>), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);

    // 模拟动画/切歌触发的重建：仍直接构建，不回到占位分支。
    await tester.pumpWidget(build());
    expect(find.byType(FutureBuilder<CacheManager?>), findsNothing);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });
}
