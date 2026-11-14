import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/services/download/download_manager.dart';
import 'package:molia/services/download/download_queue.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/services/download/download_requests.dart';
import 'package:molia/utils/download_failure_label.dart';

/// 下载请求面：资格四态、音频 / 歌词 / 封面入队与终态、批量计数。
void main() {
  late DownloadRecords records;
  late _FakeDownloadManager downloads;
  late DownloadRequests requests;

  Track makeTrack({String sourceKey = 'kw', String songId = '1'}) => Track(
    id: TrackId(sourceKey, songId),
    title: '测试歌曲',
    origin: TrackOrigin.builtin,
    qualities: const [
      AudioQuality(type: '128k'),
      AudioQuality(type: '320k'),
    ],
  );

  const localTrack = Track(
    id: TrackId(kLocalSourceKey, '/downloads/a.mp3'),
    title: '本地',
    origin: TrackOrigin.localFile,
  );

  /// 让请求层跑过 `ready` / 入队这些 await 点。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    records = DownloadRecords(initialized: true, supported: true);
    downloads = _FakeDownloadManager();
    requests = DownloadRequests(downloads: downloads, records: records);
  });

  tearDown(() {
    requests.dispose();
    downloads.dispose();
    records.dispose();
  });

  group('资格判定', () {
    test('ready：可按默认音质入队', () async {
      final track = makeTrack();

      expect(requests.statusOf(track), DownloadIntentStatus.ready);
      final future = requests.requestAudio(track);
      await settle();

      expect(downloads.starts.single.quality, '320k');
      downloads.lastTask!.markCompleted();
      expect(await future, isA<DownloadCompleted>());
    });

    test('alreadyDownloaded：已有音频记录不再入队', () async {
      records.put(
        const DownloadedTrack(
          originSourceKey: 'kw',
          originSongId: '1',
          title: '已下载',
          filePath: '/downloads/测试歌曲.mp3',
          sizeBytes: 1,
          downloadedAt: 1,
        ),
      );
      final track = makeTrack();

      expect(requests.statusOf(track), DownloadIntentStatus.alreadyDownloaded);
      final outcome = await requests.requestAudio(track);

      expect(outcome, isA<DownloadAlreadyDownloaded>());
      expect((outcome as DownloadAlreadyDownloaded).record.key, 'kw:1');
      expect(downloads.starts, isEmpty, reason: '已下载不重复入队');
    });

    test('active：有活动任务时不重复入队；不等待时立即返回', () async {
      final track = makeTrack();
      final task = DownloadTask(
        track: track,
        kind: DownloadTaskKind.audio,
        quality: '320k',
      );
      downloads.activeTask = task;

      expect(requests.statusOf(track), DownloadIntentStatus.active);
      final outcome = await requests.requestAudio(track, waitForActive: false);

      expect(outcome, isA<DownloadActive>());
      expect((outcome as DownloadActive).task, same(task));
      expect(downloads.starts, isEmpty);
    });

    test('active：waitForActive 为 true 时加入已有任务并等终态', () async {
      final track = makeTrack();
      final task = DownloadTask(
        track: track,
        kind: DownloadTaskKind.audio,
        quality: '320k',
      );
      downloads.activeTask = task;
      var sawJoined = false;

      final future = requests.requestAudio(
        track,
        onStarted: (task, {required bool joined}) {
          sawJoined = joined;
        },
      );
      await settle();
      expect(downloads.starts, isEmpty);
      expect(sawJoined, isTrue);

      task.markCompleted();
      expect(await future, isA<DownloadCompleted>());
    });

    test('unsupported：平台不支持 / 本地曲目给出既有失败原因', () async {
      downloads.supported = false;
      final platform = await requests.requestAudio(makeTrack());
      expect(platform, isA<DownloadUnsupported>());
      expect(
        (platform as DownloadUnsupported).reason.l10nKey,
        'downloadUnsupported',
      );

      downloads.supported = true;
      final local = await requests.requestAudio(localTrack);
      expect(local, isA<DownloadUnsupported>());
      expect(
        (local as DownloadUnsupported).reason.l10nKey,
        'downloadLocalTrack',
      );
      expect(downloads.starts, isEmpty);
    });
  });

  group('音频请求', () {
    test('显式音质优先于默认音质', () async {
      final future = requests.requestAudio(makeTrack(), quality: '128k');
      await settle();
      expect(downloads.starts.single.quality, '128k');
      downloads.lastTask!.markCompleted();
      await future;
    });

    test('完成：成功回读落库记录，onStarted 标记新入队', () async {
      final track = makeTrack();
      var started = false;
      var sawJoined = true;

      final future = requests.requestAudio(
        track,
        onStarted: (task, {required bool joined}) {
          started = true;
          sawJoined = joined;
        },
      );
      await settle();
      expect(started, isTrue);
      expect(sawJoined, isFalse);

      records.put(
        const DownloadedTrack(
          originSourceKey: 'kw',
          originSongId: '1',
          title: '测试歌曲',
          filePath: '/downloads/测试歌曲.mp3',
          sizeBytes: 1,
          downloadedAt: 1,
        ),
      );
      downloads.lastTask!.markCompleted();

      final outcome = await future;
      expect(outcome, isA<DownloadCompleted>());
      expect((outcome as DownloadCompleted).record?.key, 'kw:1');
    });

    test('失败：保留原错误对象交给文案映射', () async {
      const failure = SourceFailure(kind: FailureKind.network, message: '网络断了');
      final future = requests.requestAudio(makeTrack());
      await settle();
      downloads.lastTask!.markFailed(failure);

      final outcome = await future;
      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).error, same(failure));
    });

    test('取消：归一为 DownloadCancelled，不再当成失败', () async {
      final future = requests.requestAudio(makeTrack());
      await settle();
      downloads.lastTask!.markCancelled();

      final outcome = await future;
      expect(outcome, isA<DownloadCancelled>());
      expect((outcome as DownloadCancelled).task, same(downloads.lastTask));
    });
  });

  group('歌词 / 封面请求', () {
    test('歌词：等待分项任务完成，回读部分记录', () async {
      final track = makeTrack();
      final gate = downloads.lyricsGate = Completer<void>();
      final future = requests.requestLyrics(track);
      await settle();
      expect(downloads.lyricsTracks.single.id, track.id);

      records.put(
        const DownloadedTrack(
          originSourceKey: 'kw',
          originSongId: '1',
          title: '测试歌曲',
          lyricPath: '/downloads/lyrics/a.lrc',
          downloadedAt: 1,
        ),
      );
      gate.complete();

      final outcome = await future;
      expect(outcome, isA<DownloadCompleted>());
      expect(
        (outcome as DownloadCompleted).record?.lyricPath,
        '/downloads/lyrics/a.lrc',
      );
    });

    test('封面：等待分项任务完成', () async {
      final track = makeTrack();
      final gate = downloads.coverGate = Completer<void>();
      final future = requests.requestCover(track);
      await settle();
      expect(downloads.coverTracks.single.id, track.id);

      gate.complete();
      expect(await future, isA<DownloadCompleted>());
    });

    test('本地曲目：不进入分项队列，返回 unsupported', () async {
      final outcome = await requests.requestLyrics(localTrack);

      expect(outcome, isA<DownloadUnsupported>());
      expect(
        (outcome as DownloadUnsupported).reason.l10nKey,
        'downloadLocalTrack',
      );
      expect(downloads.lyricsTracks, isEmpty);
      expect(downloads.coverTracks, isEmpty);
    });

    test('分项失败 / 取消：同样归一成终态', () async {
      final track = makeTrack();
      final failureGate = downloads.lyricsGate = Completer<void>();
      final failureFuture = requests.requestLyrics(track);
      await settle();
      failureGate.completeError(
        const SourceFailure(kind: FailureKind.network, message: '取词失败'),
      );
      expect(await failureFuture, isA<DownloadFailed>());

      final cancelGate = downloads.coverGate = Completer<void>();
      final cancelFuture = requests.requestCover(track);
      await settle();
      cancelGate.completeError(
        const SourceFailure(
          kind: FailureKind.cancelled,
          message: '下载已取消',
          l10nKey: 'downloadCancelled',
        ),
      );
      expect(await cancelFuture, isA<DownloadCancelled>());
    });
  });

  test('startBatch：候选过滤交由下载服务，结果带实际入队数', () async {
    var notified = -1;
    final result = await requests.startBatch([
      makeTrack(),
      makeTrack(sourceKey: 'tx', songId: '2'),
    ], onEnqueued: (enqueued) => notified = enqueued);

    expect(notified, 2);
    expect(result.enqueued, 2);
    expect(result.done, 2);
    expect(result.failed, 0);
  });

  test('失败反馈：已知 key 精确映射，取消静默，未知异常走通用失败', () {
    final zh = lookupAppLocalizations(const Locale('zh'));

    expect(
      downloadFailureMessage(
        zh,
        const SourceFailure(
          kind: FailureKind.unsupported,
          message: '平台不支持',
          l10nKey: 'downloadUnsupported',
        ),
      ),
      zh.downloadUnsupported,
    );
    expect(
      downloadFailureMessage(
        zh,
        const SourceFailure(
          kind: FailureKind.unsupported,
          message: '已下载',
          l10nKey: 'downloadAlreadyExists',
        ),
      ),
      zh.downloadAlreadyExists,
    );
    expect(
      downloadFailureMessage(
        zh,
        const SourceFailure(
          kind: FailureKind.cancelled,
          message: '下载已取消',
          l10nKey: 'downloadCancelled',
        ),
      ),
      isNull,
      reason: '取消在所有入口静默',
    );
    expect(
      downloadFailureMessage(
        zh,
        const SourceFailure(kind: FailureKind.unknown, message: 'boom'),
      ),
      zh.downloadFailed('boom'),
    );
    final error = StateError('disk');
    expect(
      downloadFailureMessage(zh, error),
      zh.downloadFailed(error.toString()),
    );
  });
}

