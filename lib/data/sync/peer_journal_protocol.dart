/// 对端增量日志的纯协议规则：窗口选择、游标消费、WebDAV 分块衔接与文件命名。
///
/// 为什么单独成模块：同一套规则原先在引擎（服务端应答 / 接收端消费）、两个
/// 传输与测试网络里各写一遍；只要有一处口径漂移（空窗口是否算截断、游标 -1
/// 是否算落后），对端就会白做一次 bootstrap 或永久跳过条目。这里只表达协议
/// 事实，不碰网络、UI 与持久化，边界条件可以被逐条钉住。
library;

import '../../domain/models/device_sync.dart';

/// 服务端应答形态：增量窗口，或用于重新引导的全量快照。
enum JournalServeMode { delta, fullSnapshot }

/// 按请求游标决定服务端回增量还是全量。
///
/// - `since < baseSeq`：游标之前的条目已被裁剪，窗口不完整 → 全量；
/// - `since > headSeq`：对端游标超前本机头部 = 本机日志被重置 → 全量。
///   继续给增量会让对端等一个永远不会出现的 seq，必须重新引导；
/// - 其余（含 `since == headSeq` 的空增量）→ 增量。
///
/// 全新对端（游标 -1）在 `baseSeq >= 0` 时因此走全量：它没有任何本地游标
/// 可依赖，全量快照才是权威起点。
JournalServeMode chooseJournalServeMode({
  required int since,
  required int baseSeq,
  required int headSeq,
}) {
  if (since < baseSeq || since > headSeq) {
    return JournalServeMode.fullSnapshot;
  }
  return JournalServeMode.delta;
}

/// 一次增量窗口的消费结果。
class JournalDeltaConsumption {
  const JournalDeltaConsumption({
    required this.accepted,
    required this.nextCursor,
    required this.gap,
    required this.truncated,
  });

  /// 按 seq 连续覆盖游标之后、可以应用的条目（空洞之后的条目不在此列）。
  final List<SyncJournalEntry> accepted;

  /// 消费后的游标：只推进到**连续接受**的最大 seq；窗口缺口时不动。
  final int nextCursor;

  /// 是否需要全量 bootstrap：游标落后窗口起点、窗口内空洞或窗口被截断。
  final bool gap;

  /// 声明的 `windowEnd` 大于实际连续覆盖到的位置（载荷被裁 / 坏条目被丢）。
  final bool truncated;
}

/// 增量窗口的线上边界：空窗口编码为 `0 / 0`（接收端据此判定「不算截断」），
/// 非空窗口取条目首尾 seq（调用方保证条目按 seq 升序）。
({int windowStart, int windowEnd}) journalWindowBounds(
  List<SyncJournalEntry> entries,
) =>
    entries.isEmpty
        ? (windowStart: 0, windowEnd: 0)
        : (windowStart: entries.first.seq, windowEnd: entries.last.seq);

