/// 内置平台「发现」能力矩阵冒烟测试。
///
/// 每个平台 × 每项能力（榜单 / 标签 / 歌单 / 歌单搜索 / 歌单详情 / 热搜词）都用
/// 注入的 [MockClient] 驱动适配器，钉住三件事：
/// 1. 请求确实经注入的 client 发出（URL 路由命中并记录）；
/// 2. 平台真实响应的最小骨架能跑通解析路径，产出预期结果；
/// 3. 业务失败（非法载荷）走「重试 → 用尽 → [StateError]」而不是别的异常，
///    且重试预算（请求次数）由各用例的 `attempts` 断言钉住。
///
/// 迁移后的缓存身份也在这里钉住：成功结果必须落在迁移前的
/// `{platform}:{type}:{params}` 键上，失败不进缓存。缓存命中 / single-flight
/// 的通用语义见 `builtin_cached_retry_cases.dart`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/cache/request_cache.dart';
import 'package:molia/domain/models/discover.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/crypto_utils.dart';
import 'package:molia/sources/builtin/discover_source.dart';
import 'package:molia/sources/lx/lx_native_utils.dart';

import 'support/mock_dio.dart';
import 'support/transport_test_support.dart';

/// 按 URL 子串路由的发现请求桩：记录全部请求；未路由的请求直接失败，
/// 保证「绕开注入 client 的裸请求」不会被静默放过。
/// 把未绑定的发现声明与一个测试 stub 组合成可直接调用的门面。
///
/// 每次调用显式携带该 stub 的 transport，不用进程级 / 用例级可变全局。
class _BoundSource {
  const _BoundSource(this._source, this._stub);

  final DiscoverSource _source;
  final _Stub _stub;

  BuiltinTransport get transport => _stub.transport;
  List<Uri> get requests => _stub.requests;

  String get sourceKey => _source.sourceKey;
  List<DiscoverLeaderboard> get leaderboards => _source.leaderboards;
  bool get supportsLeaderboards => _source.supportsLeaderboards;
  bool get supportsPlaylists => _source.supportsPlaylists;
  bool get supportsPlaylistSearch => _source.supportsPlaylistSearch;
  bool get supportsHotSearch => _source.supportsHotSearch;
  bool get hasLeaderboardCoverEndpoint => _source.hasLeaderboardCoverEndpoint;

  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) =>
      _source.leaderboardTracks(transport, bangid);
  Future<String?> leaderboardCover(String bangid) =>
      _source.leaderboardCover(transport, bangid);
  Future<DiscoverTags> tags() => _source.tags(transport);
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) =>
      _source.playlists(transport, tagId, page);
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) =>
      _source.searchPlaylists(transport, keyword, page);
  Future<DiscoverDetail> playlistDetail(String rawId, int page) =>
      _source.playlistDetail(transport, rawId, page);
  Future<List<String>> hotSearches() => _source.hotSearches(transport);
}

class _Stub {
  _Stub(this.routes)
    : cache = RequestCache(ttl: BuiltinTransport.defaultCacheTtl);

  /// URL 子串 → 响应体；按插入顺序首个命中生效（更具体的串放前面）。
  final Map<String, String> routes;
  final List<Uri> requests = [];

  /// 与 transport 共享的结果缓存：用例直接断言发现端点的缓存键。
  final RequestCache cache;

  late final BuiltinTransport transport = testTransport(
    dio: mockDio((request) async {
      final url = request.uri.toString();
      requests.add(request.uri);
      for (final entry in routes.entries) {
        if (url.contains(entry.key)) {
          return bytesResponse(utf8.encode(entry.value), statusCode: 200);
        }
      }
      throw StateError('未路由的请求: $url');
    }),
    cache: cache,
  );

  _BoundSource bind(DiscoverSource source) => _BoundSource(source, this);
}

/// 断言失败路径：StateError（重试耗尽或直连业务失败），并校验请求次数。
Future<void> _expectStateError(
  _BoundSource source,
  Future<Object?> Function() run, {
  int? attempts,
  String? reason,
}) async {
  await expectLater(run(), throwsA(isA<StateError>()));
  if (attempts != null) {
    expect(source.requests, hasLength(attempts), reason: reason ?? '重试预算保持不变');
  }
}

/// 同一 transport 的二次调用必须命中缓存。
Future<void> _expectCacheHit(
  _BoundSource source,
  Future<Object?> Function() run,
) async {
  final before = source.requests.length;
  await run();
  expect(source.requests, hasLength(before), reason: '二次调用应命中缓存');
}

/// 成功结果必须落在迁移前约定的缓存键上（键是缓存身份，不能随迁移漂移）。
void _expectCachedKey(_Stub stub, String key) {
  expect(stub.cache.containsKey(key), isTrue, reason: '缺少缓存键 $key');
}

/// 失败结果不得进缓存（与迁移前的 `cached(...)` 一致）。
void _expectNotCachedKey(_Stub stub, String key) {
  expect(stub.cache.containsKey(key), isFalse, reason: '失败不应缓存 $key');
}

/// 酷我 wbd 接口响应需 AES-128-ECB/PKCS7 加密（与适配器解码对称）。
String _kwWbdResponse(String plainJson) {
  final cipher = LxNativeUtils.aesEncrypt(
    Uint8List.fromList(utf8.encode(plainJson)),
    'aes-128-ecb',
    base64.decode(kwWbdKeyBase64),
    null,
  );
  return base64.encode(cipher);
}

/// QQ 榜单/详情共用的最小歌曲骨架（`TxSearch.parseSongItem` 需要 file.media_mid）。
Map<String, dynamic> _txSongItem() => {
  'id': 1,
  'mid': 'mid1',
  'title': '歌',
  'interval': 200,
  'singer': [
    {'name': '歌手', 'mid': 's1'},
  ],
  'album': {'name': '专辑', 'mid': 'a1'},
  'file': {'media_mid': 'm1', 'size_128mp3': 1048576},
};

