import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/services/track_local_data_controller.dart';
import 'package:molia/services/track_local_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_music_source.dart';
import '../support/memory_cache_storage.dart';

/// 单曲本地数据刷新控制器：下载记录防抖 / 缓存修订立即重载 / 单飞 + 尾随 /
/// 切歌代次守卫 / 同步种子 / dispose 都在纯 Dart 下按虚拟时间断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('setTrack 立即发布下载种子，再异步补全缓存占用', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.records.put(_record('a'));

    final gate = Completer<void>();
    harness.service.gates['kw:a'] = gate;
    harness.service.results['kw:a'] = const TrackLocalData(
      audioCache: CacheUsage(bytes: 100, count: 1),
    );

    harness.controller.setTrack(_track('a'));

    // 首帧同步就有下载档：不能先闪一下「未下载」。
    expect(
      harness.controller.value.data?.audioState,
      LocalPartState.downloaded,
    );
    expect(harness.controller.value.data?.audioCache, CacheUsage.zero);
    expect(harness.service.loadCalls, 1);

    gate.complete();
    await pumpEventQueue();

    expect(harness.controller.value.data?.audioState, LocalPartState.cached);
    expect(
      harness.controller.value.data?.audioCache,
      const CacheUsage(bytes: 100, count: 1),
    );
  });

  test('load 同时读取音频缓存开关', () async {
    SharedPreferences.setMockInitialValues({
      CacheService.keyAudioEnabled: false,
    });
    final harness = _Harness();
    addTearDown(harness.dispose);

    harness.controller.setTrack(_track('a'));
    await pumpEventQueue();

    expect(harness.controller.value.audioEnabled, isFalse);
  });

  test('下载记录连续变化：防抖窗口合并为一次重载', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.controller.setTrack(_track('a'));
    await pumpEventQueue();
    final initialLoads = harness.service.loadCalls;

    // 同批记录通知：每个都取消上一个窗口，只留一个待执行定时器。
    for (var i = 0; i < 10; i++) {
      harness.records.put(_record('a', quality: 'q$i'));
    }
    expect(harness.scheduler.activeTimers, hasLength(1));
    expect(harness.service.loadCalls, initialLoads, reason: '窗口内不扫盘');

    harness.scheduler.elapse(const Duration(milliseconds: 299));
    expect(harness.service.loadCalls, initialLoads, reason: '不到窗口不重载');

    harness.scheduler.elapse(const Duration(milliseconds: 1));
    await pumpEventQueue();
    expect(harness.service.loadCalls, initialLoads + 1, reason: '只补一次');
    expect(harness.scheduler.activeTimers, isEmpty);
  });

  test('缓存修订立即重载并撤销待执行的记录防抖', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.controller.setTrack(_track('a'));
    await pumpEventQueue();
    final initialLoads = harness.service.loadCalls;

    harness.records.put(_record('a', quality: '320k'));
    expect(harness.scheduler.activeTimers, hasLength(1));

    harness.cacheService.revision.value++;
    expect(harness.scheduler.activeTimers, isEmpty, reason: '修订到达时待执行的防抖必须撤销');
    await pumpEventQueue();
    expect(harness.service.loadCalls, initialLoads + 1, reason: '立即重载');

    // 已撤销的窗口不能再补一次。
    harness.scheduler.elapse(const Duration(milliseconds: 300));
    await pumpEventQueue();
    expect(harness.service.loadCalls, initialLoads + 1);
  });

  test('加载单飞：进行中再触发只补一次尾随重载', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    final gate = Completer<void>();
    harness.service.gates['kw:a'] = gate;

    harness.controller.setTrack(_track('a'));
    expect(harness.service.loadCalls, 1);

    final firstRefresh = harness.controller.refreshNow();
    final secondRefresh = harness.controller.refreshNow();
    harness.cacheService.revision.value++;
    await pumpEventQueue();
    expect(harness.service.loadCalls, 1, reason: '加载中不并发发起目录扫描');

    gate.complete();
    await Future.wait([firstRefresh, secondRefresh]);
    await pumpEventQueue();
    expect(harness.service.loadCalls, 2, reason: '结束后只补跑一次');
  });

  test('切歌：旧曲目的在途结果不覆盖新曲目状态', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    final gateA = Completer<void>();
    harness.service.gates['kw:a'] = gateA;
    harness.service.results['kw:a'] = const TrackLocalData(
      audioCache: CacheUsage(bytes: 111, count: 1),
    );

    harness.controller.setTrack(_track('a'));
    expect(harness.service.loadCalls, 1);

    harness.records.put(_record('b'));
    harness.controller.setTrack(_track('b'));
    expect(
      harness.controller.value.data?.audioState,
      LocalPartState.downloaded,
      reason: '切歌先同步播种新曲目的下载档',
    );

    final observed = <TrackLocalDataState>[];
    harness.controller.addListener(
      () => observed.add(harness.controller.value),
    );

    gateA.complete();
    await pumpEventQueue();

    expect(
      observed.where((state) => state.data?.audioCache.bytes == 111),
      isEmpty,
      reason: '旧代次结果永远不能回填',
    );
    expect(harness.service.loadedTracks, [
      const TrackId('kw', 'a'),
      const TrackId('kw', 'b'),
    ]);
    expect(harness.controller.value.data?.download?.originSongId, 'b');
  });

  test('dispose：撤销防抖、退订记录 / 缓存并且不再响应', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.controller.setTrack(_track('a'));
    await pumpEventQueue();

    harness.records.put(_record('a', quality: '320k'));
    final timer = harness.scheduler.activeTimers.single;
    final beforeDispose = harness.service.loadCalls;

    harness.controller.dispose();
    expect(timer.active, isFalse, reason: '离开页面不留防抖定时器');

    harness.records.put(_record('a', quality: 'flac'));
    harness.cacheService.revision.value++;
    harness.scheduler.elapse(const Duration(milliseconds: 300));
    await pumpEventQueue();

    expect(harness.service.loadCalls, beforeDispose);
    expect(harness.scheduler.activeTimers, isEmpty);
  });

  group('selectLocalDataQuality：音质选择顺序', () {
    const available = ['320k', 'flac'];

    test('显式选择优先于下载 / 缓存 / 偏好', () {
      expect(
        selectLocalDataQuality(
          explicitChoice: 'flac',
          downloadedQuality: '320k',
          cachedQualities: const ['128k'],
          preferredQuality: '192k',
          availableQualities: available,
        ),
        'flac',
      );
    });

    test('没有显式选择时已下载音质优先于缓存', () {
      expect(
        selectLocalDataQuality(
          downloadedQuality: '320k',
          cachedQualities: const ['128k'],
          preferredQuality: '192k',
          availableQualities: available,
        ),
        '320k',
      );
    });

    test('没有下载记录时取第一条命中缓存的音质', () {
      expect(
        selectLocalDataQuality(
          cachedQualities: const ['128k', '320k'],
          preferredQuality: '192k',
          availableQualities: available,
        ),
        '128k',
      );
    });

    test('没有缓存时回退下载偏好音质', () {
      expect(
        selectLocalDataQuality(
          preferredQuality: '192k',
          availableQualities: available,
        ),
        '192k',
      );
    });

    test('都没有时取曲目第一个可用音质', () {
      expect(selectLocalDataQuality(availableQualities: available), '320k');
    });

    test('空显式选择按未设置处理；没有可用音质返回空串', () {
      expect(
        selectLocalDataQuality(
          explicitChoice: '',
          preferredQuality: '192k',
          availableQualities: available,
        ),
        '192k',
      );
      expect(selectLocalDataQuality(), '');
    });
  });
}

