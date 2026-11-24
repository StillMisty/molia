import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/download/download_manager.dart';
import 'package:molia/services/download/download_queue.dart';

/// 下载管理面快照：任务分组只读且与入参解耦。
void main() {
  Track track(int id) => Track(
    id: TrackId('kw', '$id'),
    title: '曲目 $id',
    origin: TrackOrigin.builtin,
    payload: {'songmid': '$id'},
  );

  DownloadTask task(int id) => DownloadTask(
    track: track(id),
    kind: DownloadTaskKind.audio,
    quality: '320k',
  );

  test('DownloadManagerState 冻结三组任务，入参改写不影响快照', () {
    final running = [task(1)];
    final queued = [task(2)];
    final failed = [task(3)];
    addTearDown(() {
      for (final item in [...running, ...queued, ...failed]) {
        item.dispose();
      }
    });

    final state = DownloadManagerState(
      supported: true,
      publisherSupported: false,
      notificationsSupported: false,
      initialized: true,
      taskGroups: (running: running, queued: queued, failed: failed),
    );

    expect(() => state.taskGroups.running.add(task(4)), throwsUnsupportedError);
    expect(() => state.taskGroups.queued.add(task(4)), throwsUnsupportedError);
    expect(() => state.taskGroups.failed.add(task(4)), throwsUnsupportedError);

    running.clear();
    queued.clear();
    failed.clear();
    expect(state.taskGroups.running, hasLength(1));
    expect(state.taskGroups.queued, hasLength(1));
    expect(state.taskGroups.failed, hasLength(1));
  });
}
