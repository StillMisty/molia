/// 类型化拉取计划：引擎给意图，传输给证据，动作判定只有这一份实现。
///
/// 为什么单独成模块：过去「这个对端要不要拉 / 跳过 / 全量」在引擎、局域网
/// 与 WebDAV 各自推导——引擎算游标与 anti-entropy 名单，局域网再按
/// presence 的 snapshotId 判「本轮新鲜」，WebDAV 又按 etag / 上次头部判一遍。
/// 三处规则一旦漂移，最典型的后果是「拿上一轮的旧指纹跳过 GET」，把对端
/// 新写入永久漏掉。这里只表达纯决策：不碰 socket / HTTP / 持久化。
///
/// 计划的数据形状（意图 / 发现策略）在 `domain/models/sync_pull_plan.dart`：
/// 它是传输端口契约的一部分；本模块只放判定实现，并重新导出便于调用方
/// 一次 import。
library;

import '../../domain/models/sync_pull_plan.dart';
import 'peer_journal_protocol.dart';

export '../../domain/models/sync_pull_plan.dart';

/// 拉取动作（逐对端）。
enum SyncPullAction {
  /// 已有本轮新鲜证据证明远端内容与本机游标一致：不取载荷。
  skip,

  /// 取游标之后的增量窗口（对端按自己的日志窗口决定是否回全量）。
  delta,

  /// 显式取全量快照（anti-entropy / 窗口缺口 / 引擎要求）。
  full,
}

/// 传输本轮观测到的对端证据。
///
/// 两种传输的证据形态不同，但判定所需的事实相同：
/// - 局域网：`token` = presence 的 snapshotId，`fresh` = presence 来自本轮
///   探测窗口，`journalHead` = presence 自报的头部；
/// - WebDAV：`token` = 回执文件的 etag / lastmodified，`fresh` = 本轮
///   PROPFIND 拿到了版本令牌，`journalHead` = 回执里的头部（未读到过则为
///   null）。
///
/// [headTrusted] 是「头部能不能用来判跳过」的唯一入口：局域网只有**本轮**
/// 听到的 presence 才可信（上一轮 presence 在 ack 丢失时会停在旧 head）；
/// WebDAV 的头部来自刚读到的回执，或来自「etag 未变」所证明未变的旧回执。
class SyncPeerPullEvidence {
  const SyncPeerPullEvidence({
    this.token = '',
    this.cachedToken,
    this.fresh = false,
    this.journalHead,
    this.headTrusted = false,
  });

  /// 本轮观测到的内容指纹（snapshotId / etag）；'' = 没有可用令牌。
  final String token;

  /// 上次成功拉取时记下的指纹（传输进程内缓存）。
  final String? cachedToken;

  /// 令牌是否来自**本轮**观测（上一轮缓存不能作为跳过依据）。
  final bool fresh;

  /// 对端 journal 头部；null = 未知。
  final int? journalHead;

  /// 头部是否可作为「已到对端头部」的依据。
  final bool headTrusted;
}

/// 逐对端拉取决策（纯数据，传输据此取载荷）。
class SyncPullDecision {
  const SyncPullDecision({
    required this.action,
    required this.cursor,
    required this.upToDate,
    required this.sameEvidence,
  });

  final SyncPullAction action;

  /// 取增量时使用的游标（= 计划里的游标）。
  final int cursor;

  /// 头部已知且本机游标已到头部。
  final bool upToDate;

  /// 本轮新鲜指纹与上次成功拉取的指纹一致。
  final bool sameEvidence;

  bool get shouldFetch => action != SyncPullAction.skip;

  @override
  String toString() =>
      'SyncPullDecision($action, cursor: $cursor, upToDate: $upToDate, '
      'sameEvidence: $sameEvidence)';
}

/// 唯一的拉取动作判定。
///
/// 规则：
/// 1. 计划要求全量 → 全量（权威视图优先，证据再新鲜也不能跳过）；
/// 2. 头部可信、本机游标已到头部、且（没有令牌或本轮令牌与上次一致）
///    → 跳过。**只有新鲜证据能跳过**：`headTrusted` 由传输按自己的证据
///    来源设置，局域网不会把上一轮 presence 的旧头部标成可信；
/// 3. 其余 → 增量（对端日志窗口不完整时由服务端 / 分块选择改走全量，
///    这是协议规则，不在这里重复）。
SyncPullDecision decideSyncPull({
  required SyncPeerPullIntent intent,
  required SyncPeerPullEvidence evidence,
}) {
  if (intent.forceFull) {
    return SyncPullDecision(
      action: SyncPullAction.full,
      cursor: intent.cursor,
      upToDate: false,
      sameEvidence: false,
    );
  }
  final upToDate = evidence.headTrusted &&
      isPeerUpToDate(cursor: intent.cursor, headSeq: evidence.journalHead);
  final hasToken = evidence.token.isNotEmpty;
  final sameEvidence =
      hasToken && evidence.fresh && evidence.cachedToken == evidence.token;
  if (upToDate && (!hasToken || sameEvidence)) {
    return SyncPullDecision(
      action: SyncPullAction.skip,
      cursor: intent.cursor,
      upToDate: true,
      sameEvidence: sameEvidence,
    );
  }
  return SyncPullDecision(
    action: SyncPullAction.delta,
    cursor: intent.cursor,
    upToDate: upToDate,
    sameEvidence: sameEvidence,
  );
}