Track _track(String id) => Track(
  id: TrackId('kw', id),
  title: 'Title $id',
  origin: TrackOrigin.lx,
  payload: {'id': id},
);

DownloadedTrack _record(String id, {String quality = '320k'}) =>
    DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: id,
      title: 'Title $id',
      filePath: '/downloads/$id.mp3',
      quality: quality,
      sizeBytes: 1024,
      downloadedAt: 1,
    );

class _Harness {
  _Harness() {
    records = DownloadRecords(supported: true, initialized: true);
    cacheService = CacheService(storage: MemoryCacheStorage());
    service = _FakeLocalDataService(records);
    controller = TrackLocalDataController(
      service: service,
      cacheService: cacheService,
      downloadRecords: records,
      timerFactory: scheduler.createTimer,
    );
  }

  late final DownloadRecords records;
  late final CacheService cacheService;
  late final _FakeLocalDataService service;
  late final TrackLocalDataController controller;
  final _FakeScheduler scheduler = _FakeScheduler();

  void dispose() {
    controller.dispose();
    records.dispose();
  }
}

/// 可编排的读取假件：挂起指定曲目的 load，返回预置快照。
class _FakeLocalDataService extends TrackLocalDataService {
  _FakeLocalDataService(this.records)
    : super(
        cacheService: CacheService(storage: MemoryCacheStorage()),
        artworkCache: ArtworkCache(
          cacheService: CacheService(storage: MemoryCacheStorage()),
        ),
        catalogService: CatalogService(registry: FakeSourceRegistry(const {})),
        downloadRecords: records,
      );

  final DownloadRecords records;
  final Map<String, Completer<void>> gates = {};
  final Map<String, TrackLocalData> results = {};
  int loadCalls = 0;
  final List<TrackId> loadedTracks = [];

  @override
  TrackLocalData downloadState(Track track) =>
      TrackLocalData(download: records.recordForTrack(track));

  @override
  Future<TrackLocalData> load(Track track) async {
    loadCalls++;
    loadedTracks.add(track.id);
    final gate = gates[track.id.uri];
    if (gate != null) await gate.future;
    return results[track.id.uri] ??
        TrackLocalData(download: records.recordForTrack(track));
  }
}

/// 虚拟时间调度：防抖定时器按累计时间触发。
class _FakeScheduler {
  final List<_FakeTimer> _timers = [];
  Duration _now = Duration.zero;

  Iterable<_FakeTimer> get activeTimers =>
      _timers.where((timer) => timer.active);

  TrackLocalDataTimerCancel createTimer(Duration delay, VoidCallback callback) {
    final timer = _FakeTimer(_now + delay, callback);
    _timers.add(timer);
    return timer.cancel;
  }

  void elapse(Duration duration) {
    _now += duration;
    for (final timer in List<_FakeTimer>.of(_timers)) {
      if (timer.active && timer.dueAt <= _now) timer.fire();
    }
  }
}

class _FakeTimer {
  _FakeTimer(this.dueAt, this.callback);

  final Duration dueAt;
  final VoidCallback callback;
  bool active = true;

  void cancel() => active = false;

  void fire() {
    if (!active) return;
    active = false;
    callback();
  }
}
