import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import 'package:molia/services/covers/cover_image_codec.dart';
import 'package:molia/services/covers/cover_image_format.dart';

/// 封面归一化：静态 / 透明 / 动图都统一成 WebP，且 Flutter 能解码动画帧。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('静态 PNG：转 WebP、最长边 1024、保持比例', () {
    final source = image.Image(width: 2048, height: 1024);
    image.fill(source, color: image.ColorRgb8(30, 120, 200));
    final png = image.encodePng(source);

    final normalized = CoverImageCodec.normalizeImageSync(png);
    final info = CoverImageFormats.detect(normalized.bytes);

    expect(info, isNotNull);
    expect(info!.format, CoverImageFormat.webp);
    expect(info.animated, isFalse);
    expect(info.width, 1024);
    expect(info.height, 512);
    expect(normalized.bytes.length, lessThanOrEqualTo(kCoverSyncMaxBytes));
    expect(normalized.mimeType, 'image/webp');
    expect(normalized.extension, 'webp');
  });

  test('透明 PNG：WebP 保留 alpha 通道', () {
    final source = image.Image(width: 128, height: 128, numChannels: 4);
    image.fill(source, color: image.ColorRgba8(0, 0, 0, 0));
    image.fillRect(
      source,
      x1: 32,
      y1: 32,
      x2: 96,
      y2: 96,
      color: image.ColorRgba8(220, 30, 60, 255),
    );
    final png = image.encodePng(source);

    final normalized = CoverImageCodec.normalizeImageSync(png);
    final decoded = image.decodeWebP(normalized.bytes);
    expect(decoded, isNotNull);
    expect(decoded!.getPixel(0, 0).a, 0);
    expect(decoded.getPixel(64, 64).a, 255);
  });

  test('动图 GIF：转动画 WebP，保留帧数与循环时长，Flutter 可解码多帧', () async {
    final gif = _animatedGif(frameCount: 6, edge: 96, frameMs: 80);
    final normalized = CoverImageCodec.normalizeImageSync(gif);
    final info = CoverImageFormats.detect(normalized.bytes);

    expect(info, isNotNull);
    expect(info!.format, CoverImageFormat.webp);
    expect(info.animated, isTrue);
    expect(normalized.animated, isTrue);

    final decoded = image.decodeWebP(normalized.bytes);
    expect(decoded, isNotNull);
    expect(decoded!.numFrames, 6);
    expect(decoded.loopCount, 0);

    // 直接用 Flutter 的图片解码器验证：多帧 WebP 在应用内确实会动。
    final codec = await ui.instantiateImageCodec(normalized.bytes);
    addTearDown(codec.dispose);
    expect(codec.frameCount, 6);
  });

  test('超长动图：抽帧到上限且不截断循环', () {
    final gif = _animatedGif(frameCount: 120, edge: 32, frameMs: 40);
    final normalized = CoverImageCodec.normalizeImageSync(gif);
    final decoded = image.decodeWebP(normalized.bytes);

    expect(decoded, isNotNull);
    expect(
      decoded!.numFrames,
      lessThanOrEqualTo(CoverImageCodec.maxAnimationFrames),
    );
    expect(decoded.numFrames, greaterThan(1));
  });

  test('同一输入重复归一化得到同一份字节（跨设备取色 / 哈希一致）', () {
    final source = image.Image(width: 320, height: 240);
    image.fill(source, color: image.ColorRgb8(10, 200, 30));
    final png = image.encodePng(source);

    final first = CoverImageCodec.normalizeImageSync(png);
    final second = CoverImageCodec.normalizeImageSync(png);
    expect(first.bytes, second.bytes);
  });

  test('AVIF / 未知字节：拒绝并抛 CoverImageException', () {
    // ftyp box 的品牌是 avif；Flutter 桌面 / 旧系统不保证解码，归一化入口
    // 与同步接收侧都不接受。
    final avif = Uint8List.fromList([
      0x00,
      0x00,
      0x00,
      0x1C,
      0x66,
      0x74,
      0x79,
      0x70,
      0x61,
      0x76,
      0x69,
      0x66,
      0x00,
      0x00,
      0x00,
      0x00,
      0x61,
      0x76,
      0x69,
      0x66,
      0x6D,
      0x69,
      0x66,
      0x31,
    ]);
    expect(CoverImageFormats.detect(avif), isNull);
    expect(
      () => CoverImageCodec.normalizeImageSync(avif),
      throwsA(isA<CoverImageException>()),
    );
  });
}

Uint8List _animatedGif({
  required int frameCount,
  required int edge,
  required int frameMs,
}) {
  image.Image? first;
  for (var i = 0; i < frameCount; i++) {
    final frame = image.Image(width: edge, height: edge);
    image.fill(
      frame,
      color: image.ColorRgb8((i * 37) % 255, (i * 71) % 255, (i * 113) % 255),
    );
    frame.frameDuration = frameMs;
    if (first == null) {
      first = frame;
    } else {
      first.addFrame(frame);
    }
  }
  return image.encodeGif(first!, repeat: 0);
}
