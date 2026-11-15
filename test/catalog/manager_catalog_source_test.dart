import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/manager_catalog_source.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_play.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/lx/lx_engine.dart';
import 'package:molia/sources/lx/lx_engine_supervisor.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/bili_session_mock.dart';
import '../support/mock_dio.dart';
import '../support/settings_test_support.dart';

/// 适配器测试：真实 SourceManager + any-listen 本地 mock HTTP 服务
/// （与 any_listen_manager_test.dart 相同手法，不访问真实网络）。
/// 取链降档测试用引擎：记录每次请求的音质与 hash，并按测试设定拒绝某些档位。
class _FakeResolveEngine implements LxEngine {
  _FakeResolveEngine();

  /// 每次 `getMusicUrl` 的入参（音质 + musicInfo 里的 hash，验证降档同时换 hash）。
  final List<({String quality, Object? hash})> calls = [];

  /// 每次 `getMusicUrl` 收到的超时提示（验证 deadline 会压到剩余预算）。
  final List<Duration> requestedTimeouts = [];

  /// 每次取链的模拟耗时（fake 不遵守 timeout，用于验证上层 deadline 检查）。
  Duration resolveDelay = Duration.zero;

  /// 这些档位返回「空地址」（[LxResolveRejectedException] → notFound）。
  final Set<String> rejectQualities = {};

  /// 这些档位返回 unsupported（另一种「该档位不可用」）。
  final Set<String> unsupportedQualities = {};

  /// 非空时每次取链都抛该错误（模拟网络 / 脚本暂时故障）。
  Object? error;

  bool running = false;
  Map<String, LxSourceDecl> _sources = {};
  final StreamController<LxLogEntry> _logs =
      StreamController<LxLogEntry>.broadcast();
  final StreamController<LxUpdateAlert> _alerts =
      StreamController<LxUpdateAlert>.broadcast();

  @override
  bool get isRunning => running;

  @override
  Stream<LxLogEntry> get logs => _logs.stream;

  @override
  Stream<LxUpdateAlert> get updateAlerts => _alerts.stream;

  @override
  Map<String, LxSourceDecl> get sources => Map.unmodifiable(_sources);

  @override
  LxScriptInfo? get script => null;

  @override
  Future<Map<String, LxSourceDecl>> start(
    LxScriptInfo script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    running = true;
    _sources = {
      'lx_test': const LxSourceDecl(
        key: 'lx_test',
        name: 'LX 测试',
        actions: ['musicUrl'],
        qualitys: ['flac', '320k', '128k'],
      ),
    };
    return Map<String, LxSourceDecl>.from(_sources);
  }

  @override
  Future<String> getMusicUrl({
    required String source,
    required Map<String, dynamic> musicInfo,
    required String quality,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    calls.add((quality: quality, hash: musicInfo['hash']));
    requestedTimeouts.add(timeout);
    if (resolveDelay > Duration.zero) {
      await Future<void>.delayed(resolveDelay);
    }
    final failure = error;
    if (failure != null) throw failure;
    if (unsupportedQualities.contains(quality)) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '该档位不可用',
      );
    }
    if (rejectQualities.contains(quality)) {
      throw const LxResolveRejectedException('音源未返回有效的播放地址');
    }
    return 'https://cdn.example/lx/$quality.mp3';
  }

  @override
  Future<LxLyricResult> getLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 20),
  }) async => const LxLyricResult(lyric: '');

  @override
  Future<String> getPic({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) async => '';

  @override
  Future<dynamic> search({
    required String source,
    required String action,
    required String keyword,
    int page = 1,
    int limit = 20,
    Duration timeout = const Duration(seconds: 20),
  }) async => const [];

  @override
  Future<void> dispose() async {
    running = false;
  }

  @override
  Future<void> close() async {
    running = false;
    if (!_logs.isClosed) await _logs.close();
    if (!_alerts.isClosed) await _alerts.close();
  }
}

const _lxTestScript = '''
/**
 * @name 降档测试音源
 * @description fake
 * @version 1.0.0
 */
globalThis.lx.on('request', () => {});
''';

/// 激活一个脚本源（key=lx_test）的管理器；引擎由 [_FakeResolveEngine] 驱动。
Future<({SourceManager manager, _FakeResolveEngine engine})>
_lxManager() async {
  final engine = _FakeResolveEngine();
  final supervisor = LxEngineSupervisor(engineFactory: () => engine);
  final manager = SourceManager(
    engine: supervisor,
    settings: testSettingsRegistry(),
  );
  await manager.init();
  addTearDown(manager.dispose);
  await manager.importScript(_lxTestScript, activate: true);
  return (manager: manager, engine: engine);
}

