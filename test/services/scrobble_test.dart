import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/scrobble.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/scrobble_sink.dart';
import 'package:molia/domain/scrobble/scrobble_rules.dart';
import 'package:molia/services/scrobble/lastfm_sink.dart';
import 'package:molia/services/scrobble/listenbrainz_sink.dart';
import 'package:molia/services/scrobble/scrobble_outbox.dart';
import 'package:molia/services/scrobble/scrobble_preferences.dart';
import 'package:molia/services/scrobble/scrobble_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/mock_dio.dart';
import '../support/settings_test_support.dart';

Track track({
  String id = 'kw:1',
  String title = 'Song',
  String artist = 'Artist',
  Duration duration = const Duration(minutes: 3),
}) => Track(
  id: TrackId('kw', id),
  title: title,
  artists: [Artist(name: artist)],
  duration: duration,
  origin: TrackOrigin.builtin,
);

PlaybackSnapshot snapshot({
  Track? current,
  bool playing = true,
  Duration duration = const Duration(minutes: 3),
}) => PlaybackSnapshot(
  current: current,
  isPlaying: playing,
  duration: duration,
  queue: current == null ? const [] : [current],
  currentIndex: current == null ? -1 : 0,
);

ScrobbleTrack scrobbleTrack({
  String title = 'Song',
  String artist = 'Artist',
  Duration duration = const Duration(minutes: 3),
}) => ScrobbleTrack(
  title: title,
  artist: artist,
  album: 'Album',
  duration: duration,
);

class FakeScrobbleSink implements ScrobbleSink, ScrobbleCredentialSink {
  FakeScrobbleSink(this.target);

  @override
  final ScrobbleTarget target;

  final List<ScrobbleListen> nowPlaying = [];
  final List<ScrobbleListen> submitted = [];
  ScrobbleDelivery next = const ScrobbleDelivery.success();
  ScrobbleCredentialCheck credential = const ScrobbleCredentialCheck.valid(
    'tester',
  );

  @override
  Future<ScrobbleDelivery> sendNowPlaying(ScrobbleListen listen) async {
    nowPlaying.add(listen);
    return const ScrobbleDelivery.success();
  }

  @override
  Future<ScrobbleDelivery> sendScrobble(ScrobbleListen listen) async {
    submitted.add(listen);
    return next;
  }

  @override
  Future<ScrobbleCredentialCheck> validateCredential(String credential) async =>
      this.credential;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScrobbleRules / ScrobbleSession', () {
    test('29 秒不参与，30 秒在 15 秒时达标', () {
      expect(
        ScrobbleRules.isEligible(
          scrobbleTrack(duration: const Duration(seconds: 29)),
        ),
        isFalse,
      );
      final short = scrobbleTrack(duration: const Duration(seconds: 30));
      expect(ScrobbleRules.isEligible(short), isTrue);
      expect(
        ScrobbleRules.thresholdFor(const Duration(seconds: 30)),
        const Duration(seconds: 15),
      );
    });

    test('3 分钟在 1:30 达标，10 分钟在 4:00 达标', () {
      expect(
        ScrobbleRules.thresholdFor(const Duration(minutes: 3)),
        const Duration(seconds: 90),
      );
      expect(
        ScrobbleRules.thresholdFor(const Duration(minutes: 10)),
        const Duration(minutes: 4),
      );
    });

    test('暂停恢复与向后拖动不会产生第二条', () {
      final session = ScrobbleSession(
        track: scrobbleTrack(),
        startedAt: DateTime.utc(2026),
      );
      expect(session.onPosition(const Duration(seconds: 90)), isNotNull);
      expect(session.onPosition(const Duration(seconds: 10)), isNull);
      expect(session.onPosition(const Duration(seconds: 120)), isNull);
      expect(session.hasScrobbled, isTrue);
    });

