import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/services/download/download_intent.dart';
import 'package:molia/services/download/download_service.dart'
    show LocalRelocateResult;
import 'package:molia/services/download/download_manager.dart';
import 'package:molia/services/download/download_queue.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/utils/download_failure_label.dart';

/// 下载意图：四种结果分支 + 共享失败反馈映射。
void main() {
  late DownloadRecords records;
  late _FakeDownloadManager downloads;
  late DownloadLauncher launcher;

  Track makeTrack({String sourceKey = 'kw', String songId = '1'}) => Track(
    id: TrackId(sourceKey, songId),
    title: '测试歌曲',
    origin: TrackOrigin.builtin,
    qualities: const [
      AudioQuality(type: '128k'),
      AudioQuality(type: '320k'),
    ],
  );

  setUp(() {
    records = DownloadRecords(initialized: true, supported: true);
    downloads = _FakeDownloadManager();
    launcher = DownloadLauncher(downloads: downloads, records: records);
  });

  tearDown(() {
    launcher.dispose();
    downloads.dispose();
    records.dispose();
  });

  test('start：按默认音质入队，返回 started(task)', () async {
    final track = makeTrack();

    final result = await launcher.start(track);

    expect(result, isA<DownloadStarted>());
    final started = result as DownloadStarted;
    expect(started.task.track.id, track.id);
    expect(started.task.quality, '320k');
    expect(downloads.starts.single.quality, '320k');
  });

  test('start：显式音质优先于默认音质', () async {
    await launcher.start(makeTrack(), quality: '128k');

    expect(downloads.starts.single.quality, '128k');
  });

  test('start：已有音频记录返回 alreadyDownloaded，不再入队', () async {
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

    final result = await launcher.start(makeTrack());

    expect(result, isA<DownloadAlreadyDownloaded>());
    expect(
      (result as DownloadAlreadyDownloaded).record.key,
      'kw:1',
      reason: '结果带回记录，分享入口可直接复用',
    );
    expect(downloads.starts, isEmpty);
  });

  test('start：已有活动任务返回 active(task)，不重复入队', () async {
    final track = makeTrack();
    final task = DownloadTask(
      track: track,
      kind: DownloadTaskKind.audio,
      quality: '320k',
    );
    downloads.activeTask = task;

    final result = await launcher.start(track);

    expect(result, isA<DownloadAlreadyActive>());
    expect((result as DownloadAlreadyActive).task, same(task));
    expect(downloads.starts, isEmpty);
  });

  test('start：平台不支持 / 本地曲目返回 unsupported(reason)', () async {
    downloads.supported = false;
    final platform = await launcher.start(makeTrack());
    expect(platform, isA<DownloadUnsupported>());
    expect(
      (platform as DownloadUnsupported).reason.l10nKey,
      'downloadUnsupported',
    );
    expect(launcher.statusOf(makeTrack()), DownloadIntentStatus.unsupported);

    downloads.supported = true;
    const local = Track(
      id: TrackId(kLocalSourceKey, '/downloads/a.mp3'),
      title: '本地',
      origin: TrackOrigin.localFile,
    );
    final localResult = await launcher.start(local);
    expect(localResult, isA<DownloadUnsupported>());
    expect(
      (localResult as DownloadUnsupported).reason.l10nKey,
      'downloadLocalTrack',
    );
    expect(downloads.starts, isEmpty);
  });

  test('startBatch：候选过滤交由下载服务，结果带实际入队数', () async {
    var notified = -1;
    final result = await launcher.startBatch([
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

/// 意图测试只关心「入队参数 / 已有任务 / 批量计数」：其他命令面留空实现。
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

  /// 记录每次入队（含意图层替调用方选的音质）。
  final List<({Track track, String? quality})> starts = [];

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
    return DownloadTask(
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
  Future<void> downloadLyrics(Track track) async {}

  @override
  Future<void> downloadCover(Track track) async {}

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
  String defaultQualityFor(Track track) => '320k';

  @override
  Future<Uri?> localUriFor(Track track, {String? quality}) async => null;

  @override
  void dispose() {
    _taskChanges.dispose();
    super.dispose();
  }
}
