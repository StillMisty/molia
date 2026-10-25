import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/kg_search.dart';
import 'package:molia/sources/builtin/kw_search.dart';
import 'package:molia/sources/builtin/mg_search.dart';
import 'package:molia/sources/builtin/wy_music_detail.dart';

/// 各平台共享曲目构建器（搜索 / 榜单 / 歌单详情共用的单一测试面）：
/// 音质解析 + raw musicInfo 约定。
void main() {
  group('KwSearch.parseNMinfo', () {
    test('bitrate → 音质，大小统一大写；未知 bitrate 忽略', () {
      final types = KwSearch.parseNMinfo(
        'level:ff,bitrate:2000,format:flac,size:52.83Mb;'
        'level:p,bitrate:320,format:mp3,size:10.29Mb;'
        'level:x,bitrate:9999,format:zzz,size:1Mb',
      );
      expect(types.keys, containsAll(['flac', '320k']));
      expect(types['flac']!['size'], '52.83MB');
      expect(types['320k']!['size'], '10.29MB');
      expect(types.containsKey('9999'), isFalse);
    });

    test('空串 / 无匹配返回空映射', () {
      expect(KwSearch.parseNMinfo(''), isEmpty);
      expect(KwSearch.parseNMinfo('garbage'), isEmpty);
    });
  });

  group('KgSearch', () {
    test('addKgQuality：缺 size 跳过；无 sizeFormat 值写入', () {
      final types = <String, Map<String, dynamic>>{};
      KgSearch.addKgQuality(types, '128k', size: 1048576, hash: 'h1');
      KgSearch.addKgQuality(types, 'flac', size: null, hash: 'h2');
      KgSearch.addKgQuality(types, '320k', size: 0, hash: 'h3');
      expect(types.keys, ['128k']);
      expect(types['128k']!['size'], '1.00 MiB');
      expect(types['128k']!['hash'], 'h1');
    });

    test('addKgQuality requireHash：缺 hash 跳过', () {
      final types = <String, Map<String, dynamic>>{};
      KgSearch.addKgQuality(types, '128k',
          size: 1048576, hash: null, requireHash: true);
      expect(types, isEmpty);
    });

    test('buildTrack：raw musicInfo 约定 + qualities', () {
      final types = <String, Map<String, dynamic>>{};
      KgSearch.addKgQuality(types, '128k', size: 1048576, hash: 'h1');
      final track = KgSearch.buildTrack(
        songId: 'audio-1',
        name: '歌',
        artist: '歌手',
        album: '专辑',
        albumId: 'alb-1',
        hash: 'top-hash',
        intervalText: '02:00',
        duration: const Duration(minutes: 2),
        types: types,
        rawInterval: 120,
      );
      expect(track.sourceKey, 'kg');
      expect(track.raw['songmid'], 'audio-1');
      expect(track.raw['hash'], 'top-hash');
      expect(track.raw['_interval'], 120);
      expect(track.raw['otherSource'], isNull);
      expect(track.raw['_types'], types);
      expect(track.qualities.single.type, '128k');
      expect(track.qualities.single.hash, 'h1');
    });
  });

  group('MgSearch', () {
    test('parseTypes：两套字段名 + ZQ 兼容', () {
      final types = MgSearch.parseTypes([
        {'formatType': 'PQ', 'isize': 1048576},
        {'formatType': 'SQ', 'androidSize': 2097152},
        {'formatType': 'ZQ', 'size': 3145728},
        {'formatType': 'XX', 'size': 4096},
      ]);
      expect(types.keys, ['128k', 'flac', 'flac24bit']);
      expect(types['128k']!['size'], '1.00 MiB');
      expect(types['flac24bit']!['size'], '3.00 MiB');
    });

    test('fixCoverUrl：相对路径补全，空值 null，绝对路径原样', () {
      expect(MgSearch.fixCoverUrl('/data/x.jpg'),
          'http://d.musicapp.migu.cn/data/x.jpg');
      expect(MgSearch.fixCoverUrl('https://img/1.jpg'), 'https://img/1.jpg');
      expect(MgSearch.fixCoverUrl(''), isNull);
      expect(MgSearch.fixCoverUrl(null), isNull);
    });

    test('joinSingerNames：`、` 拼接并忽略空名', () {
      expect(
        MgSearch.joinSingerNames([
          {'name': 'A'},
          {'name': ''},
          {'name': 'B'},
        ]),
        'A、B',
      );
      expect(MgSearch.joinSingerNames(null), '');
    });
  });

  group('WyMusicDetail.buildTypes', () {
    test('320k 档：320k + 128k（带 sizeFormat）', () {
      final map = WyMusicDetail.buildTypes(
        privilege: {'maxbr': 320000},
        song: {
          'h': {'size': 5242880},
          'l': {'size': 1048576},
        },
      );
      expect(map.keys, ['320k', '128k']);
      expect(map['320k']!['size'], '5.00 MiB');
      expect(WyMusicDetail.typeList(map).map((e) => e['type']).toList(),
          ['128k', '320k']);
    });

    test('999000 档：flac 使用传入 size（歌单详情传 null 固定）', () {
      final map = WyMusicDetail.buildTypes(
        privilege: {'maxbr': 999000},
        song: {
          'sq': {'size': 10485760},
          'h': {'size': 5242880},
          'l': {'size': 1048576},
        },
        flacSize: null,
      );
      expect(map['flac']!['size'], isNull);
      final full = WyMusicDetail.buildTypes(
        privilege: {'maxbr': 999000},
        song: {
          'sq': {'size': 10485760},
          'h': {'size': 5242880},
          'l': {'size': 1048576},
        },
        flacSize: 10485760,
      );
      expect(full['flac']!['size'], '10.00 MiB');
    });

    test('hires + buildTrack：raw musicInfo 约定齐全', () {
      final typeMap = WyMusicDetail.buildTypes(
        privilege: {'maxbr': 320000, 'maxBrLevel': 'hires'},
        song: {
          'hr': {'size': 20971520},
          'h': {'size': 5242880},
          'l': {'size': 1048576},
        },
      );
      final track = WyMusicDetail.buildTrack(
        songId: 123,
        name: '歌',
        singer: '歌手',
        albumName: '专辑',
        albumId: 9,
        img: 'http://img/x.jpg',
        intervalText: '03:00',
        duration: const Duration(minutes: 3),
        types: WyMusicDetail.typeList(typeMap),
        typeMap: typeMap,
      );
      expect(track.raw['songmid'], 123);
      expect(track.raw['otherSource'], isNull);
      expect(track.raw['_types'], typeMap);
      expect(track.coverUrl, 'http://img/x.jpg');
      expect(track.qualities.map((q) => q.type),
          containsAll(['flac24bit', '320k', '128k']));
    });
  });
}