/// 请求测试只关心「入队参数 / 已有任务 / 终态」：其他命令面留空实现。
class _FakeDownloadManager extends DownloadManager {
  _FakeDownloadManager();

  @override
  bool supported = true;

  @override
  bool get publisherSupported => false;

  @override
  bool get notificationsSupported => false;

  @override
  bool initialized = true;

  @override
  Future<void> get ready async {}

  @override
  Future<void> init() async {}

  final ChangeNotifier _taskChanges = ChangeNotifier();

  @override
  Listenable get taskChanges => _taskChanges;

  @override
  DownloadTaskGroups get taskGroups =>
      (running: const [], queued: const [], failed: const []);

  DownloadTask? activeTask;

  /// 最近一次音频入队（测试据此手动推进终态）。
  DownloadTask? lastTask;

  /// 记录每次音频入队（含请求层替调用方选的音质）。
  final List<({Track track, String? quality})> starts = [];

  /// 分项任务的门闩：测试用 Completer 决定完成 / 失败 / 取消。
  Completer<void>? lyricsGate;
  Completer<void>? coverGate;
  final List<Track> lyricsTracks = [];
  final List<Track> coverTracks = [];

  @override
  DownloadTask? taskForTrack(Track track) =>
      activeTask?.track.id == track.id ? activeTask : null;

