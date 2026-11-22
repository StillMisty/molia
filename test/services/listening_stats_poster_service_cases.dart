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

ListeningStatsPosterRow _row(String title, String subtitle) =>
    ListeningStatsPosterRow(title: title, subtitle: subtitle);

List<int> _weekdayHour() => List<int>.generate(
  168,
  (index) => index % 24 == 0 ? 0 : ((index * 37) % 1000) * 1000,
);

ListeningStatsPosterData _data({
  ListeningStatsPosterRow? track,
  List<ListeningStatsPosterRow>? topTracks,
  List<ListeningStatsPosterRow>? topArtists,
  List<int>? weekdayHour,
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
  completionLabel: '78%',
  completionCaption: '完整播放率',
  topTracksTitle: '最常听',
  topTracks:
      topTracks ??
      [
        track ?? _row('晴天', '周杰伦 · 12 次 · 42 分钟'),
        _row('七里香', '周杰伦 · 10 次 · 38 分钟'),
        _row('夜曲', '周杰伦 · 9 次 · 35 分钟'),
        _row('稻香', '周杰伦 · 8 次 · 31 分钟'),
        _row('搁浅', '周杰伦 · 7 次 · 28 分钟'),
      ],
  topArtistsTitle: '常听歌手',
  topArtists:
      topArtists ??
      [
        _row('周杰伦', '46 次 · 2 小时 54 分钟'),
        _row('陈奕迅', '36 次 · 2 小时 12 分钟'),
        _row('林俊杰', '31 次 · 1 小时 58 分钟'),
        _row('五月天', '28 次 · 1 小时 44 分钟'),
        _row('孙燕姿', '24 次 · 1 小时 31 分钟'),
      ],
  weekdayHourTitle: '收听时段',
  weekdayLabels: const ['一', '二', '三', '四', '五', '六', '日'],
  weekdayHour: weekdayHour ?? _weekdayHour(),
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

  test('超长标题 / 曲目 / 歌手仍按固定尺寸渲染（单行省略）', () async {
    final bytes = await const ListeningStatsPosterService().render(
      data: _data(
        track: _row('很长的歌曲标题' * 30, '长歌手 · 999 次 · 999 小时 59 分钟' * 10),
        topTracks: [
          for (var i = 0; i < 8; i++)
            _row('长标题 $i' * 30, '长歌手 $i · 999 次 · 999 小时' * 10),
        ],
        topArtists: [
          for (var i = 0; i < 8; i++)
            _row('很长的歌手名 $i' * 30, '999 次 · 999 小时' * 10),
        ],
      ),
      palette: _palette,
    );
    final image = await _decode(bytes);
    expect(image.width, 1440);
    expect(image.height, 1920);
    image.dispose();
  });

  test('热力图数据不完整时省略该块，不影响固定尺寸', () async {
    final bytes = await const ListeningStatsPosterService().render(
      data: _data(weekdayHour: const [1, 2, 3]),
      palette: _palette,
    );
    final image = await _decode(bytes);
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
