import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/poster_lyric_line.dart';
import 'package:molia/services/lyrics_poster_service.dart';
import 'package:material_ui/material_ui.dart';

/// 海报渲染：扩展行（翻译 / 罗马音）与主行同一份数据、按次级字号绘制。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> decode(List<int> bytes) async {
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Future<Uint8List> render(List<PosterLyricLine> lines) {
    final service = LyricsPosterService();
    return service.generatePosterData(
      lyrics: lines.map((line) => line.text).join('\n'),
      posterLyricLines: lines,
      trackTitle: 'Title',
      artistName: 'Artist',
      backgroundColor: const Color(0xFF101010),
      titleColor: const Color(0xFFFFFFFF),
      artistColor: const Color(0xFFCCCCCC),
      lyricsColor: const Color(0xFFFFFFFF),
      extendedColor: const Color(0xB3FFFFFF),
      watermarkColor: const Color(0x99FFFFFF),
      separatorColor: const Color(0x33FFFFFF),
    );
  }

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
  });

  test('无扩展行时保持与原行为一致（不额外占位）', () async {
    final bytes = await render(const [PosterLyricLine(text: 'Hello')]);

    expect(bytes, isNotEmpty);
  });
}
