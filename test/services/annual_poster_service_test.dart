import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/services/annual_poster_service.dart';
import 'package:molia/theme/poster_palette.dart';

const _palette = PosterPalette(
  background: Color(0xFF102030),
  title: Color(0xFFF0F4F8),
  artist: Color(0xFF9CC7FF),
  lyrics: Color(0xFFE0E8F2),
  extended: Color(0xFFB6C4D6),
  watermark: Color(0xFF8FA3BA),
  separator: Color(0xFF40566E),
);

AnnualPosterData _data({String track = 'Track'}) => AnnualPosterData(
  yearLabel: '2026',
  subtitle: 'Yearly listening report',
  listenedLabel: '120 小时 30 分钟',
  listenedCaption: 'listened this year',
  playsLabel: '321',
  playsCaption: 'Plays',
  artistsLabel: '88',
  artistsCaption: 'Artists',
  streakLabel: '7',
  streakCaption: 'days in a row',
  months: const [1, 0, 2, 3, 0, 4, 5, 0, 6, 7, 8, 9],
  topArtists: const ['Artist A', 'Artist B', 'Artist C'],
  topTracks: [track, 'Second track', 'Third track'],
  topPlatform: 'Most used: 网易云',
);

Future<ui.Image> _decode(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final frame = await codec.getNextFrame();
  return frame.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('渲染 1440×1920 PNG，字节非空', () async {
    final bytes = await AnnualPosterService().render(
      data: _data(),
      palette: _palette,
    );
    expect(bytes, isNotEmpty);
    final image = await _decode(bytes);
    expect(image.width, 1440);
    expect(image.height, 1920);
    image.dispose();
  });

  test('超长标题仍按固定尺寸渲染', () async {
    final bytes = await AnnualPosterService().render(
      data: _data(track: '很长的歌曲标题' * 20),
      palette: _palette,
    );
    final image = await _decode(bytes);
    expect(image.width, 1440);
    expect(image.height, 1920);
    image.dispose();
  });

  test('精简数据（无专辑 / 无平台 / 单曲）仍能渲染', () async {
    final bytes = await AnnualPosterService().render(
      data: AnnualPosterData(
        yearLabel: '2025',
        subtitle: 'Yearly listening report',
        listenedLabel: '1 分钟',
        listenedCaption: 'listened this year',
        playsLabel: '1',
        playsCaption: 'Plays',
        artistsLabel: '1',
        artistsCaption: 'Artists',
        streakLabel: '1',
        streakCaption: 'days in a row',
        months: const [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      ),
      palette: _palette,
    );
    final image = await _decode(bytes);
    expect(image.width, 1440);
    expect(image.height, 1920);
    image.dispose();
  });

  test('背景色实际绘制到成品', () async {
    final bytes = await AnnualPosterService().render(
      data: _data(),
      palette: _palette,
    );
    final image = await _decode(bytes);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);
    final bytesData = data!.buffer.asUint8List();
    // 左上角（避开内容文本）应接近海报底色。
    final offset = (10 * image.width + 10) * 4;
    expect(bytesData[offset + 3], 255);
    expect(bytesData[offset], closeTo(0x10, 2));
    expect(bytesData[offset + 1], closeTo(0x20, 2));
    expect(bytesData[offset + 2], closeTo(0x30, 2));
    image.dispose();
  });
}
