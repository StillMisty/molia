/// 发布台账：每传输一份，回答「这轮能不能跳过加密 / 上传？journal 能裁到哪？」
///
/// 判据聚合三处事实——**内存指纹**（本进程最近一次成功外发的载荷身份）、
/// **持久覆盖**（`sync_state_v2` 的 `snapshotPushSeq`）与**能力位**
/// （[SyncTransport.servesLiveSnapshot]）——只有这一处回答：
/// push 循环问 [PublishLedger.plan] / 记 [PublishLedger.mark]，日志裁剪的
/// 覆盖下限走 [journalCoverage]。引擎只保留轮次编排（拉取 / 合并 / 报告 /
/// 错误归类）。
///
/// 边界：本模块是 data 层内部实现（`SyncEngine` 与测试所用），不是对外端口；
/// 持久化复用 `sync_state_v2` 的 `snapshotPushSeq`，不另起存储或键族。
library;

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_transport.dart';
import 'sync_book.dart';

/// 每传输发布台账（局域网 / WebDAV 各一份，由 `SyncEngine` 持有）。
///
/// - **内存指纹**：成功外发过同一份载荷就不再重复加密与上传——全量快照按
///   内容指纹（裁剪墓碑后的记录集规范化哈希）比对，增量窗口按「窗口边界 +
///   ack 集合」比对（窗口没变但 ack 推进也要外发一次，对端据此裁自己的日志）；
/// - **持久覆盖**：该传输成功发布过的全量快照覆盖到的 journal 位置。已发布
///   覆盖够到本轮构建位置时不必重发快照文件，重启后不回退；
/// - **能力位**：对端按需拉**实时**快照的传输（局域网）没有发布延迟，不约束
///   日志裁剪；文件型传输（WebDAV）的快照是异步读取的，覆盖必须够到窗口
///   起点，否则落后 / 新加入的对端无法 bootstrap。
class PublishLedger {
  /// [kind] 是传输标识（`sync_state_v2` 的 `snapshotPushSeq` 键）；
  /// [servesLiveSnapshot] 是能力位读取（构造时传
  /// `() => transport.servesLiveSnapshot`）——判定时即时读取，测试替身可在
  /// 引擎建好后假替；[state] 提供持久覆盖的读写。
  PublishLedger({
    required this.kind,
    required SyncPublicationState state,
    required bool Function() servesLiveSnapshot,
  })  : _state = state,
        _servesLiveSnapshot = servesLiveSnapshot;

  /// 传输标识（`sync_state_v2` 的 `snapshotPushSeq` 键）。
  final String kind;

  final SyncPublicationState _state;
  final bool Function() _servesLiveSnapshot;

  /// 最近一次**成功**外发的全量快照内容指纹；null = 尚未推过 / 上次外发失败。
  String? _pushedSnapshotId;

  /// 最近一次**成功**外发的增量窗口身份；null = 尚未推过 / 上次外发失败。
  String? _pushedDeltaKey;

  /// [plan] 与 [mark] 的配对凭据：本轮已计划外发的载荷（null = 计划跳过）。
  _PlannedPayload? _planned;

  /// 决定这份载荷本轮是否需要外发；false = 门控跳过加密与上传。
  ///
  /// 返回 true 时必须配对调用 [mark]（成功与失败都记）；返回 false 时台账不
  /// 记账，下一轮重新判定。判据按载荷形态：
  /// - **全量快照**：内容指纹已推过 → 跳过；[snapshotSeq] 非空（注入了增量
  ///   日志）时还要求它超出该传输已发布的覆盖；
  /// - **增量窗口**：窗口边界 + ack 集合与上次成功外发的一致 → 跳过。
  ///
  /// [snapshotSeq] 是本机日志最近构建的全量快照覆盖位置；null = 未注入日志
  /// （没有覆盖可依，每轮都外发全量）。
  bool plan(SyncEnvelope outgoing, {int? snapshotSeq}) {
    final _PlannedPayload? planned;
    if (outgoing.isDelta) {
      final key = _deltaKey(outgoing);
      planned = key == _pushedDeltaKey
          ? null
          : _PlannedPayload(key: key, isSnapshot: false);
    } else if (_needsSnapshot(outgoing, snapshotSeq)) {
      planned = _PlannedPayload(
        key: outgoing.snapshotId,
        isSnapshot: true,
        snapshotSeq: snapshotSeq,
      );
    } else {
      planned = null;
    }
    _planned = planned;
    return planned != null;
  }

