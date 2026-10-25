/// 增量日志仓库：本机变更按 `seq` 单调追加，窗口按对端 ack 与硬上限裁剪。
///
/// - **追加与数据写入同事务**：调用方把事务 executor 传进来（资料库 / 统计
///   在写行的同一个 drift 事务里追加；设置 / 脚本 / 会话在各自的变化检测点
///   追加），崩溃不会出现「数据落了、日志没落」；
/// - **窗口** = `seq > baseSeq` 的条目；[baseSeq] 与日志条目同事务更新，
///   跨重启与条目集合一致；
/// - **compact**：正常路径裁剪到 `min(minAck, snapshotSeq)`——既不裁掉任何
///   对端还没 ack 的条目，也不裁掉全量快照尚未覆盖的位置（保证落后 / 新加入
///   的对端总能从快照 bootstrap）；窗口超过硬上限（时间 / 体积 / 条数）时
///   先推进快照覆盖再整体裁剪，落后对端降级为 bootstrap。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../domain/models/device_sync.dart';
import '../molia_database.dart';

/// 增量日志的硬上限（ADR-0003 v2 §5：日志「按 min(对端 ack) 裁剪，并设硬
/// 上限（时间 + 体积）」）。
class SyncJournalLimits {
  const SyncJournalLimits({
    this.maxAge = const Duration(days: 30),
    this.maxBytes = 4 * 1024 * 1024,
    this.maxEntries = 5000,
  });

  /// 条目最长保留时间（超过即从最旧开始裁剪）。
  final Duration maxAge;

  /// 窗口体积上限（近似字节：键 + 载荷 + 固定开销）。
  final int maxBytes;

  /// 窗口条数上限。
  final int maxEntries;

  /// 窗口是否已超过任一硬上限。
  bool exceeds(
          {required int entries,
          required int bytes,
          required int oldestAt,
          required int nowMs}) =>
      entries > maxEntries ||
      bytes > maxBytes ||
      (oldestAt > 0 && nowMs - oldestAt > maxAge.inMilliseconds);
}

/// 引擎侧消费的增量日志接口（生产 = [SyncJournalRepository]）。
///
/// 引擎只需要「读窗口 / 裁剪 / 记录快照覆盖」，追加由写入点负责
/// （见 [SyncJournalRepository.append] 的同事务约定）。
abstract interface class SyncJournalStore {
  /// 当前头部 seq（0 = 尚无条目）。
  Future<int> headSeq();

  /// 已裁剪到的位置（窗口起点 = 返回值 + 1）。
  Future<int> baseSeq();

  /// 最近构建的全量快照覆盖到的位置（-1 = 尚未构建）。
  Future<int> snapshotSeq();

  Future<SyncJournalStats> stats();

  /// 读取窗口条目（`seq > since`，按 seq 升序）。
  Future<List<SyncJournalEntry>> window({int since = -1, int limit = 0});

  /// 窗口的近似字节量（`seq > since` 的部分）。
  Future<int> windowBytes({int since = -1});

  /// 标记「全量快照已构建到 [seq]」。
  Future<void> markSnapshotBuilt(int seq);

  /// 按对端 ack 与硬上限裁剪窗口，返回新的 [baseSeq]。
  ///
  /// [coverage] 是**已发布**的全量快照覆盖位置（各传输成功推送的最小值）：
  /// 正常路径不会裁到它之后（否则落后 / 新加入的对端无法 bootstrap）；
  /// 窗口超过硬上限时把覆盖推进到头部并保留最新的、仍在上限内的条目，
  /// 更旧的对端降级 bootstrap。
  Future<int> compact({
    required int minAck,
    required int coverage,
    int? nowMs,
  });

  /// 清空日志与窗口状态（派生数据：可由本地数据重建）。
  ///
  /// 首次使用新命名空间时调用；用户数据表与 `sync_tombstones` 不受影响。
  Future<void> reset();
}

/// 一条待追加的本地变更（`seq` 由日志分配）。
typedef SyncJournalChange = ({SyncCategory category, SyncRecord record});

/// 写入点的追加面：适配器只需要「把本机变更追加进日志」，不读窗口 / 不裁剪。
///
/// 收窄成接口是为了让「登记必须在追加成功后才写」可被单测：测试注入一个
/// 追加失败的实现，验证下一轮仍能检测到同一变更。
abstract interface class SyncJournalAppender {
  /// 追加（自开事务）；返回分配到的 seq 列表（与输入同序）。
  Future<List<int>> appendAll(Iterable<SyncJournalChange> changes);
}

