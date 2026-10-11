import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/artwork_palette_service.dart';
import 'package:molia/theme/scheme_builder.dart';

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
      _SolidColorImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(
      _createImage().then((image) => ImageInfo(image: image)),
    );
  }

  Future<ui.Image> _createImage() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 4, 4),
      Paint()..color = color,
    );
    return recorder.endRecording().toImage(4, 4);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArtworkPaletteService', () {
    // 取色路径要解码真实 ui.Image：testWidgets + runAsync 才能完成引擎回调，
    // 普通 test 的 fake async 区不会完成。
    testWidgets('提取纯色封面：seed → 双亮度方案，缓存命中不重复取图', (tester) async {
      var providerCalls = 0;
      final service = ArtworkPaletteService(providerFor: (url) async {
        providerCalls++;
        return _SolidColorImageProvider(const Color(0xFF00BB00));
      });

      final first =
          await tester.runAsync(() => service.load('https://example.com/a.jpg'));
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
      final second =
          await tester.runAsync(() => service.load('https://example.com/a.jpg'));
      expect(identical(second, first), isTrue);
      expect(providerCalls, 1);
    });

    testWidgets('同 URL 并发请求合并为一次提取', (tester) async {
      var providerCalls = 0;
      final service = ArtworkPaletteService(providerFor: (url) async {
        providerCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _SolidColorImageProvider(const Color(0xFFBB0000));
      });

      final results = await tester.runAsync(() => Future.wait([
            service.load('https://example.com/b.jpg'),
            service.load('https://example.com/b.jpg'),
          ]));
      expect(providerCalls, 1);
      expect(identical(results![0], results[1]), isTrue);
    });

    testWidgets('取图失败（省流未命中/网络失败）返回 null，不抛错', (tester) async {
      final service = ArtworkPaletteService(providerFor: (url) async {
        throw const ArtworkNetworkBlockedException('https://example.com/c.jpg');
      });
      final result = await tester
          .runAsync(() => service.load('https://example.com/c.jpg'));
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
  });

  group('ArtworkThemeSync', () {
    ArtworkPalette paletteOf(Color color) =>
        ArtworkPalette.fromSeed(color);

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
  });
}
