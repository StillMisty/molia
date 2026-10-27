import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/poster_lyric_line.dart';
import 'package:molia/services/lyrics_poster_service.dart';
import 'package:material_ui/material_ui.dart';

import '../support/mock_dio.dart';

/// 海报渲染：扩展行（翻译 / 罗马音）与主行同一份数据、按次级字号绘制。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> decode(List<int> bytes) async {
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  Future<Uint8List> render(List<PosterLyricLine> lines, {String? coverUrl}) {
    final service = LyricsPosterService();
    return service.generatePosterData(
      lyrics: lines.map((line) => line.text).join('\n'),
      posterLyricLines: lines,
      trackTitle: 'Title',
      artistName: 'Artist',
      albumCoverUrl: coverUrl,
      backgroundColor: const Color(0xFF101010),
      titleColor: const Color(0xFFFFFFFF),
      artistColor: const Color(0xFFCCCCCC),
      lyricsColor: const Color(0xFFFFFFFF),
      extendedColor: const Color(0xB3FFFFFF),
      watermarkColor: const Color(0x99FFFFFF),
      separatorColor: const Color(0x33FFFFFF),
    );
  }

  /// 生成 [size]×[size] 纯色 PNG：驱动本地封面（文件字节解码）路径。
  Future<Uint8List> pngBytes(Color color, {int size = 512}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..color = color,
    );
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(size, size);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  test('方形封面按 cover 居中裁切，不拉伸', () {
    expect(
      coverCropSourceRect(
        sourceWidth: 200,
        sourceHeight: 100,
        targetWidth: 100,
        targetHeight: 100,
      ),
      const Rect.fromLTWH(50, 0, 100, 100),
      reason: '16:9 源图：裁掉左右，保留中间正方形',
    );
    expect(
      coverCropSourceRect(
        sourceWidth: 100,
        sourceHeight: 200,
        targetWidth: 100,
        targetHeight: 100,
      ),
      const Rect.fromLTWH(0, 50, 100, 100),
      reason: '9:16 源图：裁掉上下',
    );
    expect(
      coverCropSourceRect(
        sourceWidth: 100,
        sourceHeight: 100,
        targetWidth: 100,
        targetHeight: 100,
      ),
      const Rect.fromLTWH(0, 0, 100, 100),
      reason: '方形源图：完整使用',
    );
    expect(
      coverCropSourceRect(
        sourceWidth: 0,
        sourceHeight: 100,
        targetWidth: 100,
        targetHeight: 100,
      ),
      Rect.zero,
    );
  });

  test('主行 + 翻译/罗马音：渲染成功且比无扩展行更高', () async {
    final plain = await render(const [
      PosterLyricLine(text: 'Hello'),
      PosterLyricLine(text: 'World'),
    ]);
    final extended = await render(const [
      PosterLyricLine(text: 'Hello', translation: '你好', roma: 'ni hao'),
      PosterLyricLine(text: 'World', translation: '世界'),
    ]);

    expect(plain, isNotEmpty);
    expect(extended, isNotEmpty);

    final plainImage = await decode(plain);
    final extendedImage = await decode(extended);
    // 同宽：扩展行只增加高度（次级行不改变版心与字号层级）。
    expect(extendedImage.width, plainImage.width);
    expect(extendedImage.height, greaterThan(plainImage.height));
    plainImage.dispose();
    extendedImage.dispose();
  });

  test('本地封面按有界尺寸解码后仍生成海报', () async {
    final dir = await Directory.systemTemp.createTemp('molia_poster_cover');
    addTearDown(() => dir.delete(recursive: true));

    final coverFile = File('${dir.path}/cover.png');
    await coverFile.writeAsBytes(
      await pngBytes(const Color(0xFF00BB00), size: 512),
    );

    final bytes = await render(const [
      PosterLyricLine(text: 'Hello'),
    ], coverUrl: coverFile.uri.toString());
    expect(bytes, isNotEmpty);

    final image = await decode(bytes);
    addTearDown(image.dispose);
    expect(image.width, 1440, reason: '有界解码不改变海报成品宽度');

    // 封面仍按 cover 裁切绘制在左上角：取封面中心像素应为封面绿色。
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixelOffset = (180 * image.width + 164) * 4;
    final r = raw!.getUint8(pixelOffset);
    final g = raw.getUint8(pixelOffset + 1);
    final b = raw.getUint8(pixelOffset + 2);
    expect(g, greaterThan(100), reason: '本地封面应被绘制到海报上');
    expect(r, lessThan(80));
    expect(b, lessThan(80));
  });

  test('封面下载超时后回退无封面版式，不阻塞海报生成', () async {
    // 永不完成的响应：只有实例注入的 20ms 超时能让等待结束。
    // 不用 Future.delayed，避免测试结束后留下悬挂 Timer。
    final stalled = Completer<ResponseBody>();
    final service = LyricsPosterService(
      dio: mockDio((_) => stalled.future),
      networkTimeout: const Duration(milliseconds: 20),
    );

    final stopwatch = Stopwatch()..start();
    final bytes = await service.generatePosterData(
      lyrics: 'Hello',
      posterLyricLines: const [PosterLyricLine(text: 'Hello')],
      trackTitle: 'Title',
      artistName: 'Artist',
      albumCoverUrl: 'https://example.com/stall.jpg',
      backgroundColor: const Color(0xFF101010),
      titleColor: const Color(0xFFFFFFFF),
      artistColor: const Color(0xFFCCCCCC),
      lyricsColor: const Color(0xFFFFFFFF),
      extendedColor: const Color(0xB3FFFFFF),
      watermarkColor: const Color(0x99FFFFFF),
      separatorColor: const Color(0x33FFFFFF),
    );
    stopwatch.stop();

    expect(bytes, isNotEmpty, reason: '超时后应走无封面回退版式继续生成');
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: '等待应止于注入的 20ms 超时，而不是默认的 15s',
    );

    final image = await decode(bytes);
    addTearDown(image.dispose);
    expect(image.width, 1440);
  });
}
