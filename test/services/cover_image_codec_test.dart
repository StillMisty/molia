import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import 'package:molia/services/covers/cover_image_codec.dart';

void main() {
  test('最长边缩到 1024，输出 JPEG', () {
    final source = image.Image(width: 2000, height: 1000);
    image.fill(source, color: image.ColorRgb8(20, 120, 220));
    final png = Uint8List.fromList(image.encodePng(source));

    final normalized = CoverImageCodec.normalizeSync(png);
    final decoded = image.decodeJpg(normalized);
    expect(decoded, isNotNull);
    expect(decoded!.width, CoverImageCodec.maxEdge);
    expect(decoded.height, 512);
  });

  test('小图保持原尺寸；EXIF 方向被烘焙（像素已摆正）', () {
    final source = image.Image(width: 40, height: 20);
    final png = Uint8List.fromList(image.encodePng(source));
    final normalized = CoverImageCodec.normalizeSync(png);
    final decoded = image.decodeJpg(normalized)!;
    expect(decoded.width, 40);
    expect(decoded.height, 20);
  });

  test('不可读字节抛 CoverImageException', () {
    expect(
      () => CoverImageCodec.normalizeSync(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<CoverImageException>()),
    );
  });

  test('空字节在 isolate 入口直接失败', () async {
    expect(
      CoverImageCodec.normalize(Uint8List(0)),
      throwsA(isA<CoverImageException>()),
    );
  });
}
