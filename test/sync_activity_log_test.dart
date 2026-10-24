import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_activity_log.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 观测日志模块测试：日志 / 活动双上限、传输成功时间、发布位置与换口令清理。
void main() {
  SyncActivityLog activityLog({
    int logLimit = 20,
    int activityLimit = 240,
    void Function()? onChanged,
  }) =>
      SyncActivityLog(
        onChanged: onChanged ?? () {},
        logLimit: logLimit,
        activityLimit: activityLimit,
      );

  SyncRoundReport round({
    required int finishedAt,
    int applied = 0,
    List<SyncTransportReport> transports = const [],
  }) =>
      SyncRoundReport(
        trigger: SyncTrigger.timer,
        startedAt: finishedAt - 1,
        finishedAt: finishedAt,
        outcome: SyncOutcome.ok,
        applied: applied,
        transports: transports,
      );

  const lanOk = SyncTransportReport(
    kind: 'lan',
    running: true,
    enabled: true,
    peersSeen: 1,
  );

  test('每轮追加日志与活动记录：新在前，lastSyncAt 跟随轮次完成时间', () {
    final state = activityLog();
    state.recordRound(round(finishedAt: 10, applied: 1));
    state.recordRound(round(
      finishedAt: 20,
      applied: 2,
      transports: const [
        SyncTransportReport(kind: 'lan', running: true, bytesIn: 3),
      ],
    ));

    expect(state.lastSyncAt, 20);
    expect(state.log.map((entry) => entry.at), [20, 10]);
    expect(state.log.first.applied, 2);
    expect(state.log.first.bytesIn, 3);
    expect(state.activity.map((entry) => entry.at), [20, 10]);
    expect(state.activity.first.bytesIn, 3);
  });

  test('日志与活动各自按上限截断，活动窗口不受展示条数限制', () {
    final state = activityLog(logLimit: 3, activityLimit: 5);
    for (var i = 0; i < 7; i++) {
      state.recordRound(round(finishedAt: i, applied: i));
    }

    expect(state.log, hasLength(3));
    expect(state.log.map((entry) => entry.at), [6, 5, 4]);
    expect(state.activity, hasLength(5));
    expect(state.activity.map((entry) => entry.at), [6, 5, 4, 3, 2]);
  });

  test('传输成功时间：只有启用且成功接触过对端的轮次才更新', () {
    final state = activityLog();
    state.recordRound(round(
      finishedAt: 1,
      transports: const [
        lanOk,
        SyncTransportReport(kind: 'webdav', running: true), // 未启用
      ],
    ));
    expect(state.transportLastSuccessAt('lan'), 1);
    expect(state.transportLastSuccessAt('webdav'), 0);

    state.recordRound(round(
      finishedAt: 2,
      transports: const [
        SyncTransportReport(
          kind: 'lan',
          running: true,
          enabled: true,
          peersSeen: 1,
          failedPulls: 1,
        ),
      ],
    ));
    expect(state.transportLastSuccessAt('lan'), 1, reason: '失败尝试不算成功');
  });

  test('换口令只清传输成功时间：历史日志与活动记录保留', () {
    final state = activityLog();
    state.recordRound(round(finishedAt: 5, transports: const [lanOk]));

    state.resetGroupObservations();

    expect(state.transportLastSuccessAt('lan'), 0);
    expect(state.lastSyncAt, 5);
    expect(state.log, hasLength(1));
    expect(state.activity, hasLength(1));
  });

  test('快照发布位置：默认 -1，写入标脏，重复值不重复标脏', () {
    var changes = 0;
    final state = activityLog(onChanged: () => changes++);
    expect(state.snapshotPushSeq('lan'), -1);

    state.setSnapshotPushSeq('lan', 5);
    expect(state.snapshotPushSeq('lan'), 5);
    expect(changes, 1);

    state.setSnapshotPushSeq('lan', 5);
    expect(changes, 1, reason: '值未变不产生变更');

    state.setSnapshotPushSeq('lan', 7);
    expect(changes, 2);
  });

  test('快照往返：整体替换五类字段', () {
    final source = activityLog();
    source.recordRound(round(
      finishedAt: 5,
      applied: 1,
      transports: const [
        lanOk,
        SyncTransportReport(kind: 'webdav', running: true, bytesOut: 2),
      ],
    ));
    source.setSnapshotPushSeq('lan', 9);

    final target = activityLog()..applySnapshot(source.snapshot());

    expect(target.lastSyncAt, 5);
    expect(target.log.single.at, 5);
    expect(target.activity.single.bytesOut, 2);
    expect(target.transportLastSuccessAt('lan'), 5);
    expect(target.snapshotPushSeq('lan'), 9);

    target.applySnapshot(SyncActivityLogSnapshot());
    expect(target.lastSyncAt, 0);
    expect(target.log, isEmpty);
    expect(target.activity, isEmpty);
    expect(target.transportLastSuccessAt('lan'), 0);
    expect(target.snapshotPushSeq('lan'), -1);
  });
}