  /// 全量快照是否要外发。
  ///
  /// 内容指纹为空（理论上不会出现）时无法比对，保守外发。
  bool _needsSnapshot(SyncEnvelope outgoing, int? snapshotSeq) {
    // 已发布覆盖够到本轮构建的快照：对端拿到的那份已经够新（落后 / 新加入的
    // 对端读它就能 bootstrap），不必重写文件。
    if (snapshotSeq != null && _state.snapshotPushSeq(kind) >= snapshotSeq) {
      return false;
    }
    // 同一份内容在本进程成功推给过对端：跳过加密 + 上传（对端仍可主动拉取）。
    return !(outgoing.snapshotId.isNotEmpty &&
        _pushedSnapshotId == outgoing.snapshotId);
  }

  /// 记录一次外发结果（[plan] 返回 true 后配对调用）。
  ///
  /// 只在「确实有对端收下且没有失败」时记账：零对端（局域网无人在线）不算
  /// 推送成功，否则对端上线后会被误判为「已推过」；失败 / 零对端显式遗忘，
  /// 下一轮重试。全量快照成功时把持久覆盖推进到本轮构建位置（失败不前移）。
  ///
  /// 覆盖位置只写内存 + 标脏，由引擎在轮末提交一次：推送循环里每个传输 /
  /// 每份载荷都会调用这里，逐次落盘会把整份 `sync_state_v2` 写多遍。
  Future<void> mark(SyncPushResult result) async {
    final planned = _planned;
    _planned = null;
    if (planned == null) return;
    final delivered = result.failedPeers == 0 && result.succeededPeers > 0;
    if (!planned.isSnapshot) {
      _pushedDeltaKey = delivered ? planned.key : null;
      return;
    }
    _pushedSnapshotId = delivered ? planned.key : null;
    final seq = planned.snapshotSeq;
    if (delivered && seq != null) {
      _state.setSnapshotPushSeq(kind, seq);
    }
  }

  /// 该传输对日志裁剪下限的约束（已发布的全量快照覆盖位置）。
  ///
  /// null = 不约束：传输按需给出实时快照（[SyncTransport.servesLiveSnapshot]
  /// 为真，如局域网），对端随时能拿到当前视图，没有发布延迟。文件型传输
  /// 必须覆盖到窗口起点，否则落后 / 新加入的对端无法 bootstrap；从未发布过
  /// 返回 0（不能裁到任何位置）。
  int? get publishedCoverage {
    if (_servesLiveSnapshot()) return null;
    final published = _state.snapshotPushSeq(kind);
    return published < 0 ? 0 : published;
  }

  /// 增量窗口的身份：窗口边界 + ack 集合（键序规范化，与 map 插入顺序无关）。
  static String _deltaKey(SyncEnvelope envelope) =>
      '${envelope.windowStart}:${envelope.windowEnd}:'
      '${_acksKey(envelope.acks)}';

  static String _acksKey(Map<String, int> acks) {
    final entries = acks.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((entry) => '${entry.key}=${entry.value}').join(',');
  }
}

/// 日志裁剪的覆盖下限（`SyncJournalStore.compact` 的 `coverage` 参数）。
///
/// 只统计**启用**的传输里需要发布快照文件的那些（[PublishLedger.publishedCoverage]
/// 非 null），取它们已发布覆盖的最小值；没有任何约束时返回 [journalHead]
/// （按需给出实时快照的传输不参与）。
int journalCoverage({
  required Iterable<PublishLedger> ledgers,
  required Set<String> enabledKinds,
  required int journalHead,
}) {
  var coverage = journalHead;
  for (final ledger in ledgers) {
    if (!enabledKinds.contains(ledger.kind)) continue;
    final published = ledger.publishedCoverage;
    if (published != null && published < coverage) coverage = published;
  }
  return coverage;
}

/// [PublishLedger.plan] 与 [PublishLedger.mark] 之间的配对凭据。
class _PlannedPayload {
  const _PlannedPayload({
    required this.key,
    required this.isSnapshot,
    this.snapshotSeq,
  });

  /// 载荷身份：全量快照 = 内容指纹，增量窗口 = 窗口边界 + ack 集合。
  final String key;

  /// 全量快照（false = 增量窗口）。
  final bool isSnapshot;

  /// 快照的覆盖位置（成功时落持久覆盖；null = 未注入日志，不落）。
  final int? snapshotSeq;
}