void main() {
  group('酷我发现矩阵', () {
    final discover = BuiltinDiscover.of('kw');

    test('榜单：经注入 client、解析曲目、失败重试 4 次', () async {
      final body = jsonEncode({
        'code': 200,
        'data': {
          'musiclist': [
            {
              'id': 933,
              'name': '歌 & 名',
              'artist': '任夏',
              'album': '专辑',
              'albumId': 5,
              'duration': 212,
              'pic': 'http://img/p.jpg',
              'n_minfo': 'level:ff,bitrate:320,format:mp3,size:3.1M',
            },
          ],
        },
      });
      final ok = _Stub({'bang/bang_info': _kwWbdResponse(body)});
      final source = ok.bind(discover);
      final tracks = await source.leaderboardTracks('93');
      expect(tracks.single.title, '歌 & 名');
      expect(tracks.single.songId, '933');
      expect(tracks.single.durationMs, 212000);
      expect(ok.requests.single.host, 'wbd.kuwo.cn');
      await _expectCacheHit(source, () => source.leaderboardTracks('93'));

      final bad = _Stub({'bang/bang_info': 'not-base64'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardTracks('93'),
        attempts: 4,
      );
    });

    test('标签：目录 + 热门标签；直连失败一次即 StateError', () async {
      final ok = _Stub({
        'getTagList': jsonEncode({
          'code': 200,
          'data': [
            {
              'name': '风格',
              'data': [
                {'id': '100', 'digest': '10000', 'name': '流行'},
              ],
            },
          ],
        }),
        'getRcmTagList': jsonEncode({
          'code': 200,
          'data': [
            {
              'data': [
                {'id': '200', 'digest': '43', 'name': '短视频'},
              ],
            },
          ],
        }),
      });
      final source = ok.bind(discover);
      final tags = await source.tags();
      expect(tags.categories.single.name, '风格');
      expect(tags.categories.single.tags.single.id, '100-10000');
      expect(tags.hotTags.single.id, '200-43');
      expect(ok.requests, hasLength(2));
      _expectCachedKey(ok, 'kw:tags');

      final bad = _Stub({
        'getTagList': '{"code":1}',
        'getRcmTagList': '{"code":1}',
      });
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.tags(),
        attempts: 6,
        reason: '两个取数各自重试 3 次',
      );
      _expectNotCachedKey(bad, 'kw:tags');
    });

    test('歌单：推荐（tagId 空）与标签两条分支、失败重试 3 次', () async {
      final page = jsonEncode({
        'code': 200,
        'data': {
          'total': '1',
          'data': [
            {
              'digest': '8',
              'id': 123,
              'name': '歌单',
              'uname': '作者',
              'listencnt': 12034,
              'total': 5,
              'img': 'http://img/x.jpg',
            },
          ],
        },
      });
      final recommend = _Stub({'getRcmPlayList': page});
      final recommendSource = recommend.bind(discover);
      final r = await recommendSource.playlists('', 1);
      expect(r.playlists.single.id, 'digest-8__123');
      expect(recommend.requests.single.host, 'wapi.kuwo.cn');

      final tag = _Stub({'getTagPlayList': page});
      final tagSource = tag.bind(discover);
      final t = await tagSource.playlists('100-10000', 1);
      expect(t.playlists.single.name, '歌单');
      expect(t.total, 1);
      await _expectCacheHit(
        recommendSource,
        () => recommendSource.playlists('', 1),
      );
      await _expectCacheHit(
        tagSource,
        () => tagSource.playlists('100-10000', 1),
      );
      _expectCachedKey(recommend, 'kw:playlists::1');
      _expectCachedKey(tag, 'kw:playlists:100-10000:1');

      final bad = _Stub({'getTagPlayList': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlists('100-10000', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'kw:playlists:100-10000:1');
    });

    test('歌单搜索：伪 JSON 解析；直连失败一次即 StateError', () async {
      const text =
          "{'abslist':[{'playlistid':'9','name':'歌单',"
          "'nickname':'作者','pic':'http://img/x.jpg','playcnt':'12',"
          "'songnum':'3'}],'TOTAL':'1'}";
      final ok = _Stub({'search.kuwo.cn/r.s': text});
      final source = ok.bind(discover);
      final page = await source.searchPlaylists('夏', 1);
      expect(page.playlists.single.id, '9');
      expect(page.playlists.single.author, '作者');
      expect(page.total, 1);
      _expectCachedKey(ok, 'kw:playlist-search:夏:1');

      // 伪 JSON 转出来不是 Map（数组）才触发业务失败分支。
      final bad = _Stub({'search.kuwo.cn/r.s': '[]'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.searchPlaylists('夏', 1),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'kw:playlist-search:夏:1');
    });

    test('歌单详情：digest8 解析曲目、失败重试 3 次', () async {
      final body = jsonEncode({
        'result': 'ok',
        'title': '歌单',
        'pic': 'http://img/x.jpg',
        'uname': '作者',
        'playnum': '9',
        'total': '1',
        'info': '描述',
        'musiclist': [
          {
            'id': 1,
            'name': '歌曲',
            'artist': 'A&B',
            'album': '专辑',
            'albumid': 2,
            'duration': 200,
            'N_MINFO': 'level:ff,bitrate:320,format:mp3,size:1.2M',
          },
        ],
      });
      final ok = _Stub({'nplserver.kuwo.cn/pl.svc': body});
      final source = ok.bind(discover);
      final detail = await source.playlistDetail('123', 1);
      expect(detail.info.name, '歌单');
      expect(detail.tracks.single.artist, 'A、B');
      _expectCachedKey(ok, 'kw:playlist-detail:123');

      final bad = _Stub({'nplserver.kuwo.cn/pl.svc': '{"result":"no"}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlistDetail('123', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'kw:playlist-detail:123');
    });

    test('歌单详情：digest5 先换算 sourceid 再取曲目', () async {
      final stub = _Stub({
        'qukudata.kuwo.cn/q.k': jsonEncode({
          'child': [
            {'sourceid': '888'},
          ],
        }),
        'nplserver.kuwo.cn/pl.svc': jsonEncode({
          'result': 'ok',
          'title': '推荐歌单',
          'total': '0',
          'musiclist': const [],
        }),
      });
      final source = stub.bind(discover);
      final detail = await source.playlistDetail('digest-5__777', 1);
      expect(detail.info.name, '推荐歌单');
      expect(detail.info.id, '888');
      expect(stub.requests, hasLength(2));
      expect(stub.requests.last.query, contains('pid=888'));
      _expectCachedKey(stub, 'kw:playlist-detail:digest-5__777');
    });

    test('榜单封面：bang_info 解析 pic；失败不缓存', () async {
      final ok = _Stub({
        'bang/bang_info': _kwWbdResponse(
          jsonEncode({
            'code': 200,
            'data': {'pic': 'http://img/cover.jpg'},
          }),
        ),
      });
      final source = ok.bind(discover);
      expect(await source.leaderboardCover('93'), 'http://img/cover.jpg');
      _expectCachedKey(ok, 'kw:leaderboard-cover:93');
      await _expectCacheHit(source, () => source.leaderboardCover('93'));

      final bad = _Stub({'bang/bang_info': 'not-base64'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardCover('93'),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'kw:leaderboard-cover:93');
    });

    test('热搜词：解析、失败重试 3 次', () async {
      final ok = _Stub({
        'hotword.kuwo.cn': jsonEncode({
          'status': 'ok',
          'tagvalue': [
            {'key': '热词一'},
            {'key': '热词二'},
          ],
        }),
      });
      final source = ok.bind(discover);
      expect(await source.hotSearches(), ['热词一', '热词二']);
      await _expectCacheHit(source, () => source.hotSearches());

      final bad = _Stub({'hotword.kuwo.cn': '{"status":"no"}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.hotSearches(),
        attempts: 3,
      );
    });
  });

  group('酷狗发现矩阵', () {
    final discover = BuiltinDiscover.of('kg');

    test('榜单：经注入 client、解析曲目、失败重试 4 次', () async {
      final ok = _Stub({
        'api/v3/rank/song': jsonEncode({
          'errcode': 0,
          'data': {
            'info': [
              {
                'songname': '勇气',
                'authors': [
                  {'author_name': '梁静茹'},
                ],
                'remark': '专辑',
                'album_id': 9,
                'audio_id': 88,
                'duration': 240,
                'filesize': 3145728,
                'hash': 'h128',
              },
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      final tracks = await source.leaderboardTracks('8888');
      expect(tracks.single.title, '勇气');
      expect(tracks.single.artist, '梁静茹');
      expect(tracks.single.songId, '88');
      expect(ok.requests.single.host, 'mobilecdnbj.kugou.com');
      await _expectCacheHit(source, () => source.leaderboardTracks('8888'));

      final bad = _Stub({'api/v3/rank/song': '{"errcode":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardTracks('8888'),
        attempts: 4,
      );
    });

    test('标签：热门标签 + 目录；直连失败一次即 StateError', () async {
      final ok = _Stub({
        'is_smarty=1&': jsonEncode({
          'status': 1,
          'data': {
            'hotTag': {
              'status': 1,
              'data': {
                'a': {'special_id': 111, 'special_name': '经典'},
              },
            },
            'tagids': {
              '主题': {
                'data': [
                  {'id': '222', 'name': '影视'},
                ],
              },
            },
          },
        }),
      });
      final source = ok.bind(discover);
      final tags = await source.tags();
      expect(tags.hotTags.single.name, '经典');
      expect(tags.categories.single.tags.single.id, '222');
      _expectCachedKey(ok, 'kg:tags');

      final bad = _Stub({'is_smarty=1&': '{"status":0}'});
      final badSource = bad.bind(discover);
      await _expectStateError(badSource, () => badSource.tags(), attempts: 1);
      _expectNotCachedKey(bad, 'kg:tags');
    });

    test('歌单：推荐与标签两条分支、失败重试 3 次', () async {
      final ok = _Stub({
        'is_ajax=1': jsonEncode({
          'status': 1,
          'special_db': [
            {
              'specialid': 6409645,
              'specialname': '歌单',
              'nickname': '作者',
              'img': 'http://img/x.jpg',
              'songcount': 154,
              'total_play_count': '1712',
              'intro': '描述',
            },
          ],
        }),
        'is_smarty=1&cdn': jsonEncode({
          'status': 1,
          'data': {
            'params': {'total': '10', 'pagesize': '30'},
          },
        }),
      });
      final source = ok.bind(discover);
      final recommend = await source.playlists('', 1);
      expect(recommend.playlists.single.id, 'id_6409645');
      expect(recommend.limit, 30);

      final tag = await source.playlists('222', 1);
      expect(tag.playlists.single.name, '歌单');
      expect(tag.total, 10);
      expect(ok.requests, hasLength(3), reason: '推荐 1 次 + 标签列表/信息 2 次');
      _expectCachedKey(ok, 'kg:playlists::1');
      _expectCachedKey(ok, 'kg:playlists:222:1');

      final bad = _Stub({'is_ajax=1': '{"status":0}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlists('', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'kg:playlists::1');
    });

    test('歌单搜索：解析、直连失败一次即 StateError', () async {
      final ok = _Stub({
        'api/v3/search/special': jsonEncode({
          'errcode': 0,
          'data': {
            'total': '1',
            'info': [
              {
                'specialid': 5,
                'specialname': '搜索歌单',
                'nickname': '作者',
                'imgurl': 'http://img/x.jpg',
                'playcount': 10,
                'songcount': 2,
                'intro': 'd',
              },
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      final page = await source.searchPlaylists('周', 1);
      expect(page.playlists.single.id, 'id_5');
      expect(page.total, 1);
      _expectCachedKey(ok, 'kg:playlist-search:周:1');

      final bad = _Stub({'api/v3/search/special': '{"errcode":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.searchPlaylists('周', 1),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'kg:playlist-search:周:1');
    });

    test('歌单详情：HTML + gateway 批量信息、失败重试 3 次', () async {
      final ok = _Stub({
        'special/single/':
            '<html>global.data = [{"hash":"h1","audio_id":1}];'
            'global = { id: 1, name: "歌单", pic: "http://img/x.jpg" };</html>',
        'gateway.kugou.com/v2/album_audio/audio': jsonEncode({
          'status': 1,
          'data': [
            [
              {
                'songname': '歌',
                'author_name': '歌手',
                'album_info': {'album_name': '专辑', 'album_id': 3},
                'audio_info': {
                  'audio_id': 7,
                  'hash': 'h',
                  'timelength': 212000,
                  'filesize': 1048576,
                },
              },
            ],
          ],
        }),
      });
      final source = ok.bind(discover);
      final detail = await source.playlistDetail('id_123', 1);
      expect(detail.info.name, '歌单');
      expect(detail.tracks.single.title, '歌');
      expect(detail.tracks.single.durationMs, 212000);
      expect(ok.requests, hasLength(2));
      _expectCachedKey(ok, 'kg:playlist-detail:123');

      final bad = _Stub({'special/single/': '<html></html>'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlistDetail('id_123', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'kg:playlist-detail:123');
    });

    test('榜单封面：rank/info 解析 imgurl；失败不缓存', () async {
      final ok = _Stub({
        'api/v3/rank/info': jsonEncode({
          'status': 1,
          'data': {'img': 'http://img/cover{size}.jpg'},
        }),
      });
      final source = ok.bind(discover);
      expect(await source.leaderboardCover('8888'), 'http://img/cover480.jpg');
      _expectCachedKey(ok, 'kg:leaderboard-cover:8888');
      await _expectCacheHit(source, () => source.leaderboardCover('8888'));

      final bad = _Stub({'api/v3/rank/info': '{"status":0}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardCover('8888'),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'kg:leaderboard-cover:8888');
    });

    test('热搜词：解析、失败重试 3 次', () async {
      final ok = _Stub({
        'search/hot_tab': jsonEncode({
          'errcode': 0,
          'data': {
            'list': [
              {
                'keywords': [
                  {'keyword': '热词'},
                ],
              },
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      expect(await source.hotSearches(), ['热词']);

      final bad = _Stub({'search/hot_tab': '{"errcode":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.hotSearches(),
        attempts: 3,
      );
    });
  });

  group('QQ 发现矩阵', () {
    final discover = BuiltinDiscover.of('tx');

    test('榜单：经注入 client、解析曲目；直连失败一次即 StateError', () async {
      final ok = _Stub({
        'musicu.fcg': jsonEncode({
          'code': 0,
          'toplist': {
            'data': {
              'songInfoList': [_txSongItem()],
            },
          },
        }),
      });
      final source = ok.bind(discover);
      final tracks = await source.leaderboardTracks('26');
      expect(tracks.single.title, '歌');
      expect(tracks.single.songId, 'mid1');
      expect(ok.requests.single.host, 'u.y.qq.com');
      _expectCachedKey(ok, 'tx:leaderboard:26');

      final bad = _Stub({'musicu.fcg': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardTracks('26'),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'tx:leaderboard:26');
    });

    test('标签：目录接口 + 热门标签 HTML；失败归一为 StateError', () async {
      final ok = _Stub({
        'musicu.fcg': jsonEncode({
          'code': 0,
          'tags': {
            'data': {
              'v_group': [
                {
                  'group_name': '语种',
                  'v_item': [
                    {'id': 1, 'name': '华语'},
                  ],
                },
              ],
            },
          },
        }),
        'category_playlist.html':
            '<div><a class="c_bg_link js_tag_item" '
            'data-id="3317">官方歌单</a></div>',
      });
      final source = ok.bind(discover);
      final tags = await source.tags();
      expect(tags.categories.single.name, '语种');
      expect(tags.hotTags.single.name, '官方歌单');
      _expectCachedKey(ok, 'tx:tags');

      final bad = _Stub({
        'musicu.fcg': '{"code":1}',
        'category_playlist.html': '<html></html>',
      });
      final badSource = bad.bind(discover);
      await _expectStateError(badSource, () => badSource.tags(), attempts: 4);
      _expectNotCachedKey(bad, 'tx:tags');
    });

    test('歌单：推荐与分类两条分支、失败重试 3 次', () async {
      final basic = {
        'tid': 1,
        'title': '歌单',
        'cover': {'default_url': 'http://img/x.jpg'},
        'creator': {'nick': '作者'},
        'play_cnt': 10,
        'song_cnt': 2,
        'desc': 'd',
      };
      final recommend = _Stub({
        'musicu.fcg': jsonEncode({
          'code': 0,
          'playlist': {
            'data': {
              'FeedRsp': {
                'FromLimit': 1,
                'List': [
                  {
                    'Playlist': {'basic': basic},
                  },
                ],
              },
            },
          },
        }),
      });
      final recommendSource = recommend.bind(discover);
      final r = await recommendSource.playlists('', 1);
      expect(r.playlists.single.name, '歌单');
      expect(r.total, 1);

      final category = _Stub({
        'musicu.fcg': jsonEncode({
          'code': 0,
          'playlist': {
            'data': {
              'content': {
                'total_cnt': 1,
                'v_item': [
                  {'basic': basic},
                ],
              },
            },
          },
        }),
      });
      final categorySource = category.bind(discover);
      final c = await categorySource.playlists('3317', 1);
      expect(c.playlists.single.id, '1');
      await _expectCacheHit(
        recommendSource,
        () => recommendSource.playlists('', 1),
      );
      await _expectCacheHit(
        categorySource,
        () => categorySource.playlists('3317', 1),
      );
      _expectCachedKey(recommend, 'tx:playlists::1');
      _expectCachedKey(category, 'tx:playlists:3317:1');

      final bad = _Stub({'musicu.fcg': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlists('3317', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'tx:playlists:3317:1');
    });

    test('歌单搜索：解析、直连失败一次即 StateError', () async {
      final ok = _Stub({
        'client_music_search_songlist': jsonEncode({
          'code': 0,
          'data': {
            'sum': 1,
            'list': [
              {
                'dissid': '1',
                'dissname': '歌单',
                'imgurl': 'http://img/x.jpg',
                'creator': {'name': '作者'},
                'listennum': 10,
                'song_count': 2,
                'introduction': 'd',
              },
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      final page = await source.searchPlaylists('周', 1);
      expect(page.playlists.single.name, '歌单');
      expect(page.total, 1);
      _expectCachedKey(ok, 'tx:playlist-search:周:1');

      final bad = _Stub({'client_music_search_songlist': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.searchPlaylists('周', 1),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'tx:playlist-search:周:1');
    });

    test('歌单详情：cgi 主接口 + musicu 兜底、失败归一为 StateError', () async {
      final ok = _Stub({
        'fcg_ucc_getcdinfo_byids_cp': jsonEncode({
          'code': 0,
          'subcode': 0,
          'cdlist': [
            {
              'dissname': '歌单',
              'logo': 'http://img/x.jpg',
              'nickname': '作者',
              'visitnum': 5,
              'desc': 'd',
              'songlist': [_txSongItem()],
            },
          ],
        }),
      });
      final source = ok.bind(discover);
      final detail = await source.playlistDetail('1', 1);
      expect(detail.info.name, '歌单');
      expect(detail.tracks.single.title, '歌');
      expect(ok.requests, hasLength(1));
      _expectCachedKey(ok, 'tx:playlist-detail:1');

      final bad = _Stub({
        'fcg_ucc_getcdinfo_byids_cp': '{"code":1}',
        'musicu.fcg': '{"code":1}',
      });
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlistDetail('1', 1),
        attempts: 2,
        reason: 'cgi 失败后仍走 musicu 兜底',
      );
      _expectNotCachedKey(bad, 'tx:playlist-detail:1');
    });

    test('榜单封面：topInfo 封面字段；失败不缓存', () async {
      final ok = _Stub({
        'musicu.fcg': jsonEncode({
          'code': 0,
          'toplist': {
            'data': {
              'data': {'headPicUrl': 'http://img/cover.jpg'},
            },
          },
        }),
      });
      final source = ok.bind(discover);
      expect(await source.leaderboardCover('26'), 'http://img/cover.jpg');
      _expectCachedKey(ok, 'tx:leaderboard-cover:26');
      await _expectCacheHit(source, () => source.leaderboardCover('26'));

      final bad = _Stub({'musicu.fcg': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardCover('26'),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'tx:leaderboard-cover:26');
    });

    test('热搜词：解析、失败重试 3 次', () async {
      final ok = _Stub({
        'musicu.fcg': jsonEncode({
          'code': 0,
          'hotkey': {
            'data': {
              'vec_hotkey': [
                {'query': '热词'},
              ],
            },
          },
        }),
      });
      final source = ok.bind(discover);
      expect(await source.hotSearches(), ['热词']);
      await _expectCacheHit(source, () => source.hotSearches());

      final bad = _Stub({'musicu.fcg': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.hotSearches(),
        attempts: 3,
      );
    });
  });

  group('咪咕发现矩阵', () {
    final discover = BuiltinDiscover.of('mg');

    test('榜单：经注入 client、解析曲目、失败重试 4 次', () async {
      final ok = _Stub({
        'querycontentbyId.do': jsonEncode({
          'code': '000000',
          'columnInfo': {
            'contents': [
              {
                'objectInfo': {
                  'songId': 's1',
                  'copyrightId': 'c1',
                  'songName': '起风了',
                  'artists': [
                    {'name': '周深'},
                  ],
                  'album': '专辑',
                  'albumId': 'a1',
                  'length': '05:12',
                  'newRateFormats': [
                    {'formatType': 'PQ', 'size': 1048576},
                  ],
                  'albumImgs': [
                    {'img': '/data/x.jpg'},
                  ],
                },
              },
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      final tracks = await source.leaderboardTracks('27186466');
      expect(tracks.single.title, '起风了');
      expect(tracks.single.artist, '周深');
      expect(tracks.single.durationMs, 312000);
      expect(ok.requests.single.host, 'app.c.nf.migu.cn');
      await _expectCacheHit(source, () => source.leaderboardTracks('27186466'));

      final bad = _Stub({'querycontentbyId.do': '{"code":"1"}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardTracks('27186466'),
        attempts: 4,
      );
    });

    test('标签：热门 + 目录；直连失败一次即 StateError', () async {
      final ok = _Stub({
        'musiclistplaza-taglist': jsonEncode({
          'code': '000000',
          'data': [
            {
              'content': [
                {
                  'texts': ['网络热歌', '1001076096'],
                },
              ],
            },
            {
              'header': {'title': '风格'},
              'content': [
                {
                  'texts': ['流行', '1000001672'],
                },
              ],
            },
          ],
        }),
      });
      final source = ok.bind(discover);
      final tags = await source.tags();
      expect(tags.hotTags.single.name, '网络热歌');
      expect(tags.categories.single.name, '风格');
      _expectCachedKey(ok, 'mg:tags');

      final bad = _Stub({'musiclistplaza-taglist': '{"code":"1"}'});
      final badSource = bad.bind(discover);
      await _expectStateError(badSource, () => badSource.tags(), attempts: 1);
      _expectNotCachedKey(bad, 'mg:tags');
    });

    test('歌单：推荐与标签两条分支、失败重试 3 次', () async {
      final recommend = _Stub({
        'playlist-square-recommend': jsonEncode({
          'code': '000000',
          'data': {
            'contents': [
              {
                'resType': '2021',
                'resId': 11,
                'txt': '歌单一',
                'img': 'http://img/1.jpg',
              },
            ],
          },
        }),
      });
      final recommendSource = recommend.bind(discover);
      final r = await recommendSource.playlists('', 1);
      expect(r.playlists.single.name, '歌单一');

      final tag = _Stub({
        'musiclistplaza-listbytag': jsonEncode({
          'code': '000000',
          'data': {
            'contents': [
              {'resType': '2021', 'resId': 12, 'txt': '歌单二'},
            ],
          },
        }),
      });
      final tagSource = tag.bind(discover);
      final t = await tagSource.playlists('1000001672', 1);
      expect(t.playlists.single.name, '歌单二');
      await _expectCacheHit(
        recommendSource,
        () => recommendSource.playlists('', 1),
      );
      await _expectCacheHit(
        tagSource,
        () => tagSource.playlists('1000001672', 1),
      );
      _expectCachedKey(recommend, 'mg:playlists::1');
      _expectCachedKey(tag, 'mg:playlists:1000001672:1');

      final bad = _Stub({'musiclistplaza-listbytag': '{"code":"1"}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlists('1000001672', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'mg:playlists:1000001672:1');
    });

    test('歌单搜索：解析、直连失败一次即 StateError', () async {
      final ok = _Stub({
        'searchAll': jsonEncode({
          'code': '000000',
          'songListResultData': {
            'totalCount': '1',
            'result': [
              {
                'id': '77',
                'name': '歌单',
                'userName': '作者',
                'musicListPicUrl': 'http://img/2.jpg',
                'playNum': '123456',
                'musicNum': '20',
              },
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      final page = await source.searchPlaylists('周', 1);
      expect(page.playlists.single.id, '77');
      expect(page.playlists.single.trackCount, 20);
      _expectCachedKey(ok, 'mg:playlist-search:周:1');

      final bad = _Stub({'searchAll': '{"code":"1"}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.searchPlaylists('周', 1),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'mg:playlist-search:周:1');
    });

    test('歌单详情：曲目列表 + 头部信息并行、失败归一为 StateError', () async {
      final ok = _Stub({
        'resource/playlist/song': jsonEncode({
          'code': '000000',
          'data': {
            'songList': [
              {
                'songId': 'song2',
                'copyrightId': 'c2',
                'songName': '歌',
                'singerList': [
                  {'name': 'A'},
                ],
                'album': '专辑',
                'duration': 245,
                'audioFormats': [
                  {'formatType': 'HQ', 'androidSize': 5242880},
                ],
                'img1': 'https://img/1.jpg',
              },
            ],
            'totalCount': '1',
          },
        }),
        'resource/playlist/v2.0': jsonEncode({
          'code': '000000',
          'data': {
            'title': '歌单',
            'imgItem': {'img': 'http://img/1.jpg'},
            'opNumItem': {'playNum': '5'},
            'ownerName': '作者',
            'summary': 'd',
          },
        }),
      });
      final source = ok.bind(discover);
      final detail = await source.playlistDetail('777', 1);
      expect(detail.info.name, '歌单');
      expect(detail.info.author, '作者');
      expect(detail.tracks.single.title, '歌');
      expect(detail.tracks.single.durationMs, 245000);
      expect(ok.requests, hasLength(2));
      _expectCachedKey(ok, 'mg:playlist-detail:777');

      final bad = _Stub({
        'resource/playlist/song': '{"code":"1"}',
        'resource/playlist/v2.0': '{"code":"1"}',
      });
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlistDetail('777', 1),
        attempts: 4,
        reason: '曲目列表重试 3 次 + 头部信息 1 次',
      );
      _expectNotCachedKey(bad, 'mg:playlist-detail:777');
    });

    test('榜单封面：columnInfo 封面字段；失败不缓存', () async {
      final ok = _Stub({
        'querycontentbyId.do': jsonEncode({
          'code': '000000',
          'columnInfo': {'columnPicUrl': '/data/cover.jpg'},
        }),
      });
      final source = ok.bind(discover);
      expect(
        await source.leaderboardCover('27186466'),
        'http://d.musicapp.migu.cn/data/cover.jpg',
      );
      _expectCachedKey(ok, 'mg:leaderboard-cover:27186466');
      await _expectCacheHit(source, () => source.leaderboardCover('27186466'));

      final bad = _Stub({'querycontentbyId.do': '{"code":"1"}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardCover('27186466'),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'mg:leaderboard-cover:27186466');
    });

    test('热搜词：解析、失败重试 3 次', () async {
      final ok = _Stub({
        'hotword': jsonEncode({
          'code': '000000',
          'data': {
            'hotwords': [
              {
                'hotwordList': [
                  {'resourceType': 'song', 'word': '热词'},
                ],
              },
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      expect(await source.hotSearches(), ['热词']);
      await _expectCacheHit(source, () => source.hotSearches());

      final bad = _Stub({'hotword': '{"code":"1"}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.hotSearches(),
        attempts: 3,
      );
    });
  });

  group('网易云发现矩阵', () {
    final discover = BuiltinDiscover.of('wy');

    Map<String, dynamic> wyPlaylist({required List<dynamic> trackIds}) => {
      'name': '歌单',
      'coverImgUrl': 'http://img/x.jpg',
      'creator': {'nickname': '作者'},
      'playCount': 10,
      'description': 'd',
      'trackIds': trackIds,
    };

    Map<String, dynamic> wySong() => {
      'id': 1,
      'name': '歌',
      'ar': [
        {'name': '歌手'},
      ],
      'al': {'id': 9, 'name': '专辑', 'picUrl': 'http://img/x.jpg'},
      'dt': 180000,
      'h': {'size': 1048576},
      'l': {'size': 524288},
    };

    test('榜单：歌单详情 + 批量歌曲详情、失败重试 6 次', () async {
      final ok = _Stub({
        'weapi/v3/playlist/detail': jsonEncode({
          'code': 200,
          'playlist': wyPlaylist(
            trackIds: [
              {'id': 1},
            ],
          ),
        }),
        'weapi/v3/song/detail': jsonEncode({
          'code': 200,
          'songs': [wySong()],
          'privileges': [
            {'id': 1, 'maxbr': 320000},
          ],
        }),
      });
      final source = ok.bind(discover);
      final tracks = await source.leaderboardTracks('3778678');
      expect(tracks.single.title, '歌');
      expect(tracks.single.songId, '1');
      expect(tracks.single.durationMs, 180000);
      expect(ok.requests, hasLength(2));
      await _expectCacheHit(source, () => source.leaderboardTracks('3778678'));

      final bad = _Stub({'weapi/v3/playlist/detail': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardTracks('3778678'),
        attempts: 6,
      );
    });

    test('标签：目录 + 热门标签；失败归一为 StateError', () async {
      final ok = _Stub({
        'playlist/catalogue': jsonEncode({
          'code': 200,
          // 真实响应里 sub[].category 是数字，categories 的 key 是字符串：
          // 解析必须归一，否则每个分类都取不到标签（弹层只剩「全部」）。
          'sub': [
            {'category': 0, 'name': '华语'},
            {'category': '1', 'name': '流行'},
          ],
          'categories': {'0': '语种', '1': '风格'},
        }),
        'playlist/hottags': jsonEncode({
          'code': 200,
          'tags': [
            {
              'playlistTag': {'name': '热门'},
            },
          ],
        }),
      });
      final source = ok.bind(discover);
      final tags = await source.tags();
      expect(tags.categories.map((category) => category.name), ['语种', '风格']);
      expect(tags.categories.first.tags.single.name, '华语');
      expect(tags.categories.last.tags.single.name, '流行');
      expect(tags.hotTags.single.name, '热门');
      _expectCachedKey(ok, 'wy:playlist-tags');

      final bad = _Stub({
        'playlist/catalogue': '{"code":1}',
        'playlist/hottags': '{"code":1}',
      });
      final badSource = bad.bind(discover);
      await _expectStateError(badSource, () => badSource.tags(), attempts: 6);
      _expectNotCachedKey(bad, 'wy:playlist-tags');
    });

    test('歌单：weapi 列表、失败重试 3 次', () async {
      final ok = _Stub({
        'weapi/playlist/list': jsonEncode({
          'code': 200,
          'total': '1',
          'playlists': [
            {
              'id': 1,
              'name': '歌单',
              'coverImgUrl': 'http://img/x.jpg',
              'creator': {'nickname': '作者'},
              'playCount': 10,
              'trackCount': 2,
              'description': 'd',
              'createTime': 1700000000000,
            },
          ],
        }),
      });
      final source = ok.bind(discover);
      final page = await source.playlists('', 1);
      expect(page.playlists.single.id, '1');
      expect(page.playlists.single.createdAt, isNotNull);
      expect(page.total, 1);
      await _expectCacheHit(source, () => source.playlists('', 1));
      _expectCachedKey(ok, 'wy:playlists:hot::1');

      final bad = _Stub({'weapi/playlist/list': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlists('', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'wy:playlists:hot::1');
    });

    test('歌单搜索：eapi 解析、失败重试 3 次', () async {
      final ok = _Stub({
        'eapi/batch': jsonEncode({
          'code': 200,
          'result': {
            'playlistCount': '1',
            'playlists': [
              {
                'id': 1,
                'name': '歌单',
                'creator': {'nickname': '作者'},
                'playCount': 10,
                'trackCount': 2,
              },
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      final page = await source.searchPlaylists('周', 1);
      expect(page.playlists.single.name, '歌单');
      expect(page.total, 1);
      await _expectCacheHit(source, () => source.searchPlaylists('周', 1));
      _expectCachedKey(ok, 'wy:playlist-search:周:1:20');

      final bad = _Stub({'eapi/batch': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.searchPlaylists('周', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'wy:playlist-search:周:1:20');
    });

    test('歌单详情：linux forward 解析曲目、失败重试 3 次', () async {
      final ok = _Stub({
        'api/linux/forward': jsonEncode({
          'code': 200,
          'playlist': {
            ...wyPlaylist(
              trackIds: [
                {'id': 1},
              ],
            ),
            'tracks': [wySong()],
          },
          'privileges': [
            {'id': 1, 'maxbr': 320000},
          ],
        }),
      });
      final source = ok.bind(discover);
      final detail = await source.playlistDetail('123', 1);
      expect(detail.info.name, '歌单');
      expect(detail.tracks.single.title, '歌');
      _expectCachedKey(ok, 'wy:playlist-detail:123');

      final bad = _Stub({'api/linux/forward': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.playlistDetail('123', 1),
        attempts: 3,
      );
      _expectNotCachedKey(bad, 'wy:playlist-detail:123');
    });

    test('歌单详情：翻页复用详情壳，不重复下载整单', () async {
      // 1001 首：超过单页上限 1000，第二页只取剩余 1 首。
      final trackIds = [
        for (var i = 1; i <= 1001; i++) {'id': i},
      ];
      final stub = _Stub({
        'api/linux/forward': jsonEncode({
          'code': 200,
          'playlist': {...wyPlaylist(trackIds: trackIds), 'tracks': const []},
          // privileges 与 trackIds 不等长 → 走按页取曲目。
          'privileges': const [],
        }),
        'song/detail': jsonEncode({
          'code': 200,
          'songs': [
            {
              'id': 1001,
              'name': '尾曲',
              'ar': [
                {'name': 'A'},
              ],
              'al': {'id': 9, 'picUrl': ''},
              'dt': 1000,
            },
          ],
          'privileges': [
            {'id': 1001, 'maxbr': 320000},
          ],
        }),
      });
      final source = stub.bind(discover);

      final first = await source.playlistDetail('999', 1);
      expect(first.info.trackCount, 1001);
      // 详情壳只下载一次（key 与页无关）。
      final forwardRequests = stub.requests.where(
        (uri) => uri.toString().contains('linux/forward'),
      );
      expect(forwardRequests, hasLength(1));

      final second = await source.playlistDetail('999', 2);
      expect(second.tracks.single.title, '尾曲');
      expect(
        stub.requests.where((uri) => uri.toString().contains('linux/forward')),
        hasLength(1),
        reason: '第二页必须命中详情壳缓存',
      );
      expect(
        stub.requests.where((uri) => uri.toString().contains('song/detail')),
        hasLength(2),
        reason: '曲目按页取（每页各一次）',
      );
      _expectCachedKey(stub, 'wy:playlist-detail:999');
      _expectCachedKey(stub, 'wy:playlist-tracks:999:1');
      _expectCachedKey(stub, 'wy:playlist-tracks:999:2');
    });

    test('热搜词：eapi 解析；直连失败一次即 StateError', () async {
      final ok = _Stub({
        'eapi/batch': jsonEncode({
          'code': 200,
          'data': {
            'itemList': [
              {'searchWord': '热词一'},
              {'searchWord': '热词二'},
            ],
          },
        }),
      });
      final source = ok.bind(discover);
      expect(await source.hotSearches(), ['热词一', '热词二']);
      _expectCachedKey(ok, 'wy:hot-search');

      final bad = _Stub({'eapi/batch': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.hotSearches(),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'wy:hot-search');
    });

    test('榜单封面：playlist.coverImgUrl；失败不缓存', () async {
      final ok = _Stub({
        'weapi/v3/playlist/detail': jsonEncode({
          'code': 200,
          'playlist': {'coverImgUrl': 'http://img/cover.jpg'},
        }),
      });
      final source = ok.bind(discover);
      expect(await source.leaderboardCover('3778678'), 'http://img/cover.jpg');
      _expectCachedKey(ok, 'wy:leaderboard-cover:3778678');
      await _expectCacheHit(source, () => source.leaderboardCover('3778678'));

      final bad = _Stub({'weapi/v3/playlist/detail': '{"code":1}'});
      final badSource = bad.bind(discover);
      await _expectStateError(
        badSource,
        () => badSource.leaderboardCover('3778678'),
        attempts: 1,
      );
      _expectNotCachedKey(bad, 'wy:leaderboard-cover:3778678');
    });
  });

  group('汽水发现矩阵', () {
    final discover = BuiltinDiscover.of('qs');
    final source = _BoundSource(discover, _Stub(const {}));

    test('榜单与热搜：平台没有匿名入口，能力位显式为假', () async {
      expect(source.leaderboards, isEmpty);
      expect(source.supportsLeaderboards, isFalse);
      expect(await source.hotSearches(), isEmpty);
      expect(source.supportsHotSearch, isFalse);
      expect(source.supportsPlaylists, isTrue);
      expect(source.supportsPlaylistSearch, isTrue);
    });

    test('标签：固定分类目录（不发请求）', () async {
      final tags = await source.tags();
      expect(tags.hotTags.first.id, '0');
      expect(
        tags.categories.map((category) => category.name),
        containsAll(<String>['推荐', '曲风', '场景']),
      );
      expect(
        tags.categories
            .expand((category) => category.tags)
            .map((tag) => tag.id),
        contains('14'),
      );
    });

    test('推荐歌单：POST discover/mix，解析歌单与无限下拉', () async {
      final body = jsonEncode({
        'has_more': true,
        'inner_block': [
          {
            'type': 'discover_playlist',
            'title': '推荐歌单',
            'inner_block_id': '1',
            'resources': [
              {
                'resource_id': '1',
                'type': 'playlist',
                'entity': {
                  'playlist': {
                    'id': '7096700219496368135',
                    'title': '酷女孩',
                    'desc': '简介',
                    'count_tracks': 22,
                    'create_time': 1652669156,
                    'owner': {'nickname': '作者'},
                    'stats': {'count_collected': 81},
                    'url_cover': {
                      'uri': 'tos-cn-i/cover',
                      'urls': ['https://p3-luna.douyinpic.com/img/'],
                    },
                  },
                },
              },
            ],
          },
        ],
      });
      final stub = _Stub({'luna/discover/mix': body});
      final source = stub.bind(discover);
      final page = await source.playlists('0', 1);
      expect(page.playlists.single.id, '7096700219496368135');
      expect(page.playlists.single.name, '酷女孩');
      expect(page.playlists.single.author, '作者');
      expect(page.playlists.single.trackCount, 22);
      expect(page.playlists.single.playCount, 81);
      expect(page.playlists.single.coverUrl, contains('douyinpic.com'));
      expect(page.playlists.single.createdAt, '2022-05-16');
      expect(page.playlists.single.playCountText, '81');
      expect(page.hasMore, isTrue);
      expect(stub.requests.single.path, '/luna/discover/mix');
    });

    test('歌单搜索 / 详情：游标分页 + media_resources 曲目', () async {
      final searchBody = jsonEncode({
        'result_groups': [
          {
            'id': 'playlists',
            'has_more': true,
            'data': [
              {
                'entity': {
                  'playlist': {
                    'id': '1',
                    'title': '搜索歌单',
                    'count_tracks': 2,
                    'url_cover': {
                      'uri': 'c',
                      'urls': ['https://p3-luna.douyinpic.com/img/'],
                    },
                  },
                },
              },
            ],
          },
        ],
      });
      final detailBody = jsonEncode({
        'playlist': {
          'id': '1',
          'title': '搜索歌单',
          'count_tracks': 2,
          'url_cover': {
            'uri': 'c',
            'urls': ['https://p3-luna.douyinpic.com/img/'],
          },
        },
        'media_resources': [
          {
            'type': 'track',
            'entity': {
              'track_wrapper': {
                'track': {
                  'id': '7079108541549643812',
                  'name': '小半',
                  'duration': 297240,
                  'artists': [
                    {'id': '6776144869279664130', 'name': '陈粒'},
                  ],
                  'album': {
                    'id': '7079108425841379335',
                    'name': '小梦大半',
                    'url_cover': {
                      'uri': 'c',
                      'urls': ['https://p3-luna.douyinpic.com/img/'],
                    },
                  },
                  'bit_rates': [
                    {'quality': 'highest', 'size': 5454176},
                  ],
                },
              },
            },
          },
        ],
      });
      final stub = _Stub({
        'luna/search/playlist': searchBody,
        'luna/playlist/detail': detailBody,
      });
      final source = stub.bind(discover);

      final page = await source.searchPlaylists('夏日', 2);
      expect(page.playlists.single.name, '搜索歌单');
      expect(page.hasMore, isTrue);
      expect(
        stub.requests.first.queryParameters['cursor'],
        '20',
        reason: '平台按偏移量分页',
      );

      final detail = await source.playlistDetail('1', 1);
      expect(detail.info.name, '搜索歌单');
      expect(detail.info.trackCount, 2, reason: '详情页按总数判断是否还有下一页');
      expect(detail.tracks.single.title, '小半');
      expect(detail.tracks.single.songId, '7079108541549643812');
      expect(detail.tracks.single.artist, '陈粒');
    });
  });
}
