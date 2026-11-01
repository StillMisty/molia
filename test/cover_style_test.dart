import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/cover_style.dart';
import 'package:molia/services/covers/cover_style_cache.dart';
import 'package:molia/services/covers/cover_style_processor.dart';
import 'package:molia/services/covers/cover_style_settings.dart';

import 'support/settings_test_support.dart';

/// 合成封面：左半深色、右半纸白、中间一个红色圆。既有亮部也有线条 / 暗面，
/// 足以让 8 种风格都产生明显差异，且不依赖任何网络或本地素材。
Uint8List _samplePng({int width = 64, int height = 48}) {
  final source = image.Image(width: width, height: height);
  final radius = (height / 6) * (height / 6);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      int r;
      int g;
      int b;
      if (x < width ~/ 2) {
        r = 24 + (x * 3) % 32;
        g = 30 + (y * 2) % 24;
        b = 58 + (x * 2) % 30;
      } else {
        r = 247;
        g = 244;
        b = 238;
      }
      final dx = x - width / 2;
      final dy = y - height / 2;
      if (dx * dx + dy * dy < radius) {
        r = 220;
        g = 42;
        b = 52;
      }
      source.setPixelRgb(x, y, r, g, b);
    }
  }
  return Uint8List.fromList(image.encodePng(source));
}

image.Image _decode(Uint8List bytes) => image.decodeImage(bytes)!;

int _luma(image.Pixel pixel) =>
    (pixel.r.toInt() * 77 + pixel.g.toInt() * 150 + pixel.b.toInt() * 29) >> 8;

