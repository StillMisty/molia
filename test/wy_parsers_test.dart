import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/wy_hot_search.dart';
import 'package:molia/sources/builtin/wy_leaderboard.dart';
import 'package:molia/sources/builtin/wy_lyric.dart';
import 'package:molia/sources/builtin/wy_music_detail.dart';
import 'package:molia/sources/builtin/wy_songlist.dart';

/// 网易云解析器单测（合成结构，对照 lx-music-mobile 的 wy/*.js 语义）。
void main() {
  group('WyMusicDetail.filterList（musicDetail.js）', () {
    final song = {
      'id': 111,
      'name': '歌曲A',
      'dt': 245000,
      'ar': [
        {'name': '歌手1'},
        {'name': '歌手2'},
      ],
      'al': {
        'id': 9,
        'name': '专辑',
        'picUrl': 'https://p1.music.126.net/x.jpg',
      },
      'hr': {'size': 50 * 1024 * 1024},
      'sq': {'size': 20 * 1024 * 1024},
      'h': {'size': 8 * 1024 * 1024},
      'l': {'size': 3 * 1024 * 1024},
    };

    test('privilege 对齐：音质（hires 全档）、歌手、封面、时长', () {
      final tracks = WyMusicDetail.filterList(
        songs: [song],
        privileges: [
          {'id': 111, 'maxbr': 999000, 'maxBrLevel': 'hires'},
        ],
      );
      expect(tracks, hasLength(1));
      final track = tracks.first;
      expect(track.sourceKey, 'wy');
      expect(track.title, '歌曲A');
      expect(track.artist, '歌手1、歌手2');
      expect(track.album, '专辑');
      expect(track.coverUrl, 'https://p1.music.126.net/x.jpg');
      expect(track.duration, const Duration(milliseconds: 245000));
      expect(
        track.qualities.map((q) => q.type).toList(),
        ['flac24bit', 'flac', '320k', '128k'],
      );
      expect(track.raw['songmid'], 111);
      expect(track.raw['interval'], '04:05');
      // types 按 LX 在 push 后 reverse
      expect(
        (track.raw['types'] as List).map((t) => t['type']).toList(),
        ['128k', '320k', 'flac', 'flac24bit'],
      );
      expect(track.raw['_types'], isA<Map>());
    });

    test('privilege 顺序不一致时按 id 查找；缺失时跳过', () {
      final tracks = WyMusicDetail.filterList(
        songs: [song],
        privileges: [
          {'id': 999, 'maxbr': 320000},
          {'id': 111, 'maxbr': 320000},
        ],
      );
      expect(tracks, hasLength(1));
      expect(
        tracks.first.qualities.map((q) => q.type).toList(),
        ['320k', '128k'],
      );

      final skipped = WyMusicDetail.filterList(
        songs: [song],
        privileges: [
          {'id': 999, 'maxbr': 320000},
        ],
      );
      expect(skipped, isEmpty);
    });

    test('pc 字段优先（歌单详情里的替代命名）', () {
      final tracks = WyMusicDetail.filterList(
        songs: [
          {
            'id': 222,
            'name': '原名',
            'dt': 0,
            'pc': {'ar': 'PC歌手', 'sn': 'PC歌名', 'alb': 'PC专辑'},
            'al': {'id': 1, 'picUrl': ''},
          },
        ],
        privileges: [
          {'id': 222, 'maxbr': 128000},
        ],
      );
      expect(tracks.first.title, 'PC歌名');
      expect(tracks.first.artist, 'PC歌手');
      expect(tracks.first.album, 'PC专辑');
      expect(tracks.first.coverUrl, isNull);
      // dt=0 时 interval 为 LX 的占位文案
      expect(tracks.first.raw['interval'], '--/--');
    });
  });

  group('WyLeaderboard（leaderboard.js）', () {
    test('静态榜单表完整（42 个）且 id 唯一', () {
      expect(WyLeaderboard.boards, hasLength(42));
      expect(WyLeaderboard.boards.first.name, '飙升榜');
      expect(WyLeaderboard.boards.first.bangid, '19723756');
      expect(WyLeaderboard.boards.first.id, 'wy__19723756');
      final ids = WyLeaderboard.boards.map((b) => b.id).toSet();
      expect(ids, hasLength(WyLeaderboard.boards.length));
      final hot = WyLeaderboard.boards
          .where((b) => b.name == '热歌榜')
          .toList();
      expect(hot, hasLength(1));
      expect(hot.first.bangid, '3778678');
    });
  });

  group('WySongList（songList.js）', () {
    test('filterList：歌单概要字段与播放量格式化', () {
      final list = WySongList.filterList([
        {
          'id': 123,
          'name': '歌单',
          'coverImgUrl': 'https://p1.music.126.net/p.jpg',
          'creator': {'nickname': '作者'},
          'playCount': 25000,
          'trackCount': 10,
          'description': '简介',
          'createTime': DateTime(2024, 5, 6).millisecondsSinceEpoch,
        },
      ]);
      expect(list, hasLength(1));
      final playlist = list.first;
      expect(playlist.id, '123');
      expect(playlist.name, '歌单');
      expect(playlist.author, '作者');
      expect(playlist.trackCount, 10);
      expect(playlist.playCount, 25000);
      expect(playlist.playCountText, '2.5万');
      expect(playlist.createdAt, '2024-05-06');
    });

    test('filterTagInfo：按 categories 分组', () {
      final categories = WySongList.filterTagInfo(
        sub: [
          {'category': 0, 'name': '流行'},
          {'category': 0, 'name': '摇滚'},
          {'category': 1, 'name': '古典'},
        ],
        categories: {0: '语种', 1: '风格'},
      );
      expect(categories, hasLength(2));
      expect(categories[0].name, '语种');
      expect(categories[0].tags.map((t) => t.id).toList(), ['流行', '摇滚']);
      expect(categories[1].name, '风格');
      expect(categories[1].tags.single.name, '古典');
    });

    test('filterHotTagInfo：playlistTag.name', () {
      final tags = WySongList.filterHotTagInfo([
        {
          'playlistTag': {'name': '华语'}
        },
        {
          'playlistTag': {'name': '电子'}
        },
      ]);
      expect(tags.map((t) => t.name).toList(), ['华语', '电子']);
    });

    test('parseListId：链接 / ID / id###token', () async {
      expect(
        (await WySongList.parseListId(
                'https://music.163.com/playlist?id=123456&userid=1'))
            .id,
        '123456',
      );
      expect(
        (await WySongList.parseListId('https://music.163.com/#/playlist?id=42'))
            .id,
        '42',
      );
      expect(
        (await WySongList.parseListId(
                'https://music.163.com/playlist/789/123456789/?_hash=x'))
            .id,
        '789',
      );
      expect((await WySongList.parseListId('987')).id, '987');

      final withToken = await WySongList.parseListId('123456###token-abc');
      expect(withToken.id, '123456');
      expect(withToken.cookie, 'MUSIC_U=token-abc');
    });

    test('filterListDetail：flac size 固定 null + 歌手实体解码', () {
      final tracks = WySongList.filterListDetail(
        tracks: [
          {
            'id': 1,
            'name': '歌',
            'dt': 200000,
            'ar': [
              {'name': 'A&amp;B'},
              {'name': 'C'},
            ],
            'al': {'id': 2, 'name': '专', 'picUrl': 'p.jpg'},
            'sq': {'size': 20 * 1024 * 1024},
            'h': {'size': 8 * 1024 * 1024},
            'l': {'size': 3 * 1024 * 1024},
          },
        ],
        privileges: [
          {'id': 1, 'maxbr': 999000},
        ],
      );
      expect(tracks, hasLength(1));
      expect(tracks.first.artist, 'A&B、C');
      expect(tracks.first.qualities.map((q) => q.type).toList(),
          ['flac', '320k', '128k']);
      final flac =
          tracks.first.raw['_types']['flac'] as Map<String, dynamic>;
      expect(flac['size'], isNull);
    });
  });

  group('WyHotSearch（hotSearch.js）', () {
    test('filterList：仅保留 searchWord', () {
      final words = WyHotSearch.filterList([
        {'searchWord': '晴天'},
        {'searchWord': ''},
        {'other': 'x'},
        {'searchWord': '夜曲'},
      ]);
      expect(words, ['晴天', '夜曲']);
    });
  });

  group('WyLyricParser（lyric.js parseTools）', () {
    test('msFormat：默认三位毫秒 / pad3=false 两位', () {
      expect(WyLyricParser.msFormat(2500), '[00:02.500]');
      expect(WyLyricParser.msFormat(2500, pad3: false), '[00:02.50]');
      expect(WyLyricParser.msFormat(65000), '[01:05.000]');
      expect(WyLyricParser.msFormat(65000, pad3: false), '[01:05.00]');
    });

    test('parseHeaderInfo：JSON 行转时间标签，非 JSON 行原样保留', () {
      final lines = WyLyricParser.parseHeaderInfo(
        '[00:01.00]hello\n'
        '{"t":2500,"c":[{"tx":"你"},{"tx":"好"}]}\n'
        '[offset:0]',
      );
      expect(lines, [
        '[00:01.00]hello',
        '[00:02.50]你好',
        '[offset:0]',
      ]);
    });

    test('parseLyric：yrc 行 → LRC + LX 逐字（相对行首时间）', () {
      final result = WyLyricParser.parseLyric([
        '[1000,2000](0,500,0)Hello (500,1500,0)world',
        '[offset:0]',
      ]);
      expect(result.lyric, '[00:01.000]Hello world\n[offset:0]');
      expect(
        result.lxlyric,
        '[00:01.000]<0,500>Hello <0,1500>world\n[offset:0]',
      );
    });

    test('getIntv：与 LX 相同的 [m,s,ms] 权重（相对比较用）', () {
      // 注意：LX 实现按 m*3600000 + s*1000 + ms 计算（fixTimeTag 只比较差值）。
      expect(WyLyricParser.getIntv('01:02.500'), 3602500);
      expect(WyLyricParser.getIntv('2:03'), 7203000);
      expect(WyLyricParser.getIntv('5'), 5000);
      expect(WyLyricParser.getIntv(''), 0);
    });

    test('fixTimeTag：翻译行按 <100ms 对齐原文时间标签', () {
      final result = WyLyricParser.fixTimeTag(
        '[00:01.05]hello\n[00:03.00]skip\n[00:04.00]world',
        '[00:01.00]你好\n[00:04.00]世界',
      );
      expect(result, '[00:01.05]你好\n[00:04.00]世界');
    });

    test('fixTimeLabel：三段时间标签修正（含罗马音两位毫秒尾零）', () {
      final fixed = WyLyricParser.fixTimeLabel(
        '[00:01:50]a',
        '[00:01:50]b',
        '[00:01:500]c',
      );
      expect(fixed.lrc, '[00:01.50]a');
      expect(fixed.tlrc, '[00:01.50]b');
      expect(fixed.romalrc, '[00:01.50]c');

      final untouched = WyLyricParser.fixTimeLabel('[00:01.50]a', null, null);
      expect(untouched.lrc, '[00:01.50]a');
      expect(untouched.tlrc, isNull);
    });

    test('parse：yrc 分支（元数据头 + 逐字 + 翻译对齐）', () {
      final info = WyLyricParser.parse(
        ylrc: '{"t":100,"c":[{"tx":"作词"},{"tx":" : 某人"}]}\n'
            '[1000,2000](0,500,0)Hello (500,1500,0)world\n'
            '[offset:0]',
        ytlrc: '[00:01.000]你好世界',
        lrc: '[00:09.00]不应使用',
        tlrc: '[00:09.00]不应使用',
      );
      expect(
        info.lyric,
        '[00:00.100]作词 : 某人\n[00:01.000]Hello world\n[offset:0]',
      );
      expect(info.lxlyric, '[00:01.000]<0,500>Hello <0,1500>world\n[offset:0]');
      expect(info.tlyric, '[00:01.000]你好世界');
    });

    test('parse：无 yrc 时回退 lrc/tlrc/rlrc', () {
      final info = WyLyricParser.parse(
        lrc: '[00:01.00]Hello\n[00:02.00]World',
        tlrc: '[00:01.00]你好\n[00:02.00]世界',
        rlrc: '[00:01.00]konnichiwa',
      );
      expect(info.lyric, '[00:01.00]Hello\n[00:02.00]World');
      expect(info.tlyric, '[00:01.00]你好\n[00:02.00]世界');
      expect(info.rlyric, '[00:01.00]konnichiwa');
      expect(info.lxlyric, isEmpty);
      expect(info.isEmpty, isFalse);
    });
  });
}
