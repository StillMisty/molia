import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/scrobble.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/scrobble_sink.dart';
import 'package:molia/domain/scrobble/scrobble_rules.dart';
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
  });

  group('ScrobbleService', () {
    late SharedPreferences prefs;
    late FakeScrobbleSink listenBrainz;
    late ScrobbleService service;
    late DateTime now;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      now = DateTime.utc(2026, 1, 1);
      listenBrainz = FakeScrobbleSink(ScrobbleTarget.listenBrainz);
      service = ScrobbleService(
        preferences: ScrobblePreferences(
          settings: testSettingsRegistry(),
          prefs: prefs,
        ),
        outbox: ScrobbleOutbox(prefs: prefs, clock: () => now),
        listenBrainzSink: listenBrainz,
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
      // 授权失败后停止发送，但保留凭据与排队事件，等用户重新连接。
      final submitted = listenBrainz.submitted.length;
      await service.pumpNow();
      expect(listenBrainz.submitted.length, submitted);
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

    test('断开清凭据与该服务队列', () async {
      await connect();
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

    test('同意版本提升后停止发送，重新同意后恢复', () async {
      await connect();
      service.onSnapshot(snapshot(current: track()));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(listenBrainz.submitted, hasLength(1));

      // 模拟条款版本提升：设备本地记录的同意版本落后于当前常量。
      await prefs.setInt(ScrobblePreferences.keyListenBrainzConsent, 0);
      await service.reloadFromPreferences();
      expect(service.consentFor(ScrobbleTarget.listenBrainz), isFalse);
      expect(
        service.statusOf(ScrobbleTarget.listenBrainz),
        ScrobbleTargetStatus.needsConsent,
      );

      service.onSnapshot(snapshot(current: track(id: 'kw:2')));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(listenBrainz.submitted, hasLength(1), reason: '未重新同意不发送');

      await service.grantConsent(ScrobbleTarget.listenBrainz);
      service.onSnapshot(snapshot(current: track(id: 'kw:3')));
      service.onPosition(const Duration(seconds: 90));
      await service.pumpNow();
      expect(listenBrainz.submitted, hasLength(2));
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

    test('401 后不再排 0 延迟计时器', () async {
      final auto = ScrobbleService(
        preferences: ScrobblePreferences(
          settings: testSettingsRegistry(),
          prefs: prefs,
        ),
        outbox: ScrobbleOutbox(prefs: prefs, clock: () => now),
        listenBrainzSink: listenBrainz,
        clock: () => now,
      );
      addTearDown(auto.dispose);
      await auto.init();
      expect(
        await auto.connectListenBrainz('token'),
        ScrobbleConnectResult.connected,
      );
      listenBrainz.next = const ScrobbleDelivery.unauthorized();
      auto.onSnapshot(snapshot(current: track()));
      auto.onPosition(const Duration(seconds: 90));
      await auto.pumpNow();
      expect(
        auto.statusOf(ScrobbleTarget.listenBrainz),
        ScrobbleTargetStatus.needsAuthorization,
      );
      expect(auto.hasScheduledDelivery, isFalse);
    });
  });
}
