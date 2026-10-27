import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/playback/playback_power_policy.dart';
import 'package:molia/services/app_presence.dart';
import 'package:molia/services/artwork_palette_seed_store.dart';
import 'package:molia/services/artwork_palette_service.dart';
import 'package:molia/services/covers/cover_image_identity.dart';
import 'package:molia/services/covers/cover_resolution.dart';
import 'package:molia/theme/scheme_builder.dart';

import '../support/fake_cover_index.dart';

/// 4x4 纯色图片 provider：驱动取色路径（不依赖网络/资产）。
class _SolidColorImageProvider extends ImageProvider<_SolidColorImageProvider> {
  _SolidColorImageProvider(this.color);

  final Color color;

  @override
  Future<_SolidColorImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_SolidColorImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _SolidColorImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _createImage().then((image) => ImageInfo(image: image)),
    );
  }

  Future<ui.Image> _createImage() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = color);
    return recorder.endRecording().toImage(4, 4);
  }
}

/// 单帧图片 provider：图片句柄所有权交给 [ImageInfo]，测试另留 clone 观察
/// 取色结束后是否还有句柄未释放。
class _ProbeImageProvider extends ImageProvider<_ProbeImageProvider> {
  _ProbeImageProvider(this._image);

  final ui.Image _image;

  @override
  Future<_ProbeImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_ProbeImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _ProbeImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: _image)),
    );
  }
}

/// 生成 [size]×[size] 纯色图像（调用方负责 dispose 返回的句柄）。
Future<ui.Image> _solidImage(Color color, {int size = 4}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  return picture.toImage(size, size).whenComplete(picture.dispose);
}