/// 消费一份增量窗口，返回可应用条目、下一个游标与缺口标记（不写任何状态）。
///
/// 规则与线上协议逐条对应：
/// - 游标 -1 夹到 0：日志 seq 从 1 开始，`-1 < baseSeq(0)` 不是「落后」而是
///   「正好从头开始」，按落后处理会白做一次全量 bootstrap；
/// - `baseline < baseSeq`：窗口缺口，整窗都不应用（本机缺的条目已被裁剪）；
/// - 只接受从 `baseline + 1` 起**连续**的条目：解析层丢掉的坏条目 / 未知
///   类别会造成空洞，此时不能把游标推到 windowEnd（会永久跳过它们）；
/// - `windowEnd == 0` 是空窗口（回执类载荷），不算截断——否则全新对端会被
///   推进一次多余的 bootstrap，而快照可能早于本次变更，白丢一窗；
/// - `seq <= cursor` 的条目忽略：窗口可能从游标之前开始（WebDAV 分块覆盖）。
JournalDeltaConsumption consumeJournalDelta({
  required int cursor,
  required int baseSeq,
  required int windowEnd,
  required Iterable<SyncJournalEntry> entries,
}) {
  final baseline = cursor < 0 ? 0 : cursor;
  if (baseline < baseSeq) {
    return JournalDeltaConsumption(
      accepted: const [],
      nextCursor: cursor,
      gap: true,
      truncated: false,
    );
  }

  final ordered = [...entries]..sort((a, b) => a.seq.compareTo(b.seq));
  final accepted = <SyncJournalEntry>[];
  // 起点同样夹到 1：游标 -1（全新对端 / 刚被重置）时首条合法 seq 是 1，
  // 从 0 起算会把每条窗口都判成「首条即空洞」。
  var expected = baseline + 1;
  var hole = false;
  for (final entry in ordered) {
    if (entry.seq <= cursor) continue;
    if (entry.seq != expected) {
      hole = true;
      break;
    }
    expected = entry.seq + 1;
    accepted.add(entry);
  }

  final truncated =
      windowEnd > 0 && expected - 1 < windowEnd && windowEnd > cursor;
  final nextCursor = expected - 1 > cursor ? expected - 1 : cursor;
  return JournalDeltaConsumption(
    accepted: List.unmodifiable(accepted),
    nextCursor: nextCursor,
    gap: hole || truncated,
    truncated: truncated,
  );
}

/// 有序的 seq 闭区间（WebDAV 增量块的名字自带区间）。
class JournalSeqRange {
  const JournalSeqRange({required this.startSeq, required this.endSeq});

  final int startSeq;
  final int endSeq;

  @override
  bool operator ==(Object other) =>
      other is JournalSeqRange &&
      other.startSeq == startSeq &&
      other.endSeq == endSeq;

  @override
  int get hashCode => Object.hash(startSeq, endSeq);

  @override
  String toString() => '$startSeq-$endSeq';
}

/// 选择游标之后需要的块，并判断它们能否接上游标。
///
/// [needed] 按 seq 升序（输入顺序不敏感）；[contiguous] 为 false 时调用方
/// 必须改走全量快照。空的 `needed` 不算连续：头部已知且游标落后时没有块
/// 可读，说明窗口已不可用。
({List<T> needed, bool contiguous})
    selectJournalChunks<T extends JournalSeqRange>({
  required int cursor,
  required Iterable<T> chunks,
}) {
  final ordered = [...chunks]..sort((a, b) => a.startSeq.compareTo(b.startSeq));
  final needed = [
    for (final chunk in ordered)
      if (chunk.endSeq > cursor) chunk,
  ];
  // 首个块可以落在游标之前（覆盖的旧条目由消费侧按 seq 忽略），也可以正好
  // 是日志的第一个 seq（1）：游标 -1 / 0 的全新对端从 1 开始，不能要求
  // 首块必须等于 cursor + 1（0 不是合法 seq）。
  final expectedFirst = cursor + 1 < 1 ? 1 : cursor + 1;
  var contiguous = needed.isNotEmpty && needed.first.startSeq <= expectedFirst;
  for (var i = 1; contiguous && i < needed.length; i++) {
    if (needed[i].startSeq > needed[i - 1].endSeq + 1) contiguous = false;
  }
  return (needed: needed, contiguous: contiguous);
}

/// 对端是否没有本机还没消费的条目（`cursor >= head`）。
///
/// [headSeq] 为 null = 对端没有自报头部（旧版探测 / 尚未知）：局域网按
/// 「指纹未变」处理；需要「头部已知」前提的调用方（WebDAV 的回执游标 -1）
/// 先自行判空。
bool isPeerUpToDate({required int cursor, required int? headSeq}) =>
    headSeq == null || cursor >= headSeq;

/// 本协议文件名种类。
enum PeerJournalFileKind { acks, chunk, snapshot }

/// 解析后的协议文件名。
class PeerJournalFileName {
  const PeerJournalFileName({
    required this.deviceId,
    required this.kind,
    this.range,
    this.coverage = 0,
  });

  final String deviceId;
  final PeerJournalFileKind kind;

