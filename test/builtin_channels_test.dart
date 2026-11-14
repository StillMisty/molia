import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/sources/builtin/album_source.dart';
import 'package:molia/sources/builtin/artist_source.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/channel/channels.dart';
import 'package:molia/sources/builtin/comment_source.dart';
import 'package:molia/sources/builtin/discover_source.dart';
import 'package:molia/sources/builtin/lyric_search.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settings_test_support.dart';

/// 内置渠道矩阵：渠道只允许在自己的声明文件里登记一次，
/// 各 facade / SourceManager 的能力位必须从同一份注册表推导。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const expectedKeys = ['tx', 'wy', 'kg', 'kw', 'mg', 'qs', 'bili'];
  const musicKeys = ['tx', 'wy', 'kg', 'kw', 'mg', 'qs'];
  const lyricSearchKeys = ['tx', 'wy', 'kg', 'kw', 'mg'];

  test('渠道键只在声明里登记一次：规范顺序 / 显示名 / isSupported', () {
    expect(SongChannels.keys, expectedKeys);
    expect(
      SongChannels.all.map((channel) => channel.key),
      expectedKeys,
      reason: '音源页/搜索解析与发现页共用同一顺序',
    );
    expect(SongChannels.keySet, expectedKeys.toSet());
    for (final key in expectedKeys) {
      final channel = SongChannels.forKey(key);
      expect(channel, isNotNull, reason: key);
      expect(channel!.key, key, reason: key);
      expect(channel.displayName, isNotEmpty, reason: key);
      expect(SongChannels.isSupported(key), isTrue, reason: key);
      expect(BuiltinSearch.isBuiltin(key), isTrue, reason: key);
      expect(BuiltinSearch.displayName(key), channel.displayName, reason: key);
    }
    expect(SongChannels.displayName('bili'), '哔哩哔哩');
    expect(SongChannels.displayName('qs'), '汽水音乐');
    expect(SongChannels.isSupported('lx_custom'), isFalse);
    expect(SongChannels.isSupported('any_listen'), isFalse);

    // 既有 facade 的别名必须指向同一份注册表，而不是各自复制键表。
    expect(SongChannels.displayNames.keys, expectedKeys);
    expect(SongChannels.musicKeys, musicKeys);
    expect(BuiltinDiscover.sourceKeys, expectedKeys);
    expect(BuiltinDiscover.sources.keys, expectedKeys);
    expect(BuiltinDiscover.isSupported('bili'), isTrue);
  });

  test('能力族支持矩阵与渠道自述一致（每族都有自己的类型化适配器）', () {
    for (final key in expectedKeys) {
      final channel = SongChannels.forKey(key)!;
      expect(channel.search, isNotNull, reason: key);
      expect(channel.lyric, isNotNull, reason: key);
      expect(channel.pic, isNotNull, reason: key);
      expect(channel.comments, isNotNull, reason: key);
      expect(channel.artist, isNotNull, reason: key);
      expect(channel.discover, isNotNull, reason: key);

      // facade 的能力位不能自己再写一份渠道表。
      expect(
        BuiltinAlbums.isSupported(key),
        channel.album != null,
        reason: key,
      );
      expect(
        BuiltinArtists.isSupported(key),
        channel.artist != null,
        reason: key,
      );
      expect(
        BuiltinComments.isSupported(key),
        channel.comments != null,
        reason: key,
      );
      expect(
        BuiltinLyricSearch.isSupported(key),
        channel.lyricSearch != null,
        reason: key,
      );
      expect(
        BuiltinDiscover.isSupported(key),
        channel.discover != null,
        reason: key,
      );
    }

    // B 站是唯一原生取链渠道（不需要脚本）；音乐平台都靠 LX 脚本取链。
    expect(SongChannels.forKey('bili')!.resolve, isNotNull);
    for (final key in musicKeys) {
      expect(SongChannels.forKey(key)!.resolve, isNull, reason: key);
    }

    // 只有 B 站没有专辑；汽水没有匿名歌词搜索接口。
    expect(SongChannels.forKey('bili')!.album, isNull);
    expect(SongChannels.forKey('qs')!.lyricSearch, isNull);
    for (final key in lyricSearchKeys) {
      expect(SongChannels.forKey(key)!.lyricSearch, isNotNull, reason: key);
    }
    for (final key in musicKeys) {
      expect(SongChannels.forKey(key)!.album, isNotNull, reason: key);
    }
  });

  test('SourceManager.capabilitiesFor 与渠道自述 + 可取链门一致（无脚本）', () {
    final manager = SourceManager(settings: testSettingsRegistry());
    addTearDown(manager.dispose);

    for (final key in musicKeys) {
      final channel = SongChannels.forKey(key)!;
      final capabilities = manager.capabilitiesFor(key);

      // 原生取词 / 取图是 Dart 实现，不依赖脚本声明；能力位由渠道自述
      // 里的适配器是否存在推导。
      expect(capabilities.lyrics, channel.lyric != null, reason: key);
      expect(capabilities.artwork, channel.pic != null, reason: key);
      expect(capabilities.comment, channel.comments != null, reason: key);
      expect(capabilities.collection, channel.album != null, reason: key);

      // 无激活脚本 → 没有可取链源，搜索 / 歌手 / 歌词搜索的路由门关闭。
      expect(capabilities.search, isFalse, reason: key);
      expect(capabilities.pagination, isFalse, reason: key);
      expect(capabilities.resolveUrl, isFalse, reason: key);
      expect(capabilities.artist, isFalse, reason: key);
      expect(capabilities.lyricSearch, isFalse, reason: key);
    }

    // bili 不依赖脚本：搜索 / 播放 / 歌词 / 评论 / UP / 发现原生可用；
    // 专辑与按歌词搜歌仍未接入。
    final biliChannel = SongChannels.forKey('bili')!;
    final bili = manager.capabilitiesFor('bili');
    expect(bili.search, isTrue);
    expect(bili.pagination, isTrue);
    expect(bili.resolveUrl, isTrue);
    expect(bili.artwork, biliChannel.pic != null);
    expect(bili.lyrics, biliChannel.lyric != null);
    expect(bili.comment, isTrue);
    expect(bili.collection, isFalse);
    expect(bili.artist, isTrue);
    expect(bili.lyricSearch, isFalse);

    // 汽水：发现 / 专辑 / 歌手 / 评论 / 歌词原生可用，但搜索与播放要等
    // 用户装了声明 `qs` 的音源脚本。
    final qs = manager.capabilitiesFor('qs');
    expect(qs.search, isFalse);
    expect(qs.resolveUrl, isFalse);
    expect(qs.lyrics, isTrue);
    expect(qs.artwork, isTrue);
    expect(qs.comment, isTrue);
    expect(qs.collection, isTrue);
    expect(qs.artist, isFalse, reason: '歌手入口依赖搜索路由');
    expect(qs.lyricSearch, isFalse);

    // 非内置平台不应从注册表获得任何内置能力。
    final unknown = manager.capabilitiesFor('lx_custom');
    expect(unknown.search, isFalse);
    expect(unknown.comment, isFalse);
    expect(unknown.collection, isFalse);
    expect(unknown.lyrics, isFalse);
    expect(unknown.artwork, isFalse);
  });

  test('渠道自述的曲目页地址 / 专辑 id：映射层不再按 key 分支', () {
    Track mapTrack(String key, Map<String, dynamic> raw) =>
        trackFromSourceTrack(
          SourceTrack(
            sourceKey: key,
            origin: 'builtin',
            title: '歌',
            artist: '歌手',
            album: '专辑',
            raw: raw,
          ),
        );

    expect(
      mapTrack('wy', {'songId': 1, 'albumId': 'al'}).platformPageUrl,
      'https://music.163.com/#/song?id=1',
    );
    expect(
      mapTrack('tx', {'songmid': 'm', 'albumMid': 'am'}).platformPageUrl,
      'https://y.qq.com/n/ryqq/songDetail/m',
    );
    expect(
      mapTrack('kg', {'hash': 'h', 'albumId': 'al'}).platformPageUrl,
      'https://www.kugou.com/song/#hash=h',
    );
    expect(
      mapTrack('kw', {'songmid': 'k'}).platformPageUrl,
      'https://www.kuwo.cn/play_detail/k',
    );
    expect(
      mapTrack('mg', {'copyrightId': 'c', 'albumId': 'al'}).platformPageUrl,
      'https://music.migu.cn/v3/music/song/c',
    );
    expect(
      mapTrack('qs', {
        'track_id': '7079108541549643812',
        'albumId': '7079108425841379335',
      }).platformPageUrl,
      'https://www.qishui.com/share/track?track_id=7079108541549643812',
    );
    expect(
      mapTrack('qs', {
        'track_id': '7079108541549643812',
        'albumId': '7079108425841379335',
      }).platformAlbumId,
      '7079108425841379335',
    );
    expect(
      mapTrack('bili', {'bvid': 'BV1'}).platformPageUrl,
      'https://www.bilibili.com/video/BV1',
    );

    // 脚本源 / 未知 key 没有渠道自述：不猜页面地址与专辑 id。
    final custom = mapTrack('custom', {'songmid': 'm', 'albumId': 'al'});
    expect(custom.platformPageUrl, isNull);
    expect(custom.platformAlbumId, isNull);
  });
}