int _uniqueColors(image.Image source) {
  final colors = <int>{};
  for (final pixel in source) {
    colors.add(
      (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt(),
    );
  }
  return colors.length;
}

class _FakeProcessor implements CoverStyleProcessorPort {
  _FakeProcessor({this.delay = Duration.zero, this.fail = false, this.output});

  final Duration delay;
  final bool fail;
  final Uint8List? output;
  int calls = 0;
  final List<CoverStyle> styles = [];

  @override
  Future<Uint8List?> process(
    Uint8List source, {
    required CoverStyle style,
    required int edge,
  }) async {
    calls++;
    styles.add(style);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) return null;
    return output ??
        Uint8List.fromList(List<int>.generate(8, (index) => index + calls));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoverStyle', () {
    test('稳定 id / 非法值回退', () {
      expect(CoverStyle.oneLastKiss.id, 'oneLastKiss');
      expect(CoverStyle.fromId('oneLastKiss'), CoverStyle.oneLastKiss);
      expect(CoverStyle.fromId('bad-value'), CoverStyle.original);
      expect(CoverStyle.fromId(null), CoverStyle.original);
      expect(CoverStyle.original.isStylized, isFalse);
      expect(CoverStyle.lineArt.isStylized, isTrue);
      expect(CoverStyleScope.fromId('all'), CoverStyleScope.all);
      expect(CoverStyleScope.fromId('bad'), CoverStyleScope.player);
    });
  });

  group('处理器（纯 Dart）', () {
    final sample = _samplePng();

    test('8 种风格输出非空且方形、边长正确', () {
      for (final style in CoverStyle.values.where((s) => s.isStylized)) {
        final bytes = CoverStyleProcessor.processSync(
          sample,
          style: style,
          edge: 64,
        );
        expect(bytes, isNotNull, reason: style.id);
        final decoded = _decode(bytes!);
        expect(decoded.width, 64, reason: style.id);
        expect(decoded.height, 64, reason: style.id);
      }
    });

    test('渐变素描有彩色，亮部接近纸白', () {
      final bytes = CoverStyleProcessor.processSync(
        sample,
        style: CoverStyle.oneLastKiss,
        edge: 64,
      )!;
      final decoded = _decode(bytes);
      var colorful = 0;
      var bright = 0;
      for (final pixel in decoded) {
        final maxChannel = [
          pixel.r,
          pixel.g,
          pixel.b,
        ].reduce((a, b) => a > b ? a : b);
        final minChannel = [
          pixel.r,
          pixel.g,
          pixel.b,
        ].reduce((a, b) => a < b ? a : b);
        if (maxChannel - minChannel > 30) colorful++;
        if (pixel.r > 232 && pixel.g > 228 && pixel.b > 220) bright++;
      }
      expect(colorful, greaterThan(40));
      expect(bright, greaterThan(100));
    });

    test('纯线稿 / 黑白墨印输出灰阶', () {
      for (final style in [CoverStyle.lineArt, CoverStyle.ink]) {
        final decoded = _decode(
          CoverStyleProcessor.processSync(sample, style: style, edge: 64)!,
        );
        for (final pixel in decoded) {
          expect(pixel.r, pixel.g, reason: style.id);
          expect(pixel.g, pixel.b, reason: style.id);
        }
      }
    });

    test('像素风是块状重复 + 有限配色', () {
      final decoded = _decode(
        CoverStyleProcessor.processSync(
          sample,
          style: CoverStyle.pixel,
          edge: 64,
        )!,
      );
      // 64px 下块大小 3：同一块内相邻像素颜色相同。
      final a = decoded.getPixel(1, 1);
      final b = decoded.getPixel(2, 2);
      expect((a.r, a.g, a.b), (b.r, b.g, b.b));
      expect(_uniqueColors(decoded), lessThanOrEqualTo(32));
    });

    test('双色印刷是两色渐变，不是剪影 / 灰阶', () {
      final decoded = _decode(
        CoverStyleProcessor.processSync(
          sample,
          style: CoverStyle.duotone,
          edge: 64,
        )!,
      );
      expect(_uniqueColors(decoded), greaterThan(2));
      // 暗部偏靛蓝、亮部偏暖黄；只要两个方向都存在，就说明渐变映射生效。
      expect(
        decoded.any((pixel) => pixel.b > pixel.r),
        isTrue,
        reason: '应有靛蓝暗部',
      );
      expect(
        decoded.any((pixel) => pixel.r > pixel.b),
        isTrue,
        reason: '应有暖黄亮部',
      );
    });

    test('非法字节返回 null', () {
      expect(
        CoverStyleProcessor.processSync(
          Uint8List.fromList([1, 2, 3]),
          style: CoverStyle.lineArt,
          edge: 64,
        ),
        isNull,
      );
      expect(
        CoverStyleProcessor.processSync(
          Uint8List(0),
          style: CoverStyle.ink,
          edge: 64,
        ),
        isNull,
      );
    });

    test('非方形输入中心裁切为方形，边长上限 768', () {
      final wide = _samplePng(width: 120, height: 40);
      final bytes = CoverStyleProcessor.processSync(
        wide,
        style: CoverStyle.emboss,
        edge: 4096,
      )!;
      final decoded = _decode(bytes);
      expect(decoded.width, 768);
      expect(decoded.height, 768);
    });

    test('浮雕 / 铅笔为灰阶且有明暗层次', () {
      for (final style in [CoverStyle.emboss, CoverStyle.pencil]) {
        final decoded = _decode(
          CoverStyleProcessor.processSync(sample, style: style, edge: 64)!,
        );
        var min = 255;
        var max = 0;
        for (final pixel in decoded) {
          expect(pixel.r, pixel.g, reason: style.id);
          expect(pixel.g, pixel.b, reason: style.id);
          final luma = _luma(pixel);
          if (luma < min) min = luma;
          if (luma > max) max = luma;
        }
        expect(max - min, greaterThan(40), reason: style.id);
      }
    });

    test('铅笔比纯线稿有更多中间调石墨', () {
      int midtones(CoverStyle style) {
        final decoded = _decode(
          CoverStyleProcessor.processSync(sample, style: style, edge: 64)!,
        );
        return decoded.where((pixel) {
          final luma = _luma(pixel);
          return luma > 40 && luma < 215;
        }).length;
      }

      expect(
        midtones(CoverStyle.pencil),
        greaterThan(midtones(CoverStyle.lineArt)),
      );
    });

    test('胶片有彩色像素且角落比中心暗', () {
      final colorfulSource = _decode(
        CoverStyleProcessor.processSync(
          sample,
          style: CoverStyle.film,
          edge: 64,
        )!,
      );
      var colorful = 0;
      for (final pixel in colorfulSource) {
        final maxChannel = [
          pixel.r,
          pixel.g,
          pixel.b,
        ].reduce((a, b) => a > b ? a : b);
        final minChannel = [
          pixel.r,
          pixel.g,
          pixel.b,
        ].reduce((a, b) => a < b ? a : b);
        if (maxChannel - minChannel > 12) colorful++;
      }
      expect(colorful, greaterThan(100));

      // 暗角用均匀灰源验证：合成封面的四角包含亮纸白，直接比较会被内容干扰。
      final uniform = image.Image(width: 64, height: 64);
      for (var y = 0; y < uniform.height; y++) {
        for (var x = 0; x < uniform.width; x++) {
          uniform.setPixelRgb(x, y, 180, 180, 180);
        }
      }
      final decoded = _decode(
        CoverStyleProcessor.processSync(
          Uint8List.fromList(image.encodePng(uniform)),
          style: CoverStyle.film,
          edge: 64,
        )!,
      );

      double averageLuma(Iterable<image.Pixel> pixels) {
        var total = 0;
        var count = 0;
        for (final pixel in pixels) {
          total += _luma(pixel);
          count++;
        }
        return total / count;
      }

      final width = decoded.width;
      final height = decoded.height;
      final center = averageLuma([
        for (var y = height * 3 ~/ 8; y < height * 5 ~/ 8; y++)
          for (var x = width * 3 ~/ 8; x < width * 5 ~/ 8; x++)
            decoded.getPixel(x, y),
      ]);
      final corners = averageLuma([
        for (var y = 0; y < 10; y++)
          for (var x = 0; x < 10; x++) ...[
            decoded.getPixel(x, y),
            decoded.getPixel(width - 1 - x, y),
            decoded.getPixel(x, height - 1 - y),
            decoded.getPixel(width - 1 - x, height - 1 - y),
          ],
      ]);
      expect(center, greaterThan(corners + 10));
    });

    test('worker 启动失败后下一次可重新拉起', () async {
      var attempts = 0;
      final processor = CoverStyleProcessor(
        spawner: (entryPoint, message, errorPort) async {
          attempts++;
          if (attempts == 1) throw StateError('spawn failed');
          return Isolate.spawn(
            entryPoint,
            message,
            debugName: 'molia-cover-style-test',
            onError: errorPort,
            onExit: errorPort,
          );
        },
      );
      addTearDown(processor.dispose);

      expect(
        await processor.process(
          _samplePng(),
          style: CoverStyle.lineArt,
          edge: 64,
        ),
        isNull,
      );
      expect(processor.workerReady, isFalse);
      expect(attempts, 1);

      expect(
        await processor.process(
          _samplePng(),
          style: CoverStyle.lineArt,
          edge: 64,
        ),
        isNotNull,
      );
      expect(processor.workerReady, isTrue);
      expect(attempts, 2);
    });

    test('长驻 worker 可重复处理（不逐张 spawn）', () async {
      final processor = CoverStyleProcessor();
      addTearDown(processor.dispose);
      final first = await processor.process(
        _samplePng(),
        style: CoverStyle.lineArt,
        edge: 64,
      );
      expect(first, isNotNull);
      expect(processor.workerReady, isTrue);
      final second = await processor.process(
        _samplePng(),
        style: CoverStyle.pixel,
        edge: 64,
      );
      expect(second, isNotNull);
      expect(processor.workerReady, isTrue);
    });
  });

  group('CoverStyleCache', () {
    test('同 key 并发去重，只取图 / 处理一次', () async {
      final processor = _FakeProcessor(delay: const Duration(milliseconds: 20));
      var loads = 0;
      final cache = CoverStyleCache(
        processor: processor,
        sourceLoader: (url) async {
          loads++;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      final first = cache.obtain(
        'https://img.example/a.jpg',
        CoverStyle.lineArt,
        edge: 64,
      );
      final second = cache.obtain(
        'https://img.example/a.jpg',
        CoverStyle.lineArt,
        edge: 64,
      );
      expect(identical(first, second), isTrue);
      expect(await first, isNotNull);
      expect(await second, isNotNull);
      expect(loads, 1);
      expect(processor.calls, 1);
    });

    test('LRU：命中刷新顺序，超预算淘汰最久未用', () async {
      final cache = CoverStyleCache(
        processor: _FakeProcessor(
          output: Uint8List.fromList(List<int>.filled(8, 7)),
        ),
        sourceLoader: (_) async => Uint8List.fromList([1, 2, 3]),
        maxBytes: 16,
      );
      await cache.obtain('a', CoverStyle.lineArt, edge: 64);
      await cache.obtain('b', CoverStyle.lineArt, edge: 64);
      expect(cache.entryCount, 2);
      expect(cache.peek('a', CoverStyle.lineArt, 64), isNotNull);
      await cache.obtain('c', CoverStyle.lineArt, edge: 64);
      expect(cache.entryCount, 2);
      expect(cache.peek('a', CoverStyle.lineArt, 64), isNotNull);
      expect(cache.peek('b', CoverStyle.lineArt, 64), isNull);
      expect(cache.peek('c', CoverStyle.lineArt, 64), isNotNull);
    });

    test('原图不处理；失败 / 缺失源返回 null 且不抛异常', () async {
      final processor = _FakeProcessor(fail: true);
      final cache = CoverStyleCache(
        processor: processor,
        sourceLoader: (url) async =>
            url == 'missing' ? null : Uint8List.fromList([1, 2, 3]),
      );
      expect(await cache.obtain('x', CoverStyle.original, edge: 64), isNull);
      expect(processor.calls, 0);
      expect(await cache.obtain('missing', CoverStyle.ink, edge: 64), isNull);
      expect(await cache.obtain('x', CoverStyle.ink, edge: 64), isNull);
      expect(processor.calls, 1, reason: '缺失源不应进入处理器');
    });

    test('插入与淘汰通知监听者', () async {
      final cache = CoverStyleCache(
        processor: _FakeProcessor(
          output: Uint8List.fromList(List<int>.filled(8, 7)),
        ),
        sourceLoader: (_) async => Uint8List.fromList([1, 2, 3]),
        maxBytes: 8,
      );
      var notifications = 0;
      cache.addListener(() => notifications++);
      await cache.obtain('a', CoverStyle.lineArt, edge: 64);
      expect(notifications, greaterThanOrEqualTo(1));
      await cache.obtain('b', CoverStyle.lineArt, edge: 64);
      expect(cache.entryCount, 1);
      expect(cache.byteCount, 8);
    });

    test('边长分桶：64 / 128 / 256 / 512 / 768，封顶 768', () {
      expect(CoverStyleCache.bucketFor(1), 64);
      expect(CoverStyleCache.bucketFor(96), 128);
      expect(CoverStyleCache.bucketFor(300), 512);
      expect(CoverStyleCache.bucketFor(900), 768);
      expect(CoverStyleCache.edgeForLogical(40, 3), 128);
      expect(CoverStyleCache.edgeForLogical(48, 3), 256);
    });

    test('默认取图支持 data URL 与 file://', () async {
      final bytes = _samplePng(width: 8, height: 8);
      final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
      expect(await loadCoverStyleSource(dataUrl), bytes);

      final dir = await Directory.systemTemp.createTemp('molia_style_source_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/cover.png');
      await file.writeAsBytes(bytes);
      expect(await loadCoverStyleSource(Uri.file(file.path).toString()), bytes);
      expect(
        await loadCoverStyleSource(
          Uri.file('${dir.path}/missing.png').toString(),
        ),
        isNull,
      );
    });
  });

  group('CoverStyleSettings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    CoverStyleSettings buildSettings() {
      final registry = testSettingsRegistry();
      final settings = CoverStyleSettings(
        settings: registry.scope([kCoverStyle, kCoverStyleScope]),
      );
      return settings;
    }

    test('默认原图 + 仅播放页', () async {
      final settings = buildSettings();
      await settings.init();
      expect(settings.style, CoverStyle.original);
      expect(settings.scope, CoverStyleScope.player);
      expect(kCoverStyle.defaultValue, 'original');
      expect(kCoverStyleScope.defaultValue, 'player');
    });

    test('非法持久化值回退默认', () async {
      final registry = testSettingsRegistry();
      await registry.write(kCoverStyle, 'not-a-style');
      await registry.write(kCoverStyleScope, 'not-a-scope');
      final settings = CoverStyleSettings(
        settings: registry.scope([kCoverStyle, kCoverStyleScope]),
      );
      await settings.init();
      expect(settings.style, CoverStyle.original);
      expect(settings.scope, CoverStyleScope.player);
    });

    test('写入后持久化，新实例读回同一设置', () async {
      final registry = testSettingsRegistry();
      final scoped = registry.scope([kCoverStyle, kCoverStyleScope]);
      final settings = CoverStyleSettings(settings: scoped);
      await settings.init();
      await settings.setStyle(CoverStyle.oneLastKiss);
      await settings.setScope(CoverStyleScope.all);
      expect(await registry.read(kCoverStyle), 'oneLastKiss');
      expect(await registry.read(kCoverStyleScope), 'all');

      final restored = CoverStyleSettings(settings: scoped);
      await restored.init();
      expect(restored.style, CoverStyle.oneLastKiss);
      expect(restored.scope, CoverStyleScope.all);
    });

    test('同步应用远端值后 reloadKeys 重载并通知', () async {
      final registry = testSettingsRegistry();
      final settings = CoverStyleSettings(
        settings: registry.scope([kCoverStyle, kCoverStyleScope]),
      );
      await settings.init();
      var notifications = 0;
      settings.addListener(() => notifications++);

      await registry.write(kCoverStyle, 'film');
      await registry.write(kCoverStyleScope, 'all');
      await registry.reloadKeys([kCoverStyle.name, kCoverStyleScope.name]);

      expect(settings.style, CoverStyle.film);
      expect(settings.scope, CoverStyleScope.all);
      expect(notifications, 1, reason: '两个键共用同一 reload 钩子，只通知一次');
    });
  });
}
