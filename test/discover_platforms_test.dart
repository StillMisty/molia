import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/crypto_utils.dart';
import 'package:molia/sources/builtin/discover_source.dart';
import 'package:molia/sources/builtin/discover_track_mapper.dart';
import 'package:molia/sources/builtin/kg_discover.dart';
import 'package:molia/sources/builtin/kw_discover.dart';
import 'package:molia/sources/builtin/mg_discover.dart';
import 'package:molia/sources/builtin/tx_discover.dart';
import 'package:molia/sources/lx/lx_native_utils.dart';
import 'package:molia/sources/source_track.dart';

/// 多平台「发现」模块单测：注册表 + 各平台解析器（离线夹具）。
void main() {
  group('BuiltinDiscover 注册表', () {
    test('五平台注册且静态榜单表非空', () {
      expect(BuiltinDiscover.sourceKeys, ['wy', 'tx', 'kg', 'kw', 'mg']);
      for (final key in BuiltinDiscover.sourceKeys) {
        final source = BuiltinDiscover.of(key);
        expect(source.sourceKey, key);
        expect(source.supportsLeaderboards, isTrue, reason: key);
        expect(source.leaderboards, isNotEmpty, reason: key);
      }
    });

    test('未知平台抛 UnsupportedError', () {
      expect(() => BuiltinDiscover.of('nope'), throwsUnsupportedError);
    });
  });

  group('discoverTrackOf 映射', () {
    test('songId 取键优先级与 SourceTrack.id 一致', () {
      final track = SourceTrack(
        sourceKey: 'kg',
        origin: 'builtin',
        title: 'T',
        artist: 'A',
        album: 'B',
        duration: const Duration(seconds: 30),
        raw: {'songmid': 42, 'hash': 'h'},
      );
      final discover = discoverTrackOf(track);
      expect(discover.sourceKey, 'kg');
      expect(discover.songId, '42');
      expect(discover.durationMs, 30000);
      expect(discover.raw['hash'], 'h');
    });
  });

  group('QQ 音乐解析', () {
    test('标签目录 / 热门标签 HTML / 热搜词', () {
      final categories = TxDiscoverSource.filterTagInfo([
        {
          'group_name': '语种',
          'v_item': [
            {'id': 1, 'name': '华语'},
            {'id': 2, 'name': '欧美'},
          ],
        },
      ]);
      expect(categories.single.name, '语种');
      expect(categories.single.tags.map((t) => t.id).toList(), ['1', '2']);

      const html = '<div><a class="c_bg_link js_tag_item" data-id="3317">'
          '官方歌单</a> <a class="c_bg_link js_tag_item" data-id="3418">'
          '免费热歌</a></div>';
      final hotTags = TxDiscoverSource.filterInfoHotTag(html);
      expect(hotTags.map((t) => t.name).toList(), ['官方歌单', '免费热歌']);
      expect(hotTags.first.id, '3317');

      final words = TxDiscoverSource.filterHotSearch([
        {'query': '茶汤 郁可唯'},
        {'query': ''},
        {'other': 1},
      ]);
      expect(words, ['茶汤 郁可唯']);
    });
  });

  group('酷我解析', () {
    test('歌单列表：digest 前缀 id / 播放量', () {
      final list = KwDiscoverSource.filterList([
        {
          'digest': '8',
          'id': 123,
          'name': '歌单',
          'uname': '作者',
          'listencnt': 12034,
          'total': 5,
          'img': 'http://img/x.jpg',
        },
      ]);
      final playlist = list.single;
      expect(playlist.id, 'digest-8__123');
      expect(playlist.name, '歌单');
      expect(playlist.playCount, 12034);
      expect(playlist.trackCount, 5);
    });

    test('标签 / 热门标签：`{id}-{digest}` 组合 id', () {
      final categories = KwDiscoverSource.filterTagInfo([
        {
          'name': '风格',
          'data': [
            {'id': '100', 'digest': '10000', 'name': '流行'},
          ],
        },
      ]);
      expect(categories.single.tags.single.id, '100-10000');

      final hot = KwDiscoverSource.filterInfoHotTag([
        {'id': '200', 'digest': '43', 'name': '短视频'},
      ]);
      expect(hot.single.id, '200-43');
    });

    test('歌单详情曲目：N_MINFO 音质解析 + 歌手 & → 、', () {
      final tracks = KwDiscoverSource.filterListDetail([
        {
          'id': 1,
          'name': '歌曲',
          'artist': 'A&B',
          'album': '专辑',
          'albumid': 2,
          'duration': 200,
          'N_MINFO':
              'level:ff,bitrate:320,format:mp3,size:1.2M;'
                  'level:f,bitrate:2000,format:flac,size:20M',
        },
      ]);
      final track = tracks.single;
      expect(track.artist, 'A、B');
      expect(track.duration, const Duration(seconds: 200));
      // kLxQualityOrder 为高音质在前
      expect(track.qualities.map((q) => q.type).toList(), ['flac', '320k']);
      expect(track.raw['songmid'], '1');
      expect(track.raw['_types'], contains('flac'));
    });

    test('榜单曲目：n_minfo 音质解析', () {
      final track = KwDiscoverSource.filterDataItem({
        'id': 933,
        'name': '歌 & 名',
        'artist': '任夏',
        'album': '专辑',
        'albumId': 5,
        'duration': 212,
        'pic': 'http://img/p.jpg',
        'n_minfo': 'level:ff,bitrate:128,format:mp3,size:3.1M;'
            'level:f,bitrate:4000,format:flac,size:40M',
      });
      expect(track, isNotNull);
      expect(track!.title, '歌 & 名');
      expect(track.raw['songmid'], '933');
      expect(track.raw['_types'], contains('flac24bit'));
    });

    test('伪 JSON 转换（search.kuwo.cn 响应）', () {
      final parsed = KwDiscoverSource.objStr2JSON(
        "{'ARTISTPIC':'','HIT':'143','list':[{'a':'b','c':1}],'TOTAL':'2'}",
      ) as Map;
      expect(parsed['HIT'], '143');
      expect((parsed['list'] as List).single, {'a': 'b', 'c': 1});
    });

    test('wbd 加密参数可逆（AES-128-ECB + sign）', () {
      final param = kwWbdBuildParam({'id': '93', 'rn': 3}, time: 1700000000000);
      final query = Uri.splitQueryString(param);
      expect(query['appId'], kwWbdAppId);
      expect(query['time'], '1700000000000');
      final encrypted = Uri.decodeComponent(query['data']!);
      expect(
        query['sign'],
        md5Hex('$kwWbdAppId${encrypted}1700000000000').toUpperCase(),
      );
      // 用同一密钥加密一段响应，验证解码链路
      final key = base64.decode(kwWbdKeyBase64);
      final cipherBytes = LxNativeUtils.aesEncrypt(
        Uint8List.fromList(utf8.encode('{"code":200,"data":{"musiclist":[]}}')),
        'aes-128-ecb',
        key,
        null,
      );
      final decoded =
          kwWbdDecodeData(base64.encode(cipherBytes)) as Map;
      expect(decoded['code'], 200);
    });
  });

  group('酷狗解析', () {
    test('标签：hotTag + tagids 分类', () {
      final hot = KgDiscoverSource.filterInfoHotTag({
        'status': 1,
        'data': {
          'a': {'special_id': 111, 'special_name': '经典'},
        },
      });
      expect(hot.single.id, '111');
      expect(hot.single.name, '经典');

      final categories = KgDiscoverSource.filterTagInfo({
        '主题': {
          'data': [
            {'id': '222', 'name': '影视'},
          ],
        },
      });
      expect(categories.single.name, '主题');
      expect(categories.single.tags.single.id, '222');
    });

    test('榜单曲目：hash/音质/歌手', () {
      final track = KgDiscoverSource.filterDataItem({
        'songname': '勇气',
        'authors': [
          {'author_name': '梁静茹'},
        ],
        'remark': '专辑',
        'album_id': 9,
        'audio_id': 88,
        'duration': 240,
        'filesize': 3 * 1024 * 1024,
        'hash': 'h128',
        '320filesize': 8 * 1024 * 1024,
        '320hash': 'h320',
        'sqfilesize': 0,
        'sqhash': '',
        'filesize_high': 20 * 1024 * 1024,
        'hash_high': 'hhigh',
      });
      expect(track, isNotNull);
      expect(track!.artist, '梁静茹');
      expect(track.raw['hash'], 'h128');
      expect(track.raw['_types'], contains('flac24bit'));
      expect(track.raw['_types'], isNot(contains('flac')));
    });

    test('gateway 曲目：audio_info/album_info（毫秒时长）', () {
      final track = KgDiscoverSource.filterData2Item({
        'songname': '歌',
        'author_name': '歌手',
        'album_info': {'album_name': '专辑', 'album_id': 3},
        'audio_info': {
          'audio_id': 7,
          'hash': 'h',
          'timelength': 212000,
          'filesize': 1024 * 1024,
          'hash_320': 'h320',
          'filesize_320': 2 * 1024 * 1024,
        },
      });
      expect(track, isNotNull);
      expect(track!.duration, const Duration(milliseconds: 212000));
      expect(track.raw['songmid'], '7');
      expect(track.raw['_types'], contains('320k'));
    });

    test('歌单列表/搜索结果：id_ 前缀', () {
      final item = KgDiscoverSource.filterListItem({
        'specialid': 6409645,
        'specialname': '歌单',
        'nickname': '作者',
        'total_play_count': '1712.8万',
        'songcount': 154,
      });
      expect(item, isNotNull);
      expect(item!.id, 'id_6409645');
      expect(item.trackCount, 154);

      final search = KgDiscoverSource.filterSearchItem({
        'specialid': 5,
        'specialname': '搜索歌单',
      });
      expect(search!.id, 'id_5');
    });
  });

  group('咪咕解析', () {
    test('标签：texts [name, id] 结构', () {
      final tags = MgDiscoverSource.filterTagInfo([
        {
          'content': [
            {'texts': ['网络热歌', '1001076096', '%E7%BD%91%E7%BB%9C']},
          ],
        },
        {
          'header': {'title': '风格'},
          'content': [
            {'texts': ['流行', '1000001672']},
          ],
        },
      ]);
      expect(tags.hotTags.single.name, '网络热歌');
      expect(tags.hotTags.single.id, '1001076096');
      expect(tags.categories.single.name, '风格');
      expect(tags.categories.single.tags.single.id, '1000001672');
    });

    test('嵌套歌单内容：resType 2021 递归提取', () {
      final list = MgDiscoverSource.filterList2([
        {
          'contents': [
            {
              'resType': '2021',
              'resId': 11,
              'txt': '歌单一',
              'img': 'http://img/1.jpg',
            },
            {
              'contents': [
                {'resType': '2021', 'resId': 12, 'txt': '歌单二'},
                {'resType': '2021', 'resId': 11, 'txt': '重复'},
              ],
            },
          ],
        },
      ]);
      expect(list.map((p) => p.id).toList(), ['11', '12']);
      expect(list.first.name, '歌单一');
    });

    test('榜单曲目：newRateFormats + mm:ss 时长', () {
      final tracks = MgDiscoverSource.filterMusicInfoList([
        {
          'songId': 'song1',
          'copyrightId': 'c1',
          'songName': '起风了',
          'artists': [
            {'name': '周深'},
          ],
          'album': '专辑',
          'albumId': 'a1',
          'length': '05:12',
          'albumImgs': [
            {'img': '/data/x.jpg'},
          ],
          'newRateFormats': [
            {'formatType': 'PQ', 'size': 1024 * 1024},
            {'formatType': 'SQ', 'size': 10 * 1024 * 1024},
          ],
        },
      ]);
      final track = tracks.single;
      expect(track.title, '起风了');
      expect(track.duration, const Duration(minutes: 5, seconds: 12));
      expect(track.coverUrl, 'http://d.musicapp.migu.cn/data/x.jpg');
      expect(track.qualities.map((q) => q.type).toList(), ['flac', '128k']);
      expect(track.raw['copyrightId'], 'c1');
    });

    test('歌单详情曲目：audioFormats + duration 秒', () {
      final tracks = MgDiscoverSource.filterMusicInfoListV5([
        {
          'songId': 'song2',
          'copyrightId': 'c2',
          'songName': '歌',
          'singerList': [
            {'name': 'A'},
            {'name': 'B'},
          ],
          'album': '专辑',
          'duration': 245,
          'img1': 'https://img/1.jpg',
          'audioFormats': [
            {'formatType': 'HQ', 'androidSize': 5 * 1024 * 1024},
          ],
        },
      ]);
      final track = tracks.single;
      expect(track.artist, 'A、B');
      expect(track.duration, const Duration(seconds: 245));
      expect(track.qualities.map((q) => q.type).toList(), ['320k']);
    });

    test('歌单搜索结果', () {
      final list = MgDiscoverSource.filterSongListResult([
        {
          'id': '77',
          'name': '歌单',
          'userName': '作者',
          'musicListPicUrl': 'https://img/2.jpg',
          'playNum': '123456',
          'musicNum': '20',
        },
      ]);
      expect(list.single.id, '77');
      expect(list.single.trackCount, 20);
    });
  });
}