  @override
  Future<DownloadTask> enqueueDownload(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async {
    starts.add((track: track, quality: quality));
    return lastTask = DownloadTask(
      track: track,
      kind: DownloadTaskKind.audio,
      quality: quality ?? '320k',
      includeLyrics: includeLyrics,
      includeCover: includeCover,
    );
  }

  @override
  Future<void> download(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async {
    final task = await enqueueDownload(
      track,
      quality: quality,
      includeLyrics: includeLyrics,
      includeCover: includeCover,
    );
    await task.done;
  }

  @override
  Future<void> downloadLyrics(Track track) {
    lyricsTracks.add(track);
    return lyricsGate?.future ?? Future<void>.value();
  }

  @override
  Future<void> downloadCover(Track track) {
    coverTracks.add(track);
    return coverGate?.future ?? Future<void>.value();
  }

  @override
  Future<void> retryTask(DownloadTask task) async {}

  @override
  void dismissTask(DownloadTask task) {}

  @override
  void cancelTrack(Track track) {}

  @override
  List<({int index, Track track})> batchCandidates(Iterable<Track> tracks) =>
      const [];

  @override
  Future<(int, int)> downloadBatch(
    Iterable<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) async {
    final items = tracks.toList();
    onEnqueued?.call(items.length);
    return (items.length, 0);
  }

  @override
  Future<void> delete(DownloadedTrack record) async {}

  @override
  Future<(int, int)> importLocalFiles(Iterable<String> paths) async => (0, 0);

  @override
  Future<LocalRelocateResult> relocate(
    DownloadedTrack record,
    String newPath,
  ) async => LocalRelocateResult.relocated;

  @override
  Future<DownloadedTrack?> refreshLocalMetadata(DownloadedTrack record) async =>
      record;

  @override
  String defaultQualityFor(Track track) => '320k';

  @override
  Future<Uri?> localUriFor(Track track, {String? quality}) async => null;

  @override
  void dispose() {
    _taskChanges.dispose();
    super.dispose();
  }
}