  /// 增量块的 seq 区间；其它种类为 null。
  final JournalSeqRange? range;

  /// 全量快照的覆盖位置；其它种类为 0。
  final int coverage;
}

/// WebDAV 远端文件命名（协议的一部分：文件名自带设备与 seq 区间）。
///
/// 命名规则集中在这里：块名同时是「窗口区间」的唯一来源，解析与生成分开
/// 实现很容易一边改了另一边忘掉。`.p2` 是硬断代后的命名空间：旧文件名不
/// 识别、不清理（按幽灵文件忽略），因此不存在「误删上一代文件」的路径。
abstract final class PeerJournalNames {
  /// 断代命名空间标记：所有协议文件名都必须带它。
  static const String namespace = '.p2';

  /// 回执文件后缀（固定名，可变）：`<deviceId>.p2.acks.msync`。
  static const String acksSuffix = '$namespace.acks.msync';

  /// 增量块后缀（不可变）：`<deviceId>.p2.<start>-<end>.chunk.msync`。
  static const String chunkSuffix = '.chunk.msync';

  /// 全量快照后缀（不可变）：`<deviceId>.p2.<coverage>.snapshot.msync`。
  static const String snapshotSuffix = '.snapshot.msync';

  /// 命名空间 + 数据段的分隔标记（`<deviceId>.p2.`）。
  static const String _marker = '$namespace.';

  static String acks(String deviceId) => '$deviceId$acksSuffix';

  static String chunk(String deviceId, JournalSeqRange range) =>
      '$deviceId$namespace.${range.startSeq}-${range.endSeq}$chunkSuffix';

  static String snapshot(String deviceId, int coverage) =>
      '$deviceId$namespace.$coverage$snapshotSuffix';

  /// 解析本协议文件名；其它命名（旧命名空间 / 残留）返回 null。
  ///
  /// 设备 id 是本协议自产的 32 位小写十六进制（不含 `.`），按命名空间标记
  /// 分段解析即可。旧文件名在这里统一变成幽灵文件：既不进列表也不被删除。
  static PeerJournalFileName? parse(String name) {
    String strip(String suffix) =>
        name.substring(0, name.length - suffix.length);
    if (name.endsWith(acksSuffix)) {
      final device = strip(acksSuffix);
      if (device.isNotEmpty && !device.contains('.')) {
        return PeerJournalFileName(
          deviceId: device,
          kind: PeerJournalFileKind.acks,
        );
      }
    } else if (name.endsWith(chunkSuffix)) {
      final split = _splitNamespace(strip(chunkSuffix));
      if (split != null) {
        final pieces = split.rest.split('-');
        if (pieces.length == 2) {
          final start = int.tryParse(pieces[0]);
          final end = int.tryParse(pieces[1]);
          if (start != null && end != null && end >= start) {
            return PeerJournalFileName(
              deviceId: split.deviceId,
              kind: PeerJournalFileKind.chunk,
              range: JournalSeqRange(startSeq: start, endSeq: end),
            );
          }
        }
      }
    } else if (name.endsWith(snapshotSuffix)) {
      final split = _splitNamespace(strip(snapshotSuffix));
      if (split != null) {
        final coverage = int.tryParse(split.rest);
        if (coverage != null) {
          return PeerJournalFileName(
            deviceId: split.deviceId,
            kind: PeerJournalFileKind.snapshot,
            coverage: coverage,
          );
        }
      }
    }
    return null;
  }

  /// 把 `<deviceId>.p2.<rest>` 拆成设备 id 与数据段；命名空间缺失 / 设备 id
  /// 非法时返回 null（旧命名与嵌套 `.p2` 都不会被当成协议文件）。
  static ({String deviceId, String rest})? _splitNamespace(String stem) {
    final index = stem.indexOf(_marker);
    if (index <= 0) return null;
    final device = stem.substring(0, index);
    if (device.contains('.')) return null;
    final rest = stem.substring(index + _marker.length);
    if (rest.isEmpty) return null;
    return (deviceId: device, rest: rest);
  }
}
