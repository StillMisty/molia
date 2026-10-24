/// 同步观测日志：展示日志、近 24 小时活动、传输成功时间与快照发布位置。
///
/// 为什么单独一层：这些字段都是「一轮结束后写给观测面看」的流水，按同一组
/// 上限追加 / 截断，换口令时也只清传输成功时间、不动历史日志。收进这里后，
/// `SyncStateStore` 不再同时维护四份容器的追加 / 裁剪规则；落盘形状仍由
/// `sync_state_codec.dart` 定义，本模块只产出 / 接受不可变切片。
library;

import '../../domain/models/device_sync.dart';
import 'sync_activity.dart';
import 'sync_state_codec.dart';

/// 观测日志类字段的持久化切片（对应 `SyncPersistedState` 的同名字段）。
///
/// 构造时复制集合：调用方可以把切片交给异步编码，之后的新轮次不会改到
/// 正在落盘的内容。
class SyncActivityLogSnapshot {
  SyncActivityLogSnapshot({
    this.lastSyncAt = 0,
    Map<String, int> transportLastSuccess = const {},
    Map<String, int> snapshotPushSeq = const {},
    List<SyncLogEntry> log = const [],
    List<SyncActivityEntry> activity = const [],
  })  : transportLastSuccess = Map.unmodifiable(transportLastSuccess),
        snapshotPushSeq = Map.unmodifiable(snapshotPushSeq),
        log = List.unmodifiable(log),
        activity = List.unmodifiable(activity);

  /// 最近一轮完成时间（0 = 尚未同步过）。
  final int lastSyncAt;

  /// 每传输最近一次成功接触对端的轮次时间（0 = 尚未成功过）。
  final Map<String, int> transportLastSuccess;

  /// 各传输最近成功发布的全量快照覆盖位置（kind → seq；-1 = 尚未发布）。
  final Map<String, int> snapshotPushSeq;

  /// 展示日志（新在前；上限由构造参数给定）。
  final List<SyncLogEntry> log;

  /// 近 24 小时活动记录（新在前；上限由构造参数给定）。
  final List<SyncActivityEntry> activity;
}

/// 同步轮次流水（内存状态；不做持久化）。
class SyncActivityLog {
  SyncActivityLog({
    required void Function() onChanged,
    int logLimit = SyncStateCodec.logLimit,
    int activityLimit = SyncStateCodec.activityLimit,
  })  : _onChanged = onChanged,
        _logLimit = logLimit,
        _activityLimit = activityLimit;

  /// 有内存变更（由状态存储标脏；轮内不改磁盘）。
  final void Function() _onChanged;

  /// 展示日志保留条数（设置页只展示最近几条）。
  final int _logLimit;

  /// 活动记录保留条数（近 24 小时汇总用；展示日志不足以支撑窗口）。
  final int _activityLimit;

  int _lastSyncAt = 0;
  final List<SyncLogEntry> _log = [];

  /// 近 24 小时活动记录（新在前；展示日志之外单独保留，供观测面汇总）。
  final List<SyncActivityEntry> _activity = [];

  /// 每传输最近一次成功接触对端的轮次时间（UI「最后成功于」；0 = 尚未成功过）。
  final Map<String, int> _transportLastSuccess = {};

  /// 各传输最近成功发布的全量快照覆盖位置（kind → seq；-1 = 尚未发布）。
  ///
  /// 日志裁剪不会越过**已发布**的快照覆盖：落后 / 新加入的对端要能 bootstrap。
  /// 读写都只经发布台账（`publish_ledger.dart`，判据唯一处）。
  final Map<String, int> _snapshotPushSeq = {};

  int get lastSyncAt => _lastSyncAt;

  List<SyncLogEntry> get log => List.unmodifiable(_log);

  /// 近 24 小时活动记录（新在前；上限 [_activityLimit]）。
  List<SyncActivityEntry> get activity => List.unmodifiable(_activity);

  /// 传输最近一次成功接触对端的时间（0 = 尚未成功过）。
  int transportLastSuccessAt(String kind) => _transportLastSuccess[kind] ?? 0;

  /// 传输最近成功发布的全量快照覆盖位置（-1 = 尚未发布）。
  ///
  /// 判据（谁在什么条件下读它、失败时是否前移）在发布台账里；这里只是
  /// `sync_state_v2` 的键值与形状。
  int snapshotPushSeq(String kind) => _snapshotPushSeq[kind] ?? -1;

  /// 只改内存 + 标脏：发布台账在推送循环里逐载荷记账，由轮末提交统一落盘
  /// （旧实现每次 mark 都写一次整份状态 JSON，多传输 / 多载荷时写放大）。
  void setSnapshotPushSeq(String kind, int seq) {
    if (_snapshotPushSeq[kind] == seq) return;
    _snapshotPushSeq[kind] = seq;
    _onChanged();
  }

  /// 记录一轮同步结果：展示日志 + 活动记录 + 传输成功时间。
  ///
  /// 落盘由存储层在轮末提交一次；这里只维护内存与保留上限。
  void recordRound(SyncRoundReport report) {
    _onChanged();
    _lastSyncAt = report.finishedAt;
    _log.insert(
      0,
      SyncLogEntry(
        at: report.finishedAt,
        trigger: report.trigger,
        outcome: report.outcome,
        durationMs: report.durationMs,
        applied: report.applied,
        peersSeen: report.peersSeen,
        failed: report.failedCount,
        bytesIn: report.bytesIn,
        bytesOut: report.bytesOut,
        // 本轮启用的传输（未启用的传输不参与本轮）。
        transports: report.transports
            .where((t) => t.enabled)
            .map((t) => t.kind)
            .toList(),
        error: report.error,
      ),
    );
    while (_log.length > _logLimit) {
      _log.removeLast();
    }
    // 活动记录：观测面的「近 24 小时」不受展示保留量截断。
    _activity.insert(
      0,
      SyncActivityEntry(
        at: report.finishedAt,
        bytesIn: report.bytesIn,
        bytesOut: report.bytesOut,
        applied: report.applied,
      ),
    );
    while (_activity.length > _activityLimit) {
      _activity.removeLast();
    }
    for (final transport in report.transports) {
      if (transport.enabled && transport.succeeded) {
        _transportLastSuccess[transport.kind] = report.finishedAt;
      }
    }
  }

  /// 清空本机对**旧同步组**的传输成功时间（换口令时调用）。
  ///
  /// 只清「哪些传输真正接触过旧组」的观测；历史日志 / 活动记录是用户可见
  /// 的审计流水，不随换口令抹掉（与旧行为一致）。
  void resetGroupObservations() {
    _transportLastSuccess.clear();
    _onChanged();
  }

  /// 当前内存状态的持久化切片（不可变；字段由 `sync_state_codec.dart` 编码）。
  SyncActivityLogSnapshot snapshot() => SyncActivityLogSnapshot(
        lastSyncAt: _lastSyncAt,
        transportLastSuccess: _transportLastSuccess,
        snapshotPushSeq: _snapshotPushSeq,
        log: _log,
        activity: _activity,
      );

  /// 把解码出的切片写回内存（整体替换：状态 JSON 是完整视图，不是增量）。
  void applySnapshot(SyncActivityLogSnapshot snapshot) {
    _lastSyncAt = snapshot.lastSyncAt;
    _transportLastSuccess
      ..clear()
      ..addAll(snapshot.transportLastSuccess);
    _snapshotPushSeq
      ..clear()
      ..addAll(snapshot.snapshotPushSeq);
    _log
      ..clear()
      ..addAll(snapshot.log);
    _activity
      ..clear()
      ..addAll(snapshot.activity);
  }
}