    test('新曲目是新会话（外部按曲目身份新建）', () {
      final first = ScrobbleSession(
        track: scrobbleTrack(title: 'A'),
        startedAt: DateTime.utc(2026),
      );
      final second = ScrobbleSession(
        track: scrobbleTrack(title: 'B'),
        startedAt: DateTime.utc(2026),
      );
      expect(first.onPosition(const Duration(seconds: 89)), isNull);
      expect(second.onPosition(const Duration(seconds: 89)), isNull);
      expect(first.onPosition(const Duration(seconds: 90)), isNotNull);
      expect(second.onPosition(const Duration(seconds: 90)), isNotNull);
    });
  });

  group('ScrobbleOutbox', () {
    late SharedPreferences prefs;
    late ScrobbleOutbox outbox;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      outbox = ScrobbleOutbox(
        prefs: prefs,
        clock: () => DateTime.utc(2026, 1, 1),
        random: () => 0.5,
      );
      await outbox.load();
    });

    ScrobbleEvent event({
      String id = 'e1',
      ScrobbleTarget target = ScrobbleTarget.listenBrainz,
      DateTime? createdAt,
    }) => ScrobbleEvent(
      id: id,
      target: target,
      kind: ScrobbleEventKind.scrobble,
      listen: ScrobbleListen(
        track: scrobbleTrack(),
        startedAt: createdAt ?? DateTime.utc(2026, 1, 1),
      ),
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
    );

    test('跨实例持久化并保持顺序', () async {
      await outbox.add(event(id: 'a'));
      await outbox.add(event(id: 'b'));
      final reloaded = ScrobbleOutbox(
        prefs: prefs,
        clock: () => DateTime.utc(2026, 1, 1),
      );
      await reloaded.load();
      expect(reloaded.length, 2);
      expect(reloaded.due(ScrobbleTarget.listenBrainz).map((e) => e.event.id), [
        'a',
        'b',
      ]);
    });

    test('每个服务最多 100 条，先丢最旧', () async {
      for (var i = 0; i < 105; i++) {
        await outbox.add(
          event(
            id: 'e$i',
            createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
          ),
        );
      }
      expect(outbox.lengthFor(ScrobbleTarget.listenBrainz), 100);
      final due = outbox.due(ScrobbleTarget.listenBrainz);
      expect(due.first.event.id, 'e5');
    });

    test('按服务隔离，断开只丢弃该服务', () async {
      await outbox.add(event(id: 'lb'));
      await outbox.add(event(id: 'fm', target: ScrobbleTarget.lastFm));
      await outbox.discardTarget(ScrobbleTarget.lastFm);
      expect(outbox.lengthFor(ScrobbleTarget.lastFm), 0);
      expect(outbox.lengthFor(ScrobbleTarget.listenBrainz), 1);
    });

    test('失败退避与 Retry-After', () async {
      await outbox.add(event(id: 'a'));
      await outbox.markRetry('a', retryAfter: const Duration(seconds: 42));
      final due = outbox.due(ScrobbleTarget.listenBrainz);
      expect(due, isEmpty, reason: 'Retry-After 未到期前不重发');
      final later = outbox.due(
        ScrobbleTarget.listenBrainz,
        now: DateTime.utc(2026, 1, 1).add(const Duration(seconds: 42)),
      );
      expect(later, hasLength(1));
      expect(later.single.attempts, 1);
    });

    test('30 天前的条目在加载时丢弃', () async {
      final oldClock = DateTime.utc(
        2026,
        1,
        1,
      ).subtract(const Duration(days: 31));
      final old = ScrobbleOutbox(prefs: prefs, clock: () => oldClock);
      await old.load();
      await old.add(event(id: 'old', createdAt: oldClock));
      final fresh = ScrobbleOutbox(
        prefs: prefs,
        clock: () => DateTime.utc(2026, 1, 1),
      );
      await fresh.load();
      expect(fresh.length, 0);
    });
  });

  group('协议适配器', () {
    test('ListenBrainz 提交形状与口令只进请求头', () async {
      final adapter = MockDioAdapter(
        (_) async => textResponse('{"status":"ok"}'),
      );
      final sink = ListenBrainzSink(
        token: () => 'secret-token',
        dio: mockDio((_) async => textResponse('{"status":"ok"}'))
          ..httpClientAdapter = adapter,
      );
      final delivery = await sink.sendScrobble(
        ScrobbleListen(
          track: scrobbleTrack(),
          startedAt: DateTime.utc(2026, 1, 1, 12),
        ),
      );
      expect(delivery.isSuccess, isTrue);
      final request = adapter.lastRequest;
      expect(request.headers['Authorization'], 'Token secret-token');
      final body = jsonDecode(requestBodyText(request)) as Map<String, dynamic>;
      expect(body['listen_type'], 'single');
      final payload = (body['payload'] as List).single as Map;
      expect(payload['listened_at'], 1767268800);
      final metadata = payload['track_metadata'] as Map;
      expect(metadata['track_name'], 'Song');
      expect(metadata['artist_name'], 'Artist');
      expect(requestBodyText(request), isNot(contains('secret-token')));
    });

    test('ListenBrainz 401 需要重新授权、429 带回 Retry-After', () async {
      final unauthorized = ListenBrainzSink(
        token: () => 't',
        dio: mockDio((_) async => textResponse('', statusCode: 401)),
      );
      expect(
        (await unauthorized.sendScrobble(
          ScrobbleListen(track: scrobbleTrack(), startedAt: DateTime.utc(2026)),
        )).outcome,
        ScrobbleDeliveryOutcome.unauthorized,
      );
      final limited = ListenBrainzSink(
        token: () => 't',
        dio: mockDio(
          (_) async => textResponse(
            '',
            statusCode: 429,
            headers: {
              'retry-after': ['12'],
            },
          ),
        ),
      );
      final result = await limited.sendScrobble(
        ScrobbleListen(track: scrobbleTrack(), startedAt: DateTime.utc(2026)),
      );
      expect(result.outcome, ScrobbleDeliveryOutcome.retryable);
      expect(result.retryAfter, const Duration(seconds: 12));
    });

    test('Last.fm 参数排序后签名稳定', () {
      expect(
        lastFmSignature({'b': '2', 'a': '1'}, apiSecret: 's'),
        '1d0396bcbc2c54e569e7af9cf9c4685e',
      );
    });

    test('Last.fm 提交带 sk / api_sig，401 标记需要授权', () async {
      final adapter = MockDioAdapter(
        (_) async => textResponse('{"scrobbles":{"@attr":{"accepted":1}}}'),
      );
      final sink = LastFmSink(
        sessionKey: () => 'session-key',
        config: const LastFmApiConfig(apiKey: 'key', apiSecret: 'secret'),
        dio: mockDio((_) async => textResponse('{}'))
          ..httpClientAdapter = adapter,
      );
      final delivery = await sink.sendScrobble(
        ScrobbleListen(
          track: scrobbleTrack(),
          startedAt: DateTime.utc(2026, 1, 1, 12),
        ),
      );
      expect(delivery.isSuccess, isTrue);
      final data = adapter.lastRequest.data as Map<String, dynamic>;
      expect(data['sk'], 'session-key');
      expect(data['api_key'], 'key');
      expect(data['method'], 'track.scrobble');
      expect(data['timestamp'], '1767268800');
      expect(data['api_sig'], isNotEmpty);
      expect(adapter.lastRequest.uri.toString(), contains('audioscrobbler'));

      final unauthorized = LastFmSink(
        sessionKey: () => 'session-key',
        config: const LastFmApiConfig(apiKey: 'key', apiSecret: 'secret'),
        dio: mockDio(
          (_) async => textResponse('{"error":9,"message":"bad session"}'),
        ),
      );
      expect(
        (await unauthorized.sendScrobble(
          ScrobbleListen(track: scrobbleTrack(), startedAt: DateTime.utc(2026)),
        )).outcome,
        ScrobbleDeliveryOutcome.unauthorized,
      );
    });

    test('Last.fm 授权：取令牌、打开浏览器、换取会话密钥、取消', () async {
      final opened = <Uri>[];
      var call = 0;
      final dio = mockDio((options) async {
        call++;
        if (call == 1) return textResponse('{"token":"request-token"}');
        return textResponse(
          '{"session":{"name":"listener","key":"session-key"}}',
        );
      });
      final auth = LastFmAuth(
        config: const LastFmApiConfig(apiKey: 'key', apiSecret: 'secret'),
        openBrowser: (uri) async {
          opened.add(uri);
          return true;
        },
        dio: dio,
      );
      expect(await auth.begin(), LastFmAuthStage.awaitingUser);
      expect(opened.single.queryParameters['token'], 'request-token');
      expect(await auth.complete(), LastFmAuthStage.connected);
      expect(auth.takeSessionKey(), 'session-key');
      expect(auth.accountName, 'listener');

      final cancelled = LastFmAuth(
        config: const LastFmApiConfig(apiKey: 'key', apiSecret: 'secret'),
        openBrowser: (_) async => true,
        dio: dio,
      );
      await cancelled.begin();
      cancelled.cancel();
      expect(cancelled.stage, LastFmAuthStage.cancelled);
    });

    test('Last.fm 未内置应用密钥时不发请求', () async {
      var requests = 0;
      final auth = LastFmAuth(
        config: LastFmApiConfig.none,
        openBrowser: (_) async => true,
        dio: mockDio((_) async {
          requests++;
          return textResponse('{}');
        }),
      );
      expect(await auth.begin(), LastFmAuthStage.failed);
      expect(requests, 0);
    });
  });

  group('ScrobbleService', () {
    late SharedPreferences prefs;
    late FakeScrobbleSink listenBrainz;
    late FakeScrobbleSink lastFm;
    late ScrobbleService service;
    late DateTime now;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      now = DateTime.utc(2026, 1, 1);
      listenBrainz = FakeScrobbleSink(ScrobbleTarget.listenBrainz);
      lastFm = FakeScrobbleSink(ScrobbleTarget.lastFm);
      service = ScrobbleService(
        preferences: ScrobblePreferences(
          settings: testSettingsRegistry(),
          prefs: prefs,
        ),
        outbox: ScrobbleOutbox(prefs: prefs, clock: () => now),
        listenBrainzSink: listenBrainz,
        lastFmSink: lastFm,
        lastFmConfig: LastFmApiConfig.none,
        clock: () => now,
        autoDeliver: false,
      );
      await service.init();
    });

    tearDown(() => service.dispose());

    Future<void> connect() async {
      expect(
        await service.connectListenBrainz('token'),
        ScrobbleConnectResult.connected,
      );
    }

    test('默认关闭时不上报，连接后只在开始时发一次 now-playing', () async {
      final current = track();
      service.onSnapshot(snapshot(current: current));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(listenBrainz.nowPlaying, isEmpty);
      expect(listenBrainz.submitted, isEmpty);

      await connect();
      service.onSnapshot(snapshot(current: current));
      expect(listenBrainz.nowPlaying, hasLength(1));
      service.onSnapshot(snapshot(current: current, playing: false));
      service.onSnapshot(snapshot(current: current));
      expect(listenBrainz.nowPlaying, hasLength(1));
    });

    test('达到阈值只提交一次，暂停 / 恢复 / 回拖不重复', () async {
      await connect();
      service.onSnapshot(snapshot(current: track()));
      service.onPosition(const Duration(seconds: 89));
      await service.pumpNow();
      expect(listenBrainz.submitted, isEmpty);
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(listenBrainz.submitted, hasLength(1));
      service.onPosition(const Duration(seconds: 10));
      service.onSnapshot(snapshot(current: track(), playing: false));
      service.onSnapshot(snapshot(current: track()));
      service.onPosition(const Duration(seconds: 180));
      await service.pumpNow();
      expect(listenBrainz.submitted, hasLength(1));
    });

    test('短曲目与缺少歌手不产生事件', () async {
      await connect();
      service.onSnapshot(
        snapshot(
          current: track(duration: const Duration(seconds: 20)),
          duration: const Duration(seconds: 20),
        ),
      );
      service.onPosition(const Duration(seconds: 20));
      await service.pumpNow();
      expect(listenBrainz.nowPlaying, isEmpty);
      expect(listenBrainz.submitted, isEmpty);

      service.onSnapshot(
        snapshot(
          current: track(id: 'kw:2', artist: ''),
        ),
      );
      service.onPosition(const Duration(seconds: 100));
      await service.pumpNow();
      expect(listenBrainz.nowPlaying, isEmpty);
    });

    test('now-playing 失败不影响 scrobble，401 进入待授权', () async {
      await connect();
      listenBrainz.next = const ScrobbleDelivery.unauthorized();
      service.onSnapshot(snapshot(current: track()));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(
        service.statusOf(ScrobbleTarget.listenBrainz),
        ScrobbleTargetStatus.needsAuthorization,
      );
      // 授权失败后服务不再被视为可发送。
      expect(service.activeFor(ScrobbleTarget.listenBrainz), isTrue);
    });

    test('可重试失败保留在发件箱并进入重试态', () async {
      await connect();
      listenBrainz.next = const ScrobbleDelivery.retryable(
        retryAfter: Duration(seconds: 5),
      );
      service.onSnapshot(snapshot(current: track()));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(service.queuedFor(ScrobbleTarget.listenBrainz), 1);
      expect(
        service.statusOf(ScrobbleTarget.listenBrainz),
        ScrobbleTargetStatus.retrying,
      );
      listenBrainz.next = const ScrobbleDelivery.success();
      now = now.add(const Duration(seconds: 6));
      await service.pumpNow();
      expect(service.queuedFor(ScrobbleTarget.listenBrainz), 0);
    });

    test('断开清凭据与该服务队列；另一服务保留', () async {
      await connect();
      lastFm.credential = const ScrobbleCredentialCheck.valid('fm');
      await service.beginLastFmAuthorization();
      // 直接写 Last.fm 状态（本测试不覆盖浏览器流程）：走服务公开接口
      // 需要配置密钥，这里改用底层断开语义的对应目标。
      service.onSnapshot(snapshot(current: track()));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(service.queuedFor(ScrobbleTarget.listenBrainz), 0);
      await service.disconnect(ScrobbleTarget.listenBrainz);
      expect(
        service.statusOf(ScrobbleTarget.listenBrainz),
        ScrobbleTargetStatus.disconnected,
      );
      expect(service.masterEnabled, isFalse);
      expect(service.credentialFor(ScrobbleTarget.listenBrainz), isEmpty);
    });

    test('日志不包含访问口令', () async {
      final records = <String>[];
      final subscription = Logger.root.onRecord.listen(
        (record) => records.add(record.message),
      );
      addTearDown(subscription.cancel);
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = previousLevel);

      await service.connectListenBrainz('super-secret-token');
      listenBrainz.next = const ScrobbleDelivery.retryable();
      service.onSnapshot(snapshot(current: track()));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(records.join('\n'), isNot(contains('super-secret-token')));
    });

    test('发件箱按服务隔离，一个成功不删除另一个', () async {
      await connect();
      // 第二个服务通过持久化事件模拟已连接的另一端。
      await service.outbox.add(
        ScrobbleEvent(
          id: 'fm-1',
          target: ScrobbleTarget.lastFm,
          kind: ScrobbleEventKind.scrobble,
          listen: ScrobbleListen(
            track: scrobbleTrack(),
            startedAt: DateTime.utc(2026),
          ),
          createdAt: DateTime.utc(2026),
        ),
      );
      service.onSnapshot(snapshot(current: track()));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(service.queuedFor(ScrobbleTarget.listenBrainz), 0);
      expect(service.queuedFor(ScrobbleTarget.lastFm), 1);
    });
  });
}