/// 增量日志窗口的观测值（硬上限判定与诊断用）。
class SyncJournalStats {
  const SyncJournalStats({
    required this.headSeq,
    required this.baseSeq,
    required this.snapshotSeq,
    required this.entries,
    required this.bytes,
    required this.oldestAt,
  });

  /// 当前头部（0 = 尚无条目）。
  final int headSeq;

  /// 已裁剪到的位置（窗口起点 = baseSeq + 1）。
  final int baseSeq;

  /// 最近构建的全量快照覆盖到的位置（-1 = 尚未构建）。
  final int snapshotSeq;

  final int entries;
  final int bytes;
  final int oldestAt;
}

class SyncJournalRepository implements SyncJournalStore, SyncJournalAppender {
  SyncJournalRepository({
    required this._databaseProvider,
    this.limits = const SyncJournalLimits(),
    int Function()? clock,
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MoliaDatabase Function() _databaseProvider;
  final SyncJournalLimits limits;
  final int Function() _clock;

  MoliaDatabase get _db => _databaseProvider();

  /// 追加本地变更（**必须在数据写入的同一事务 executor 内调用**）。
  ///
  /// 返回分配到的 seq 列表（与输入同序；空输入不写库）。
  Future<List<int>> append(
    DatabaseConnectionUser executor,
    Iterable<SyncJournalChange> changes,
  ) async {
    final list = changes.toList();
    if (list.isEmpty) return const [];
    final db = _db;
    final head = await _headSeq(executor);
    final at = _clock();
    final seqs = <int>[];
    var seq = head;
    for (final change in list) {
      seq++;
      seqs.add(seq);
      await executor.into(db.syncJournal).insert(
            SyncJournalCompanion.insert(
              seq: Value(seq),
              category: change.category.name,
              key: change.record.key,
              versionPhysical: change.record.version.physical,
              versionCounter: Value(change.record.version.counter),
              deviceId: Value(change.record.version.deviceId),
              deleted: Value(change.record.deleted),
              data: Value(
                change.record.data == null
                    ? null
                    : jsonEncode(change.record.data),
              ),
              at: at,
            ),
          );
    }
    return seqs;
  }

  /// 追加本机变更（自开事务；供没有现成 executor 的写入点使用，如设置 /
  /// 脚本 / 会话在各自的变化检测点追加）。
  @override
  Future<List<int>> appendAll(Iterable<SyncJournalChange> changes) {
    final list = changes.toList();
    if (list.isEmpty) return Future.value(const []);
    // 事务内 `_db` 自动走事务执行器（drift 的 zone 语义）。
    return _db.transaction(() => append(_db, list));
  }

  /// 当前头部 seq（0 = 尚无条目）。
  @override
  Future<int> headSeq() => _headSeq(_db);

  /// 已裁剪到的位置（窗口起点 = 返回值 + 1）。
  @override
  Future<int> baseSeq() async => (await stats()).baseSeq;

  /// 最近构建的全量快照覆盖到的位置（-1 = 尚未构建）。
  @override
  Future<int> snapshotSeq() async => (await stats()).snapshotSeq;

  /// 窗口观测值（条数 / 体积 / 最旧时间 / 头部与裁剪位置）。
  @override
  Future<SyncJournalStats> stats() async {
    final db = _db;
    return db.transaction(() async {
      final state = await _stateRow(db);
      final head = await _headSeq(db);
      final row = await db.customSelect('''
        SELECT COUNT(*) AS n,
               COALESCE(SUM(LENGTH("key") + COALESCE(LENGTH(data), 0) + 96), 0) AS b,
               COALESCE(MIN(at), 0) AS o
        FROM sync_journal WHERE seq > ?
      ''', variables: [Variable<int>(state.baseSeq)]).getSingle();
      return SyncJournalStats(
        headSeq: head,
        baseSeq: state.baseSeq,
        snapshotSeq: state.snapshotSeq,
        entries: (row.data['n'] as num?)?.toInt() ?? 0,
        bytes: (row.data['b'] as num?)?.toInt() ?? 0,
        oldestAt: (row.data['o'] as num?)?.toInt() ?? 0,
      );
    });
  }

  /// 读取窗口条目（`seq > since`，按 seq 升序；[limit] > 0 时截断）。
  @override
  Future<List<SyncJournalEntry>> window({int since = -1, int limit = 0}) async {
    final db = _db;
    final query = db.select(db.syncJournal)
      ..where((t) => t.seq.isBiggerThanValue(since))
      ..orderBy([(t) => OrderingTerm.asc(t.seq)]);
    if (limit > 0) query.limit(limit);
    final rows = await query.get();
    return [
      for (final row in rows)
        ?_entryFromRow(row),
    ];
  }

  /// 窗口的近似字节量（`seq > since` 的部分；对端落后字节用）。
  @override
  Future<int> windowBytes({int since = -1}) async {
    final db = _db;
    final row = await db.customSelect('''
      SELECT COALESCE(SUM(LENGTH("key") + COALESCE(LENGTH(data), 0) + 96), 0) AS b
      FROM sync_journal WHERE seq > ?
    ''', variables: [Variable<int>(since)]).getSingle();
    return (row.data['b'] as num?)?.toInt() ?? 0;
  }

  /// 标记「全量快照已构建到 [seq]」：compact 的裁剪不会超过该位置。
  @override
  Future<void> markSnapshotBuilt(int seq) async {
    final db = _db;
    await db.transaction(() async {
      final state = await _stateRow(db);
      if (seq <= state.snapshotSeq) return;
      await _writeState(db, baseSeq: state.baseSeq, snapshotSeq: seq);
    });
  }

  /// compact：按对端 ack 与硬上限裁剪窗口，返回新的 [baseSeq]。
  ///
  /// 正常路径裁剪到 `min(minAck, coverage, head)`——既不裁掉任何对端还没
  /// ack 的条目，也不裁掉**已发布**的全量快照尚未覆盖的位置；窗口超过硬
  /// 上限（时间 / 体积 / 条数）时把快照覆盖推进到当前头部并只保留最新的、
  /// 仍在上限内的条目——更旧的对端降级为 bootstrap（见类文档）。
  @override
  Future<int> compact({
    required int minAck,
    required int coverage,
    int? nowMs,
  }) async {
    final db = _db;
    final now = nowMs ?? _clock();
    return db.transaction(() async {
      final state = await _stateRow(db);
      final head = await _headSeq(db);
      final row = await db.customSelect('''
        SELECT COUNT(*) AS n,
               COALESCE(SUM(LENGTH("key") + COALESCE(LENGTH(data), 0) + 96), 0) AS b,
               COALESCE(MIN(at), 0) AS o
        FROM sync_journal WHERE seq > ?
      ''', variables: [Variable<int>(state.baseSeq)]).getSingle();
      final entries = (row.data['n'] as num?)?.toInt() ?? 0;
      final bytes = (row.data['b'] as num?)?.toInt() ?? 0;
      final oldestAt = (row.data['o'] as num?)?.toInt() ?? 0;
      if (limits.exceeds(
        entries: entries,
        bytes: bytes,
        oldestAt: oldestAt,
        nowMs: now,
      )) {
        // 硬上限：快照覆盖推进到头部（引擎随后构建并推送新快照），保留最新
        // 的、仍在上限内的条目；更旧的对端下次拉取时走 bootstrap。
        final keepFrom =
            await _newestWithinLimits(db, state.baseSeq, head, now);
        await _writeState(db, baseSeq: keepFrom, snapshotSeq: head);
        await _trim(db, keepFrom);
        return keepFrom;
      }
      final covered = coverage < 0 ? 0 : coverage;
      final target = math.max(
        state.baseSeq,
        math.min(math.min(minAck, head), covered),
      );
      if (target > state.baseSeq) {
        await _writeState(db, baseSeq: target, snapshotSeq: state.snapshotSeq);
        await _trim(db, target);
      }
      return target;
    });
  }

  /// 清空日志与窗口状态（首次使用新命名空间时重建派生状态）。
  ///
  /// 只删可再生的派生数据；用户数据表与 `sync_tombstones` 不动。
  @override
  Future<void> reset() async {
    final db = _db;
    await db.transaction(() async {
      await db.delete(db.syncJournal).go();
      await db.delete(db.syncJournalStates).go();
    });
  }

  /// 硬上限裁剪的保留起点：从最新往回累计，直到超过任一条数 / 体积 / 时间
  /// 上限；返回新的 baseSeq（保留条目里最小 seq - 1；一条都保留不了时为头部）。
  Future<int> _newestWithinLimits(
    DatabaseConnectionUser executor,
    int baseSeq,
    int head,
    int nowMs,
  ) async {
    final rows = await executor.customSelect('''
      SELECT seq, at, LENGTH("key") + COALESCE(LENGTH(data), 0) + 96 AS b
      FROM sync_journal WHERE seq > ? ORDER BY seq DESC
    ''', variables: [Variable<int>(baseSeq)]).get();
    var entries = 0;
    var bytes = 0;
    var keepFrom = -1;
    for (final row in rows) {
      final seq = (row.data['seq'] as num?)?.toInt() ?? 0;
      final at = (row.data['at'] as num?)?.toInt() ?? 0;
      final size = (row.data['b'] as num?)?.toInt() ?? 0;
      final tooOld = at > 0 && nowMs - at > limits.maxAge.inMilliseconds;
      if (tooOld ||
          entries + 1 > limits.maxEntries ||
          bytes + size > limits.maxBytes) {
        break;
      }
      entries++;
      bytes += size;
      keepFrom = seq;
    }
    if (keepFrom < 0) return head;
    return keepFrom - 1;
  }

  Future<int> _headSeq(DatabaseConnectionUser executor) async {
    // 头部 = max(已裁剪位置, 窗口内最大 seq)：窗口整体裁剪后 MAX(seq) 为空，
    // 但头部位置由 baseSeq 保留（裁剪只发生在 ≤ 头部的位置）。
    final state = await _stateRow(executor);
    final row = await executor
        .customSelect('SELECT COALESCE(MAX(seq), 0) AS m FROM sync_journal')
        .getSingle();
    final maxSeq = (row.data['m'] as num?)?.toInt() ?? 0;
    return maxSeq > state.baseSeq ? maxSeq : state.baseSeq;
  }

  /// 单行窗口状态（不存在时按初始值建行：baseSeq = 0、snapshotSeq = -1）。
  Future<({int baseSeq, int snapshotSeq})> _stateRow(
    DatabaseConnectionUser executor,
  ) async {
    final db = _db;
    final row = await (executor.select(db.syncJournalStates)
          ..where((t) => t.id.equals(0))
          ..limit(1))
        .getSingleOrNull();
    if (row != null) {
      return (baseSeq: row.baseSeq, snapshotSeq: row.snapshotSeq);
    }
    await executor.into(db.syncJournalStates).insert(
          const SyncJournalStatesCompanion(
            id: Value(0),
            baseSeq: Value(0),
            snapshotSeq: Value(-1),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return (baseSeq: 0, snapshotSeq: -1);
  }

  Future<void> _writeState(
    DatabaseConnectionUser executor, {
    required int baseSeq,
    required int snapshotSeq,
  }) async {
    final db = _db;
    await executor.into(db.syncJournalStates).insert(
          SyncJournalStatesCompanion(
            id: const Value(0),
            baseSeq: Value(baseSeq),
            snapshotSeq: Value(snapshotSeq),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  Future<void> _trim(DatabaseConnectionUser executor, int throughSeq) async {
    final db = _db;
    await (executor.delete(db.syncJournal)
          ..where((t) => t.seq.isSmallerOrEqualValue(throughSeq)))
        .go();
  }

  /// 行 → 领域条目；类别未知的行跳过（返回 null）。
  SyncJournalEntry? _entryFromRow(SyncJournalData row) {
    final category = SyncCategory.tryParse(row.category);
    if (category == null) return null;
    final rawData = row.data;
    Map<String, Object?>? data;
    if (rawData != null && rawData.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawData);
        if (decoded is Map) {
          data = decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (_) {
        // 损坏载荷按 null 处理（记录仍在，版本与键照常参与合并）。
      }
    }
    return SyncJournalEntry(
      seq: row.seq,
      category: category,
      record: SyncRecord(
        key: row.key,
        deleted: row.deleted,
        version: SyncVersion(
          physical: row.versionPhysical,
          counter: row.versionCounter,
          deviceId: row.deviceId,
        ),
        data: data,
      ),
    );
  }
}