/// LX 曲目：音质条目带 hash，验证降档时 `musicInfo.hash` 同步替换。
SourceTrack _lxTrack() => SourceTrack(
  sourceKey: 'lx_test',
  origin: 'lx',
  title: '降档测试',
  artist: '歌手',
  album: '专辑',
  qualities: const [
    SourceQuality(type: 'flac', hash: 'flac-hash'),
    SourceQuality(type: '320k', hash: '320-hash'),
    SourceQuality(type: '128k', hash: '128-hash'),
  ],
  raw: const {'id': 'song-1', 'hash': 'raw-hash'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late HttpServer server;
  late int port;
  late List<Uri> requests;
  Completer<void>? gate;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    gate = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((request) async {
      requests.add(request.uri);
      if (request.method == 'POST') {
        await utf8.decoder.bind(request).join();
      }
      if (gate != null) await gate!.future;
      request.response.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      switch (request.uri.path) {
        case '/api/music/search':
          final limit = int.tryParse(
            request.uri.queryParameters['limit'] ?? '',
          );
          if (limit == 1) {
            request.response.write(
              jsonEncode({
                'list': [
                  {'id': 'any-1', 'name': '第一首', 'singer': '歌手'},
                ],
                'total': 3,
              }),
            );
          } else {
            request.response.write(
              jsonEncode({
                'list': [
                  {
                    'id': 'any-9',
                    'name': '测试曲目',
                    'singer': '测试歌手',
                    'interval': '03:00',
                    'meta': {
                      'albumName': '测试专辑',
                      'source': 'tx',
                      'picUrl': 'http://127.0.0.1:1/cover.jpg',
                      'qualitys': {
                        '320k': {'sizeStr': '8.5MB'},
                      },
                    },
                  },
                ],
                'total': 1,
                'limit': 30,
                'page': 1,
              }),
            );
          }
        case '/api/music/url':
          request.response.write(
            jsonEncode({'url': 'http://127.0.0.1:1/stream.mp3'}),
          );
        case '/api/music/lyric':
          request.response.write(
            jsonEncode({
              'info': {'lyric': '[00:00.00]hello', 'tlyric': '[00:00.00]你好'},
            }),
          );
        case '/api/music/pic':
          request.response.write(
            jsonEncode({'url': 'http://127.0.0.1:1/pic.jpg'}),
          );
        default:
          request.response
            ..statusCode = 404
            ..write('{}');
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<SourceManager> configuredManager() async {
    final manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    await manager.updateAnyListenConfig(
      AnyListenConfig(serverUrl: 'http://127.0.0.1:$port', enabled: true),
    );
    return manager;
  }

  group('SourceManagerMusicSource · 元信息', () {
    test('capabilities 与路由一致：内置平台歌词/封面为原生能力', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);

      final kw = SourceManagerMusicSource('kw', manager);
      expect(kw.key, 'kw');
      expect(kw.capabilities.search, isFalse);
      expect(kw.capabilities.resolveUrl, isFalse);
      // 内置平台歌词/封面/专辑为 Dart 原生实现（脚本未声明时也可用）。
      expect(kw.capabilities.lyrics, isTrue);
      expect(kw.capabilities.artwork, isTrue);
      expect(kw.capabilities.collection, isTrue);
      expect(kw.capabilities.favorite, isFalse);

      // wy 同五平台一致；取链仍需要脚本。
      final wy = SourceManagerMusicSource('wy', manager);
      expect(wy.capabilities.lyrics, isTrue);
      expect(wy.capabilities.artwork, isTrue);
      expect(wy.capabilities.resolveUrl, isFalse);

      // manager 生命周期由 main 管理：init/dispose 为空实现。
      await kw.init();
      await kw.dispose();
    });

    test('capabilities：any-listen 已配置时全能力', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );
      expect(source.capabilities.search, isTrue);
      expect(source.capabilities.pagination, isTrue);
      expect(source.capabilities.resolveUrl, isTrue);
      expect(source.capabilities.lyrics, isTrue);
      expect(source.capabilities.artwork, isTrue);
      expect(source.capabilities.collection, isFalse);
    });

    test('displayName 从可搜索画像读取；停用 / 未知 key 回退；adopt 按 key', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );
      expect(source.displayName, AnyListenSource.displayName);
      // 停用后回退 key（路由仍可命中历史曲目）。
      await manager.setChannelEnabled(AnyListenSource.sourceKey, false);
      expect(source.displayName, AnyListenSource.sourceKey);

      final kw = SourceManagerMusicSource('kw', manager);
      // 无脚本 / 不可搜索的内置渠道回退 key。
      expect(kw.displayName, 'kw');
      await manager.setChannelEnabled('kw', false);
      expect(kw.displayName, 'kw');
      // 画像里不存在的 key（脚本已下架等）回退 key 本身。
      expect(SourceManagerMusicSource('gone', manager).displayName, 'gone');

      final own = Track(
        id: const TrackId(AnyListenSource.sourceKey, 'x'),
        title: 't',
        origin: TrackOrigin.anyListen,
      );
      final other = Track(
        id: const TrackId('kw', 'x'),
        title: 't',
        origin: TrackOrigin.builtin,
      );
      expect(source.adopt(own), same(own));
      expect(source.adopt(other), isNull);
    });

    test('collection：无能力（脚本源）抛 SourceFailure(unsupported)', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('lx_custom', manager);
      expect(source.capabilities.collection, isFalse);

      await expectLater(
        source.collection(const CollectionRef(type: 'album', id: 'a')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });

    test('collection：内置平台仅专辑类型支持（歌单/艺人抛 unsupported）', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);
      expect(source.capabilities.collection, isTrue);

      await expectLater(
        source.collection(const CollectionRef(type: 'playlist', id: 'a')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });

    test('collection：内置平台专辑路由到 SourceManager.fetchAlbum', () async {
      final original = BuiltinSearch.transport;
      BuiltinSearch.transport = BuiltinTransport(
        dio: createAppDio(
          adapter: MockDioAdapter(
            (options) async => textResponse(
              "{'albumid':'1433','name':'黑色香水','artist':'曹方',"
              "'songnum':'12','musiclist':[{'id':'81642','name':'黑色香水',"
              "'artist':'曹方','album':'黑色香水','albumId':1433,"
              "'duration':'240','N_MINFO':'level:h,bitrate:320,format:mp3,size:9.17Mb'}]}",
            ),
          ),
        ),
      );
      addTearDown(() => BuiltinSearch.transport = original);

      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);
      final page = await source.collection(
        const CollectionRef(type: 'album', id: '1433'),
      );
      expect(page.items, hasLength(1));
      expect(page.items.single.id, const TrackId('kw', '81642'));
      expect(page.items.single.payload['albumId'], '1433');
      expect(page.hasMore, isFalse, reason: 'songnum=12 < 默认每页 50');
    });
  });

  group('SourceManagerMusicSource · 歌手 / 歌词', () {
    test('searchArtists / searchLyrics：非内置源无能力 → unsupported', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('lx_custom', manager);
      expect(source.capabilities.artist, isFalse);
      expect(source.capabilities.lyricSearch, isFalse);

      await expectLater(
        source.searchArtists(const SearchQuery(keyword: 'x')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
      await expectLater(
        source.searchLyrics(const SearchQuery(keyword: 'x')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });

    test('searchArtists / searchLyrics：内置平台未配脚本时能力位与搜索同门', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);
      // 与 search 同一门（`_isBuiltinSearchable`：脚本可取链才宣称可用），
      // 避免 UI 显示一个必然失败的入口。
      expect(source.capabilities.search, isFalse);
      expect(source.capabilities.artist, isFalse);
      expect(source.capabilities.lyricSearch, isFalse);

      await expectLater(
        source.searchArtists(const SearchQuery(keyword: '周杰伦')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
      await expectLater(
        source.searchLyrics(const SearchQuery(keyword: '雨下整夜')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });
  });

  group('SourceManagerMusicSource · search/resolve/lyrics/artwork', () {
    test('search：SourceTrack → Track 映射，hasMore/total 原样透传', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(
        const SearchQuery(keyword: '测试', page: 1, limit: 30),
      );

      expect(result.items, hasLength(1));
      expect(result.total, 1);
      expect(result.hasMore, isFalse);

      final track = result.items.single;
      expect(track.id, const TrackId(AnyListenSource.sourceKey, 'any-9'));
      expect(track.title, '测试曲目');
      expect(track.artists.single.name, '测试歌手');
      expect(track.album, '测试专辑');
      expect(track.duration, const Duration(minutes: 3));
      expect(track.origin, TrackOrigin.anyListen);
      expect(track.artwork?.uri.toString(), 'http://127.0.0.1:1/cover.jpg');
      expect(track.qualities.single.type, '320k');
      expect(track.qualities.single.size, '8.5MB');
      // payload 必须与服务器返回对象同引用（raw 原样回传不变量）。
      expect(track.payload['id'], 'any-9');

      expect(requests.single.path, '/api/music/search');
      expect(requests.single.queryParameters['name'], '测试');
      expect(requests.single.queryParameters['page'], '1');
      expect(requests.single.queryParameters['limit'], '30');
    });

    test('search：page/limit 透传，total 推断 hasMore', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(
        const SearchQuery(keyword: 'x', page: 2, limit: 1),
      );
      expect(result.items, hasLength(1));
      expect(result.total, 3);
      expect(result.hasMore, isTrue, reason: 'page*limit=2 < total=3');
      expect(requests.single.queryParameters['page'], '2');
      expect(requests.single.queryParameters['limit'], '1');
    });

    test('search：取消令牌生效（前/后检查都丢弃结果）', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      // 请求前已取消：不发网络请求。
      final cancelled = CancelToken()..cancel();
      final early = await source.search(
        const SearchQuery(keyword: 'x'),
        cancel: cancelled,
      );
      expect(early.items, isEmpty);
      expect(requests, isEmpty);

      // 请求中被取消：结果丢弃。
      gate = Completer<void>();
      final token = CancelToken();
      final pending = source.search(
        const SearchQuery(keyword: 'x'),
        cancel: token,
      );
      // 等请求到达服务器后再取消。
      while (requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      token.cancel();
      gate!.complete();
      final late = await pending;
      expect(late.items, isEmpty);
    });

    test('resolve：返回 PlayableStream（URL 来自 manager.resolveStream）', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(const SearchQuery(keyword: 'x'));
      final stream = await source.resolve(
        result.items.single,
        preferredQuality: const AudioQuality(type: '320k'),
      );
      expect(stream.uri, Uri.parse('http://127.0.0.1:1/stream.mp3'));
      expect(stream.headers, isEmpty);
    });

    test('lyrics：LxLyricResult → LyricsDoc（含翻译）', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(const SearchQuery(keyword: 'x'));
      final doc = await source.lyrics(result.items.single);
      expect(doc, isNotNull);
      expect(doc!.lyric, '[00:00.00]hello');
      expect(doc.translation, '[00:00.00]你好');
    });

    test('artwork：URL → Artwork；空 URL 返回 null', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(const SearchQuery(keyword: 'x'));
      final art = await source.artwork(result.items.single);
      expect(art, isNotNull);
      expect(art!.uri, Uri.parse('http://127.0.0.1:1/pic.jpg'));

      // 无 decl 的内置平台：fetchPic 返回 null → artwork null。
      final builtinSource = SourceManagerMusicSource('kw', manager);
      final builtinTrack = Track(
        id: const TrackId('kw', 'x'),
        title: 't',
        origin: TrackOrigin.builtin,
        payload: const {'id': 'x'},
      );
      expect(await builtinSource.artwork(builtinTrack), isNull);
    });

    test('无可用源：lyrics 返回 null，resolve 抛 SourceFailure(scriptError)', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);
      final track = Track(
        id: const TrackId('kw', 'x'),
        title: 't',
        origin: TrackOrigin.builtin,
        payload: const {'id': 'x'},
      );

      expect(await source.lyrics(track), isNull);
      await expectLater(
        source.resolve(track),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.scriptError,
          ),
        ),
      );
    });

    test('search：manager 异常归一化为 SourceFailure(scriptError)', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);

      await expectLater(
        source.search(const SearchQuery(keyword: 'x')),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.scriptError)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('search：平台返回 failed 时抛 SourceFailure（不静默成空结果）', () async {
      final original = BuiltinSearch.transport;
      addTearDown(() => BuiltinSearch.transport = original);
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((_) async => textResponse('{}', statusCode: 500)),
      );
      BiliApi.reset();

      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('bili', manager);

      await expectLater(
        source.search(const SearchQuery(keyword: 'x')),
        throwsA(isA<SourceFailure>()),
        reason: '失败必须在边界暴露，换源页才能把 B 站列进失败源',
      );
    });
  });

  group('SourceManager · 取链降档 / 原生流透传', () {
    test('notFound：按 kLxQualityOrder 降一档再试，musicInfo.hash 同步替换', () async {
      final fixture = await _lxManager();
      fixture.engine.rejectQualities.add('flac');

      final stream = await fixture.manager.resolveStream(
        _lxTrack(),
        requestedQuality: 'flac',
      );

      expect(stream.uri.path, '/lx/320k.mp3');
      expect(fixture.engine.calls.map((call) => call.quality), [
        'flac',
        '320k',
      ], reason: 'flac 没有地址 → 换下一档 320k');
      expect(fixture.engine.calls.map((call) => call.hash), [
        'flac-hash',
        '320-hash',
      ], reason: '酷狗等平台不同音质对应不同 hash，降档必须一起换');
    });

    test('unsupported：同样降档', () async {
      final fixture = await _lxManager();
      fixture.engine.unsupportedQualities.add('flac');

      final stream = await fixture.manager.resolveStream(
        _lxTrack(),
        requestedQuality: 'flac',
      );

      expect(stream.uri.path, '/lx/320k.mp3');
      expect(fixture.engine.calls, hasLength(2));
    });

    test('降档最多 2 档：三档都不可用时抛最后一次失败', () async {
      final fixture = await _lxManager();
      fixture.engine.rejectQualities.addAll(['flac', '320k', '128k']);

      await expectLater(
        fixture.manager.resolveStream(_lxTrack(), requestedQuality: 'flac'),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.notFound,
          ),
        ),
      );
      expect(fixture.engine.calls.map((call) => call.quality), [
        'flac',
        '320k',
        '128k',
      ], reason: '首次 + 最多 2 次降档');
    });

    test('网络 / 脚本故障不降档（交给目录层同档位重试）', () async {
      final fixture = await _lxManager();
      fixture.engine.error = const LxEngineException('网络抖动');

      await expectLater(
        fixture.manager.resolveStream(_lxTrack(), requestedQuality: 'flac'),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.scriptError,
          ),
        ),
      );
      expect(fixture.engine.calls.map((call) => call.quality), [
        'flac',
      ], reason: '暂时故障换档只会多花一次脚本调用');
    });

    test('timeout 已耗尽：一档都不发起，按 timeout 上报', () async {
      final fixture = await _lxManager();

      await expectLater(
        fixture.manager.resolveStream(
          _lxTrack(),
          requestedQuality: 'flac',
          timeout: Duration.zero,
        ),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.timeout)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      expect(fixture.engine.calls, isEmpty);
    });

    test('降档受调用方 deadline 约束：剩余不足后不再发起下一档', () async {
      final fixture = await _lxManager();
      fixture.engine
        ..rejectQualities.addAll(['flac', '320k', '128k'])
        ..resolveDelay = const Duration(milliseconds: 180);

      final watch = Stopwatch()..start();
      await expectLater(
        fixture.manager.resolveStream(
          _lxTrack(),
          requestedQuality: 'flac',
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.notFound,
          ),
        ),
      );
      watch.stop();

      expect(fixture.engine.calls.map((call) => call.quality), [
        'flac',
        '320k',
      ], reason: '第二轮后预算为负，第三档不再发起');
      expect(
        fixture.engine.requestedTimeouts.first.inMilliseconds,
        lessThanOrEqualTo(300),
      );
      expect(
        fixture.engine.requestedTimeouts.last.inMilliseconds,
        lessThan(300),
        reason: '第二档只拿到剩余预算',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('B 站原生取链：headers / expiresIn 经适配器原样透传', () async {
      final original = BuiltinSearch.transport;
      addTearDown(() => BuiltinSearch.transport = original);
      BiliApi.reset();
      BiliPlay.reset();
      final deadline = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final requested = <String>[];
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) async {
          final session = biliSessionResponse(request);
          if (session != null) return session;
          requested.add(request.uri.path);
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'dash': {
                  'duration': 200,
                  'audio': [
                    {
                      'id': 30280,
                      'baseUrl':
                          'https://cdn.example/audio.m4s?deadline=$deadline',
                      'bandwidth': 192000,
                    },
                  ],
                },
              },
            }),
          );
        }),
      );

      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('bili', manager);
      final track = Track(
        id: const TrackId('bili', 'BV1xx411c7mD'),
        title: 't',
        origin: TrackOrigin.builtin,
        qualities: const [AudioQuality(type: '192k')],
        // cid 已在 payload：跳过分 P 请求，只验证 playurl 之后的流形状。
        payload: const {'bvid': 'BV1xx411c7mD', 'cid': 12345},
      );

      final stream = await source.resolve(
        track,
        preferredQuality: const AudioQuality(type: '192k'),
      );

      expect(requested, ['/x/player/wbi/playurl']);
      expect(stream.headers['Referer'], BiliApi.streamHeaders['Referer']);
      expect(stream.headers['User-Agent'], BiliApi.streamHeaders['User-Agent']);
      expect(stream.expiresIn, isNotNull);
      expect(stream.expiresIn!.inMinutes, greaterThan(50));
    });
  });
}