/// 生成 [size]×[size] 纯色 PNG 字节：驱动「本地缓存字节」启动预解析路径。
Future<Uint8List> _pngBytes(Color color, {int size = 8}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// 内存 seed store：写发生在 future 完成前，测试无需等待落盘队列。
class _FakeSeedStore extends ArtworkPaletteSeedStore {
  final Map<String, int> entries = {};

  @override
  Future<int?> read(String cacheKey) async => entries[cacheKey];

  @override
  Future<void> write(String cacheKey, int seed) async {
    entries[cacheKey] = seed;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArtworkPaletteService', () {
    // 取色路径要解码真实 ui.Image：testWidgets + runAsync 才能完成引擎回调，
    // 普通 test 的 fake async 区不会完成。
    test('loadTrack：只有默认封面时不取色 / 不读图', () async {
      var providerCalls = 0;
      final service = ArtworkPaletteService(
        providerFor: (url) async {
          providerCalls++;
          return _SolidColorImageProvider(const Color(0xFF00BB00));
        },
      );
      final index = FakeCoverIndex(defaultUrl: 'file:///tmp/default-cover.jpg');
      const track = Track(
        id: TrackId('wy', '1'),
        title: 'T',
        origin: TrackOrigin.builtin,
      );

      final palette = await service.loadTrack(
        track,
        covers: CoverResolver(index),
      );

      expect(palette, isNull);
      expect(providerCalls, 0, reason: '默认封面是占位，不参与取色');
    });

    testWidgets('提取纯色封面：seed → 双亮度方案，缓存命中不重复取图', (tester) async {
      var providerCalls = 0;
      final service = ArtworkPaletteService(
        providerFor: (url) async {
          providerCalls++;
          return _SolidColorImageProvider(const Color(0xFF00BB00));
        },
      );

      final first = await tester.runAsync(
        () => service.load('https://example.com/a.jpg'),
      );
      expect(first, isNotNull);
      expect(first!.light, buildColorScheme(first.seed, Brightness.light));
      expect(first.dark, buildColorScheme(first.seed, Brightness.dark));
      expect(
        first.seed.toARGB32(),
        isNot(Colors.blue.toARGB32()),
        reason: '绿色封面不应回落到默认种子色',
      );
      expect(providerCalls, 1);

      // 再次读取命中缓存：同一个 palette 实例，不再取图。
      final second = await tester.runAsync(
        () => service.load('https://example.com/a.jpg'),
      );
      expect(identical(second, first), isTrue);
      expect(providerCalls, 1);
    });

    testWidgets('取色只缓存 100px 采样图，不把原图留在图片缓存', (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('molia_palette_probe'),
      ))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/large-cover.png');
      await tester.runAsync(() async {
        await file.writeAsBytes(
          await _pngBytes(const Color(0xFF00BB00), size: 512),
        );
      });

      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();

      final service = ArtworkPaletteService(
        providerFor: (url) async => FileImage(file),
      );
      final before = cache.currentSizeBytes;
      final palette = await tester.runAsync(
        () => service.load(file.uri.toString()),
      );
      final after = cache.currentSizeBytes;

      expect(palette, isNotNull);
      // 512×512 原图约 1MB；缩到采样边长 100px 后只应留下约 40KB。
      expect(
        after - before,
        lessThan(256 * 1024),
        reason: '取色不应把原图按 512px 留在共享图片缓存',
      );
      cache.clear();
    });

    testWidgets('取色完成后释放监听持有的 ImageInfo（图像句柄可回收）', (tester) async {
      final image = (await tester.runAsync(
        () => _solidImage(const Color(0xFF00BB00)),
      ))!;
      final probe = image.clone();
      addTearDown(() {
        if (!probe.debugDisposed) probe.dispose();
      });

      final provider = _ProbeImageProvider(image);
      final service = ArtworkPaletteService(
        providerFor: (url) async => provider,
      );
      final palette = await tester.runAsync(
        () => service.load('https://example.com/lifetime.jpg'),
      );
      expect(palette, isNotNull);

      // 清空共享图片缓存并跑一帧：`ImageCache` 通过 post-frame 回调释放
      // keepAlive 句柄，只有显式调度一帧后图片流才会真正释放当前图像。
      // 此时只剩测试自己的 probe；若取色监听泄漏 ImageInfo，会多一个句柄。
      final cache = PaintingBinding.instance.imageCache;
      await tester.runAsync(() async {
        cache.clear();
        cache.clearLiveImages();
      });
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(probe.debugGetOpenHandleStackTraces(), hasLength(1));
    });

    testWidgets('同 URL 并发请求合并为一次提取', (tester) async {
      var providerCalls = 0;
      final service = ArtworkPaletteService(
        providerFor: (url) async {
          providerCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _SolidColorImageProvider(const Color(0xFFBB0000));
        },
      );

      final results = await tester.runAsync(
        () => Future.wait([
          service.load('https://example.com/b.jpg'),
          service.load('https://example.com/b.jpg'),
        ]),
      );
      expect(providerCalls, 1);
      expect(identical(results![0], results[1]), isTrue);
    });

    testWidgets('取图失败（省流未命中/网络失败）返回 null，不抛错', (tester) async {
      final service = ArtworkPaletteService(
        providerFor: (url) async {
          throw const ArtworkNetworkBlockedException(
            'https://example.com/c.jpg',
          );
        },
      );
      final result = await tester.runAsync(
        () => service.load('https://example.com/c.jpg'),
      );
      expect(result, isNull);
      // 失败不写缓存：下次可重试（恢复网络后补取色）。
      expect(service.cacheSize, 0);
    });

    testWidgets('LRU 上限：超出容量的最早条目被淘汰', (tester) async {
      final service = ArtworkPaletteService(
        maxCacheEntries: 2,
        providerFor: (url) async =>
            _SolidColorImageProvider(const Color(0xFF112233)),
      );
      await tester.runAsync(() => service.load('a'));
      await tester.runAsync(() => service.load('b'));
      await tester.runAsync(() => service.load('c'));
      expect(service.cacheSize, 2);
    });

    testWidgets('启动预解析：命中本地缓存出方案，写入 LRU 后稳态 load 不再取图', (tester) async {
      final bytes = (await tester.runAsync(
        () => _pngBytes(const Color(0xFF00BB00)),
      ))!;
      var providerCalls = 0;
      var bytesCalls = 0;
      final service = ArtworkPaletteService(
        providerFor: (url) async {
          providerCalls++;
          return _SolidColorImageProvider(const Color(0xFFBB0000));
        },
        cachedBytesFor: (url) async {
          bytesCalls++;
          return bytes;
        },
      );

      final palette = await tester.runAsync(
        () => service.loadCached('https://example.com/a.jpg'),
      );
      expect(palette, isNotNull);
      expect(palette!.light, buildColorScheme(palette.seed, Brightness.light));
      expect(bytesCalls, 1);
      expect(providerCalls, 0, reason: '本地命中不应走取图（网络）路径');

      // LRU 已写入：同 URL 的稳态取色直接命中，不重复取图 / 读缓存字节。
      final loaded = await tester.runAsync(
        () => service.load('https://example.com/a.jpg'),
      );
      expect(identical(loaded, palette), isTrue);
      expect(providerCalls, 0);
      expect(bytesCalls, 1);
    });

    testWidgets('启动预解析：本地未命中返回 null，不发起取图', (tester) async {
      var providerCalls = 0;
      final service = ArtworkPaletteService(
        providerFor: (url) async {
          providerCalls++;
          return _SolidColorImageProvider(const Color(0xFFBB0000));
        },
        cachedBytesFor: (url) async => null,
      );

      final palette = await tester.runAsync(
        () => service.loadCached('https://example.com/miss.jpg'),
      );
      expect(palette, isNull);
      expect(providerCalls, 0, reason: '启动预解析不能触网');
      expect(service.cacheSize, 0);
    });

    testWidgets('启动预解析：file:// 封面走本地文件，不读网络缓存', (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('molia_palette_test'),
      ))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/cover.png');
      await tester.runAsync(() async {
        await file.writeAsBytes(await _pngBytes(const Color(0xFF00BB00)));
      });

      var bytesCalls = 0;
      final service = ArtworkPaletteService(
        cachedBytesFor: (url) async {
          bytesCalls++;
          return null;
        },
      );

      final palette = await tester.runAsync(
        () => service.loadCached(file.uri.toString()),
      );
      expect(palette, isNotNull);
      expect(bytesCalls, 0, reason: 'file:// 本身就是本地文件');
    });

    testWidgets('loadLocalFile：读盘字节出方案，同路径第二次只读一次盘', (tester) async {
      final bytes = (await tester.runAsync(
        () => _pngBytes(const Color(0xFF00BB00)),
      ))!;
      var reads = 0;
      final service = ArtworkPaletteService(
        localFileBytesFor: (path) async {
          reads++;
          return bytes;
        },
      );

      final first = await tester.runAsync(
        () => service.loadLocalFile('/home/u/wallpaper.png'),
      );
      expect(first, isNotNull);
      expect(first!.light, buildColorScheme(first.seed, Brightness.light));
      expect(
        first.seed.toARGB32(),
        isNot(Colors.blue.toARGB32()),
        reason: '绿色壁纸不应回落到默认种子色',
      );
      expect(reads, 1);

      // 浅 / 深壁纸常是同一文件：第二次命中 LRU，不再读盘、不再解码。
      final second = await tester.runAsync(
        () => service.loadLocalFile('/home/u/wallpaper.png'),
      );
      expect(identical(second, first), isTrue);
      expect(reads, 1);
    });

    testWidgets('loadLocalFile：大图按采样尺寸缩略解码后仍取到主色', (tester) async {
      final bytes = (await tester.runAsync(
        () => _pngBytes(const Color(0xFF00BB00), size: 512),
      ))!;
      final service = ArtworkPaletteService(
        localFileBytesFor: (path) async => bytes,
      );

      final palette = await tester.runAsync(
        () => service.loadLocalFile('/home/u/wallpaper-large.png'),
      );
      expect(palette, isNotNull);
      final argb = palette!.seed.toARGB32();
      final r = (argb >> 16) & 0xFF;
      final g = (argb >> 8) & 0xFF;
      final b = argb & 0xFF;
      expect(g, greaterThan(r), reason: '绿色壁纸主色应偏绿');
      expect(g, greaterThan(b));
    });

    testWidgets('loadLocalFile：读盘失败 / 空字节 / 解码失败返回 null，不抛错', (tester) async {
      final failing = ArtworkPaletteService(
        localFileBytesFor: (path) async => throw StateError('read failed'),
      );
      expect(
        await tester.runAsync(() => failing.loadLocalFile('/denied.png')),
        isNull,
      );

      final empty = ArtworkPaletteService(
        localFileBytesFor: (path) async => Uint8List(0),
      );
      expect(
        await tester.runAsync(() => empty.loadLocalFile('/empty.png')),
        isNull,
      );

      final corrupt = ArtworkPaletteService(
        localFileBytesFor: (path) async => Uint8List.fromList([1, 2, 3]),
      );
      expect(
        await tester.runAsync(() => corrupt.loadLocalFile('/corrupt.png')),
        isNull,
      );
    });

    testWidgets('seed 命中：不读缓存字节 / 不取图，稳态 load 复用 LRU', (tester) async {
      const identity = CoverImageIdentity(
        url: 'https://example.com/seed.jpg',
        sizeBytes: 1024,
        modifiedMs: 1234,
      );
      final store = _FakeSeedStore()..entries[identity.cacheKey] = 0xFF00BB00;
      var providerCalls = 0;
      var bytesCalls = 0;
      final service = ArtworkPaletteService(
        seedStore: store,
        identityFor: (url) async => identity,
        providerFor: (url) async {
          providerCalls++;
          return _SolidColorImageProvider(const Color(0xFFBB0000));
        },
        cachedBytesFor: (url) async {
          bytesCalls++;
          return Uint8List(0);
        },
      );

      final cached = await tester.runAsync(
        () => service.loadCached(identity.url),
      );
      expect(cached, isNotNull);
      expect(cached!.seed.toARGB32(), 0xFF00BB00);
      expect(providerCalls, 0);
      expect(bytesCalls, 0, reason: 'seed 命中不应读封面缓存字节');

      // 500ms 稳态 load 按同一内容身份命中内存 LRU，不重复提取。
      final loaded = await tester.runAsync(() => service.load(identity.url));
      expect(identical(loaded, cached), isTrue);
      expect(providerCalls, 0);
      expect(bytesCalls, 0);
    });

    testWidgets('新实例直接 load：持久 seed 命中，不读字节 / 不取图', (tester) async {
      const identity = CoverImageIdentity(
        url: 'https://example.com/load-seed.jpg',
        sizeBytes: 512,
        modifiedMs: 4321,
      );
      final store = _FakeSeedStore()..entries[identity.cacheKey] = 0xFF112233;
      var providerCalls = 0;
      var bytesCalls = 0;
      // 全新服务、内存 LRU 为空，也没有先走 loadCached。
      final service = ArtworkPaletteService(
        seedStore: store,
        identityFor: (url) async => identity,
        providerFor: (url) async {
          providerCalls++;
          return _SolidColorImageProvider(const Color(0xFFBB0000));
        },
        cachedBytesFor: (url) async {
          bytesCalls++;
          return Uint8List(0);
        },
      );

      final palette = await tester.runAsync(() => service.load(identity.url));
      expect(palette, isNotNull);
      expect(palette!.seed.toARGB32(), 0xFF112233);
      expect(providerCalls, 0);
      expect(bytesCalls, 0);

      // seed 命中时已写 LRU：后续 load 直接复用同一实例。
      final again = await tester.runAsync(() => service.load(identity.url));
      expect(identical(again, palette), isTrue);
      expect(providerCalls, 0);
      expect(bytesCalls, 0);
    });

    testWidgets('seed 未命中：走本地缓存字节，提取成功后写入 seed', (tester) async {
      const identity = CoverImageIdentity(
        url: 'https://example.com/miss.jpg',
        sizeBytes: 2048,
        modifiedMs: 5678,
      );
      final store = _FakeSeedStore();
      final bytes = (await tester.runAsync(
        () => _pngBytes(const Color(0xFF00BB00)),
      ))!;
      var bytesCalls = 0;
      final service = ArtworkPaletteService(
        seedStore: store,
        identityFor: (url) async => identity,
        cachedBytesFor: (url) async {
          bytesCalls++;
          return bytes;
        },
      );

      final palette = await tester.runAsync(
        () => service.loadCached(identity.url),
      );
      expect(palette, isNotNull);
      expect(bytesCalls, 1);
      expect(store.entries[identity.cacheKey], palette!.seed.toARGB32());
    });

    testWidgets('稳态 load 取图成功后也写 seed（不读本地缓存字节）', (tester) async {
      const identity = CoverImageIdentity(
        url: 'https://example.com/provider.jpg',
        sizeBytes: 4096,
        modifiedMs: 9999,
      );
      final store = _FakeSeedStore();
      var providerCalls = 0;
      var bytesCalls = 0;
      final service = ArtworkPaletteService(
        seedStore: store,
        identityFor: (url) async => identity,
        providerFor: (url) async {
          providerCalls++;
          return _SolidColorImageProvider(const Color(0xFF00BB00));
        },
        cachedBytesFor: (url) async {
          bytesCalls++;
          return null;
        },
      );

      final palette = await tester.runAsync(() => service.load(identity.url));
      expect(palette, isNotNull);
      expect(providerCalls, 1);
      expect(bytesCalls, 0);
      expect(store.entries[identity.cacheKey], palette!.seed.toARGB32());
    });

    testWidgets('内容身份变化：旧 seed 不复用，重新提取并写新 seed', (tester) async {
      const url = 'https://example.com/changing.jpg';
      const oldIdentity = CoverImageIdentity(
        url: url,
        sizeBytes: 10,
        modifiedMs: 1,
      );
      const newIdentity = CoverImageIdentity(
        url: url,
        sizeBytes: 20,
        modifiedMs: 2,
      );
      final store = _FakeSeedStore()
        ..entries[oldIdentity.cacheKey] = 0xFF00BB00;
      final bytes = (await tester.runAsync(
        () => _pngBytes(const Color(0xFFBB0000)),
      ))!;
      var identity = oldIdentity;
      var bytesCalls = 0;
      final service = ArtworkPaletteService(
        seedStore: store,
        identityFor: (_) async => identity,
        cachedBytesFor: (url) async {
          bytesCalls++;
          return bytes;
        },
      );

      final oldPalette = await tester.runAsync(() => service.loadCached(url));
      expect(oldPalette!.seed.toARGB32(), 0xFF00BB00);
      expect(bytesCalls, 0, reason: '旧身份 seed 仍有效');

      // 同一 URL 的缓存文件被替换：新身份没有 seed，必须重新提取。
      identity = newIdentity;
      final freshPalette = await tester.runAsync(() => service.loadCached(url));
      expect(freshPalette, isNotNull);
      expect(identical(freshPalette, oldPalette), isFalse);
      expect(bytesCalls, 1);
      expect(
        store.entries[newIdentity.cacheKey],
        freshPalette!.seed.toARGB32(),
      );
      expect(
        store.entries[oldIdentity.cacheKey],
        0xFF00BB00,
        reason: '旧内容 seed 保留，回滚到旧文件仍可命中',
      );
    });
  });

  group('ArtworkThemeSync', () {
    ArtworkPalette paletteOf(Color color) => ArtworkPalette.fromSeed(color);

    test('新封面经稳态延迟后应用；无封面清除回退', () async {
      final applied = <ArtworkPalette>[];
      var cleared = 0;
      final sync = ArtworkThemeSync(
        load: (url) async => paletteOf(Colors.green),
        onPalette: applied.add,
        onCleared: () => cleared++,
        settleDelay: Duration.zero,
      );

      sync.onArtworkChanged('https://example.com/a.jpg');
      await pumpEventQueue();
      expect(applied, hasLength(1));

      // 同一 URL 不重复触发。
      sync.onArtworkChanged('https://example.com/a.jpg');
      await pumpEventQueue();
      expect(applied, hasLength(1));

      // 无封面：清除（主题回退基础配色），不再取色。
      sync.onArtworkChanged(null);
      sync.onArtworkChanged('');
      expect(cleared, 1);
      await pumpEventQueue();
      expect(applied, hasLength(1));

      sync.dispose();
    });

    test('过期结果丢弃：切歌期间完成的旧取色不落地', () async {
      final completers = <String, Completer<ArtworkPalette?>>{};
      final applied = <String>[];
      final sync = ArtworkThemeSync(
        load: (url) {
          final completer = Completer<ArtworkPalette?>();
          completers[url] = completer;
          return completer.future;
        },
        onPalette: (palette) => applied.add(palette.seed.toARGB32().toString()),
        onCleared: () {},
        settleDelay: Duration.zero,
      );

      sync.onArtworkChanged('a');
      await pumpEventQueue();
      sync.onArtworkChanged('b');
      await pumpEventQueue();

      // 旧请求先完成：丢弃。
      completers['a']!.complete(paletteOf(Colors.green));
      await pumpEventQueue();
      expect(applied, isEmpty);

      // 当前请求完成：应用。
      completers['b']!.complete(paletteOf(Colors.red));
      await pumpEventQueue();
      expect(applied, hasLength(1));

      sync.dispose();
    });

    test('取色失败保持现色：不应用也不清除', () async {
      var cleared = 0;
      final applied = <ArtworkPalette>[];
      final sync = ArtworkThemeSync(
        load: (url) async => null,
        onPalette: applied.add,
        onCleared: () => cleared++,
        settleDelay: Duration.zero,
      );

      sync.onArtworkChanged('a');
      await pumpEventQueue();
      expect(applied, isEmpty);
      expect(cleared, 0);

      sync.dispose();
    });

    test('后台期只记 URL 不取色；恢复后补一次且不重复应用', () async {
      final presence = AppPresence();
      final loaded = <String>[];
      final applied = <ArtworkPalette>[];
      final sync = ArtworkThemeSync(
        load: (url) async {
          loaded.add(url);
          return paletteOf(Colors.green);
        },
        onPalette: applied.add,
        onCleared: () {},
        settleDelay: Duration.zero,
        presence: presence,
      );

      // 托盘隐藏期间切歌：URL 记下、不触发解码取色。
      presence.markTrayHidden();
      sync.onArtworkChanged('a');
      await pumpEventQueue();
      expect(loaded, isEmpty);
      expect(applied, isEmpty);

      // 恢复：对当前封面补一次。
      presence.markVisible();
      await pumpEventQueue();
      expect(loaded, ['a']);
      expect(applied, hasLength(1));

      // 已应用的 URL 不因后续存在态翻转重复取色（最小化→恢复）。
      presence.markMinimized();
      presence.markVisible();
      await pumpEventQueue();
      expect(loaded, ['a']);
      expect(applied, hasLength(1));

      sync.dispose();
    });

    test('移动端后台：无桌面歌词不取色；开悬浮窗允许取色', () async {
      final policy = PlaybackPowerPolicy();
      addTearDown(policy.dispose);
      final loaded = <String>[];
      final applied = <ArtworkPalette>[];
      final sync = ArtworkThemeSync(
        load: (url) async {
          loaded.add(url);
          return paletteOf(Colors.green);
        },
        onPalette: applied.add,
        onCleared: () {},
        settleDelay: Duration.zero,
        mobilePowerPolicy: policy,
      );

      // 息屏 / 切后台、没有桌面歌词：记录 URL 但不解码封面。
      policy.markBackground();
      sync.onArtworkChanged('a');
      await pumpEventQueue();
      expect(loaded, isEmpty);

      // 回前台：补一次。
      policy.markForeground();
      await pumpEventQueue();
      expect(loaded, ['a']);
      expect(applied, hasLength(1));

      // 再退后台并打开桌面歌词：悬浮窗可能跟随封面配色，允许取色。
      policy.markBackground();
      sync.onArtworkChanged('b');
      policy.setDesktopLyricsActive(true);
      await pumpEventQueue();
      expect(loaded, ['a', 'b']);
      expect(applied, hasLength(2));

      // 关闭悬浮窗后后台不再取色。
      policy.setDesktopLyricsActive(false);
      sync.onArtworkChanged('c');
      await pumpEventQueue();
      expect(loaded, ['a', 'b']);
      expect(applied, hasLength(2));

      sync.dispose();
    });
  });
}
