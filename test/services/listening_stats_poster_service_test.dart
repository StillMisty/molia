import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/services/listening_stats_poster_service.dart';
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

ListeningStatsPosterData _data({
  String track = '晴天 — 周杰伦',
  List<String>? topTracks,
  List<String>? topArtists,
  String? platform = '最常使用 网易云',
}) => ListeningStatsPosterData(
  title: '听歌记录',
  rangeLabel: '近 30 天',
  listenedLabel: '42 小时 18 分钟',
  listenedCaption: '收听时长',
  playsLabel: '320',
  playsCaption: '有效播放',
  tracksLabel: '128',
  tracksCaption: '听过曲目',
  topTracksTitle: '最常听',
  topTracks:
      topTracks ?? [track, '七里香 — 周杰伦', '夜曲 — 周杰伦', '稻香 — 周杰伦', '搁浅 — 周杰伦'],
  topArtistsTitle: '常听歌手',
  topArtists: topArtists ?? const ['周杰伦', '陈奕迅', '林俊杰', '五月天', '孙燕姿'],
  platformLabel: platform,
);

Future<ui.Image> _decode(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final frame = await codec.getNextFrame();
  return frame.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('渲染 1440×1920 PNG，字节非空', () async {
    final bytes = await const ListeningStatsPosterService().render(
      data: _data(),
      palette: _palette,
    );
    expect(bytes, isNotEmpty);
    final image = await _decode(bytes);
    expect(image.width, 1440);
    expect(image.height, 1920);
    image.dispose();
  });

  test('超长标题 / 曲目 / 歌手仍按固定尺寸渲染（省略号截断）', () async {
    final bytes = await const ListeningStatsPosterService().render(
      data: _data(
        track: '很长的歌曲标题' * 30,
        topTracks: [for (var i = 0; i < 8; i++) '长标题 $i — 长歌手' * 20],
        topArtists: [for (var i = 0; i < 8; i++) '很长的歌手名 $i' * 20],
      ),
      palette: _palette,
    );
    final image = await _decode(bytes);
    expect(image.width, 1440);
    expect(image.height, 1920);
    image.dispose();
  });

  test('精简 / 零数据仍能渲染有效海报（空块省略）', () async {
    final reduced = await const ListeningStatsPosterService().render(
      data: ListeningStatsPosterData(
        title: '听歌记录',
        rangeLabel: '近 7 天',
        listenedLabel: '0 分钟',
        listenedCaption: '收听时长',
        playsLabel: '0',
        playsCaption: '有效播放',
        tracksLabel: '0',
        tracksCaption: '听过曲目',
        topTracksTitle: '最常听',
        topArtistsTitle: '常听歌手',
      ),
      palette: _palette,
    );
    final image = await _decode(reduced);
    expect(image.width, 1440);
    expect(image.height, 1920);
    image.dispose();
  });

  test('渲染过程不发起网络请求', () async {
    final bytes = await HttpOverrides.runZoned(
      () => const ListeningStatsPosterService().render(
        data: _data(),
        palette: _palette,
      ),
      createHttpClient: (_) => throw StateError('海报不应发起网络请求'),
    );
    expect(bytes, isNotEmpty);
  });
}
