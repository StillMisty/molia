import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/download/download_queue.dart';

/// 下载队列：单 worker FIFO、同 key 去重、取消 / 失败 / 重试与进度通道。
void main() {
  Track track(String id) => Track(
    id: TrackId('kw', id),
    title: '曲目 $id',
    origin: TrackOrigin.builtin,
    payload: {'songmid': id},
  );

  DownloadTask audio(String id) => DownloadTask(
    track: track(id),
    kind: DownloadTaskKind.audio,
    quality: '320k',
  );

  /// 让队列 worker 跑到下一次 await（入队 / 开始 / 收尾都靠它推进）。
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('单 worker FIFO：一次只跑一个，按入队顺序推进', () async {
    final gates = <String, Completer<void>>{};
    final started = <String>[];
    var active = 0;
    var maxActive = 0;
    final queue = DownloadQueue((task) async {
      started.add(task.key);
      active++;
      maxActive = active > maxActive ? active : maxActive;
      await gates[task.key]!.future;
      active--;
    });
    final tasks = [audio('1'), audio('2'), audio('3')];
    for (final task in tasks) {
      gates[task.key] = Completer<void>();
    }

    final futures = [for (final task in tasks) queue.enqueue(task)];
    // enqueue 同步可见（页面立即看到等待列表），worker 尚未开始。
    expect(queue.tasks.map((task) => task.key), [
      tasks[0].key,
      tasks[1].key,
      tasks[2].key,
    ]);
    await flush();
    expect(started, [tasks[0].key]);
    expect(tasks[0].status, DownloadTaskStatus.running);
    expect(tasks[1].status, DownloadTaskStatus.queued);

    gates[tasks[0].key]!.complete();
    await futures[0];
    await flush();
    expect(started, [tasks[0].key, tasks[1].key]);
    expect(maxActive, 1, reason: '严格串行');

    gates[tasks[1].key]!.complete();
    await futures[1];
    await flush();
    expect(started, [tasks[0].key, tasks[1].key, tasks[2].key]);
    gates[tasks[2].key]!.complete();
    await futures[2];
    await flush();

    expect(maxActive, 1);
    expect(queue.tasks, isEmpty, reason: '完成后从队列移除');
  });

  test('同 key 去重：排队 / 运行中返回同一 future，不重复入队', () async {
    final gate = Completer<void>();
    final queue = DownloadQueue((task) => gate.future);
    final first = audio('1');
    final second = audio('1');

    final f1 = queue.enqueue(first);
    final f2 = queue.enqueue(second);
    expect(identical(f1, f2), isTrue);
    expect(queue.tasks, hasLength(1));
    expect(identical(queue.taskFor(first.key), first), isTrue);

    await flush();
    gate.complete();
    await f1;
    await flush();
    expect(queue.tasks, isEmpty);
  });

  test('取消排队任务：立即移出队列，等待方收到 cancelled', () async {
    final gate = Completer<void>();
    final queue = DownloadQueue((task) => gate.future);
    final running = audio('1');
    final queued = audio('2');
    final f1 = queue.enqueue(running);
    final f2 = queue.enqueue(queued);
    await flush();

    expect(queue.cancelQueued(queued.key), isTrue);
    await expectLater(
      f2,
      throwsA(
        predicate((e) => e is SourceFailure && e.kind == FailureKind.cancelled),
      ),
    );
    expect(queued.status, DownloadTaskStatus.cancelled);
    expect(queue.tasks.map((task) => task.key), [running.key]);
    expect(queue.cancelQueued(running.key), isFalse, reason: '运行中不归队列取消');

    gate.complete();
    await f1;
    await flush();
    expect(queue.tasks, isEmpty);
  });

  test('运行中取消：runner 抛 cancelled 后任务移除', () async {
    final gate = Completer<void>();
    final queue = DownloadQueue((task) => gate.future);
    final task = audio('1');
    final future = queue.enqueue(task);
    await flush();
    expect(queue.cancelQueued(task.key), isFalse);

    gate.completeError(
      const SourceFailure(
        kind: FailureKind.cancelled,
        message: '下载已取消',
        l10nKey: 'downloadCancelled',
      ),
    );
    await expectLater(
      future,
      throwsA(
        predicate((e) => e is SourceFailure && e.kind == FailureKind.cancelled),
      ),
    );
    await flush();
    expect(task.status, DownloadTaskStatus.cancelled);
    expect(queue.tasks, isEmpty, reason: '取消后不留失败项');
  });

  test('音频失败：任务保留供重试；同一对象重新入队后成功', () async {
    final attempts = <Completer<void>>[];
    var failFirst = true;
    final queue = DownloadQueue((task) async {
      final gate = Completer<void>();
      attempts.add(gate);
      await gate.future;
      if (failFirst) {
        failFirst = false;
        throw const SourceFailure(
          kind: FailureKind.network,
          message: 'HTTP 500',
          l10nKey: 'downloadFailed',
        );
      }
    });
    final task = audio('1');
    final first = queue.enqueue(task);
    await flush();
    attempts.last.complete();
    await expectLater(first, throwsA(isA<SourceFailure>()));
    await flush();

    expect(task.status, DownloadTaskStatus.failed);
    expect(task.failure?.kind, FailureKind.network);
    expect(queue.tasks.single, same(task));

    final retried = queue.enqueue(task);
    expect(task.status, DownloadTaskStatus.queued);
    expect(task.failure, isNull);
    await flush();
    expect(task.status, DownloadTaskStatus.running);
    attempts.last.complete();
    await retried;
    await flush();
    expect(task.status, DownloadTaskStatus.completed);
    expect(queue.tasks, isEmpty);
  });

  test('失败后同 key 新任务替换旧任务', () async {
    final attempts = <Completer<void>>[];
    var failFirst = true;
    final queue = DownloadQueue((task) async {
      final gate = Completer<void>();
      attempts.add(gate);
      await gate.future;
      if (failFirst) {
        failFirst = false;
        throw const SourceFailure(
          kind: FailureKind.network,
          message: 'HTTP 500',
        );
      }
    });
    final oldTask = audio('1');
    final first = queue.enqueue(oldTask);
    await flush();
    attempts.last.complete();
    await expectLater(first, throwsA(isA<SourceFailure>()));
    await flush();
    expect(queue.tasks.single, same(oldTask));

    final newTask = audio('1');
    final retried = queue.enqueue(newTask);
    expect(queue.tasks.single, same(newTask));
    expect(queue.taskFor(newTask.key), same(newTask));
    await flush();
    attempts.last.complete();
    await retried;
    await flush();
    expect(queue.tasks, isEmpty);
    expect(oldTask.status, DownloadTaskStatus.failed);
  });

  test('失败任务：可逐条移除', () async {
    final attempts = <Completer<void>>[];
    final queue = DownloadQueue((task) async {
      final gate = Completer<void>();
      attempts.add(gate);
      await gate.future;
      throw const SourceFailure(kind: FailureKind.network, message: 'HTTP 500');
    });
    final one = audio('1');
    final two = audio('2');
    final f1 = queue.enqueue(one);
    final f2 = queue.enqueue(two);
    await flush();
    attempts.last.complete();
    await expectLater(f1, throwsA(isA<SourceFailure>()));
    await flush();
    attempts.last.complete();
    await expectLater(f2, throwsA(isA<SourceFailure>()));
    await flush();
    expect(queue.tasks, hasLength(2));

    queue.dismiss(one.key);
    expect(queue.tasks.map((task) => task.key), [two.key]);
  });

  test('进度只通知任务自身，队列不在进度时通知', () async {
    final gate = Completer<void>();
    final queue = DownloadQueue((task) => gate.future);
    final task = audio('1');
    var queueNotifications = 0;
    var taskNotifications = 0;
    queue.addListener(() => queueNotifications++);
    task.addListener(() => taskNotifications++);

    final future = queue.enqueue(task);
    await flush();
    final structural = queueNotifications;
    expect(task.status, DownloadTaskStatus.running);

    task.reportProgress(10, 100, nowMs: 1000);
    expect(task.progress.receivedBytes, 10);
    expect(taskNotifications, greaterThan(0));
    expect(queueNotifications, structural, reason: '进度不重建任务区');

    // 100ms 窗口内合并；100% 立即送达。
    final before = taskNotifications;
    task.reportProgress(20, 100, nowMs: 1040);
    expect(task.progress.receivedBytes, 10);
    expect(taskNotifications, before);
    task.reportProgress(100, 100, nowMs: 1050);
    expect(task.progress.receivedBytes, 100);
    expect(taskNotifications, before + 1);

    gate.complete();
    await future;
    await flush();
  });

  test('dispose 后恢复的 runner 不再通知队列', () async {
    final gate = Completer<void>();
    final queue = DownloadQueue((task) => gate.future);
    var notifications = 0;
    queue.addListener(() => notifications++);
    final task = audio('1');
    queue.enqueue(task);
    await flush();
    final before = notifications;

    queue.dispose();
    gate.complete();
    await flush();

    expect(notifications, before);
  });

  test('非 audio 任务失败自动移除（失败由调用方提示）', () async {
    final queue = DownloadQueue((task) async {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '未找到歌词',
        l10nKey: 'downloadNoLyrics',
      );
    });
    final task = DownloadTask(
      track: track('1'),
      kind: DownloadTaskKind.lyrics,
      quality: '',
    );
    final future = queue.enqueue(task);
    await expectLater(future, throwsA(isA<SourceFailure>()));
    await flush();

    expect(task.status, DownloadTaskStatus.failed);
    expect(queue.tasks, isEmpty);
    expect(queue.taskFor(task.key), isNull);
  });
}
