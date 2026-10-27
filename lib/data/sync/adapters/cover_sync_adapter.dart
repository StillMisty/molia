import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

import '../../../domain/models/device_sync.dart';
import '../../../services/covers/custom_cover_store.dart';
import '../sync_adapter.dart';
import '../sync_book.dart';
import '../sync_journal.dart';
import '../sync_stamp.dart';

/// 自定义封面适配器（`covers` 类别）。
///
/// - 记录键 = 封面键（`sourceKey:songId`）+ 全局默认封面的保留键
///   [SyncRecordKeys.defaultCoverKey]；
/// - 版本 = 内容哈希变化时向发号器现取的版本戳（图片字节本身不带版本，
///   登记在同步状态里跨轮稳定）；
/// - 类别未被本轮请求时 [collectForCategories] 立即返回空，不读文件、
///   不算哈希、不增长缓存（蜂窝小类别轮因此不带封面字节）；手动完整备份
///   请求全部类别，因此仍会带上已有封面；
/// - 开启后的第一次收集只登记已有封面、不逐张追加增量：控制面在开启时
///   已重置各传输的快照发布覆盖，全量快照会携带它们；此后首次登记 / 真实
///   变化 / 删除 / 墓碑后重设都追加日志，让增量对端收到；墓碑后重设必须取
///   新版本，不能复用旧戳（否则会输给更陈旧的墓碑）；
/// - 只接受本地归一化产出的 JPEG（记录固定 `image/jpeg` / `.jpg`）：
///   PNG / GIF / WebP 与损坏载荷一律跳过；单张图超过
///   [CustomCoverStore.maxSyncBytes] 只跳过同步并记一次日志，本地封面继续
///   可用；接收侧在 base64 解码前先按长度拒绝超限记录；
/// - 远端应用只写封面存储与登记，不触发本地变更回调（不会形成同步回环）。
class CoverSyncAdapter implements CategoryScopedSyncAdapter {
  CoverSyncAdapter({
    required this._store,
    required this._state,
    this._journal,
    bool Function()? enabled,
    Logger? logger,
  })  : _enabled = enabled ?? (() => true),
        _logger = logger ?? Logger('molia.sync') {
    // 构造时开关已开启 = 不是本进程内的「刚开启」：首次收集按常规登记
    // 变化。构造时关闭、之后开启才走切换轮规则（见 [collectForCategories]）。
    _wasEnabled = _enabled();
  }

  /// 线上图片 MIME（Phase 1 归一化产物固定是 JPEG）。
  static const String _mime = 'image/jpeg';

  /// [CustomCoverStore.maxSyncBytes] 上限对应的 base64 文本长度。
  ///
  /// 接收侧先按字符串长度拒绝再解码：异常远端不能让我们为一张超限图片分配
  /// 数倍于上限的内存。
  static const int _maxBase64Length =
      ((CustomCoverStore.maxSyncBytes + 2) ~/ 3) * 4;

  final CustomCoverStore _store;
  final SyncStampLedger _state;

  /// 增量日志（可选）：需要让增量对端立刻收到的变化才追加。
  final SyncJournalAppender? _journal;

  /// 类别是否启用（默认开关来自同步状态；未请求时整轮跳过）。
  final bool Function() _enabled;
  final Logger _logger;

  /// 上次收集时看到的类别开关，用于识别 off → on 的切换。
  bool _wasEnabled = false;

  /// 已观察到 off → on，但还没有真正收集过封面。
  ///
  /// 中间可能夹着小类别轮 / 备份轮（不读封面）：第一次读封面的那一轮才用
  /// 切换轮规则，避免把开启前就存在的封面整库塞进增量日志。
  bool _firstCoversCollectAfterEnable = false;

  /// base64 缓存上限：只缓存最近读过的少量封面，避免随曲库增长。
  ///
  /// 超过上限后整库 collect 会逐张重读（有界内存优先）；缓存只服务最近
  /// 变化过的少量封面，不随曲库增长。
  static const int _base64CacheLimit = 16;

  /// 封面键 → 上轮读到的内容哈希 + base64（哈希未变不重读文件；LRU）。
  final LinkedHashMap<String, ({String hash, String base64})> _base64Cache =
      LinkedHashMap();

  /// 已提示过「无法同步」的键（同一张大图不每轮刷日志）。
  final Set<String> _unsyncableLogged = {};

  @override
  Set<SyncCategory> get categories => const {SyncCategory.covers};

  @override
  bool get ready => _store.isLoaded;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({bool fresh = false}) =>
      collectForCategories(categories, fresh: fresh);

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collectForCategories(
    Set<SyncCategory> categories, {
    bool fresh = false,
  }) async {
    final enabled = _enabled();
    // 无论本轮是否请求封面都要跟踪开关：小类别轮 / 备份轮可能夹在
    // off → on 与第一次封面轮之间。
    if (enabled && !_wasEnabled) _firstCoversCollectAfterEnable = true;
    if (!enabled) _firstCoversCollectAfterEnable = false;
    _wasEnabled = enabled;
    if (!categories.contains(SyncCategory.covers)) return const {};
    if (!ready) return const {};
    final firstAfterEnable = _firstCoversCollectAfterEnable;
    _firstCoversCollectAfterEnable = false;
    // 索引快照：曲目封面 + 默认封面；键与同步登记一一对应。
    final current = <String, CustomCoverEntry>{
      ..._store.trackEntries,
      if (_store.defaultEntry != null)
        SyncRecordKeys.defaultCoverKey: _store.defaultEntry!,
    };

    final changes = <SyncJournalChange>[];
    final registrations = <String, SyncStamp>{};
    final removedStamps = <String>{};
    final removedTombstones = <String>{};
    final newTombstones = <String, SyncStamp>{};
    final records = <SyncRecord>[];

    // 上轮登记过、本轮索引里消失 = 本地删除：一律取新戳（复用旧墓碑会让
    // 这次删除输给更陈旧的远端墓碑）。
    for (final key in _state.coverStamps.keys.toList()) {
      if (current.containsKey(key)) continue;
      final version = _state.stampIssuer.next();
      newTombstones[key] = SyncStamp(version: version);
      removedStamps.add(key);
      if (enabled) {
        changes.add((
          category: SyncCategory.covers,
          record: SyncRecord.tombstone(
            key: key,
            version: version,
            deletedAt: version.physical,
          ),
        ));
      }
    }

    for (final entry in current.entries) {
      final key = entry.key;
      final stamp = _state.coverStamps[key];
      final tombstone = _state.coverTombstones[key];
      final data = await _recordData(key, entry.value);
      if (data == null) {
        // 读不到 / 超限 / 损坏：不产出记录。仍登记当前哈希，避免每轮重复
        // 读大文件；哈希变化后会重新尝试。
        final hash = entry.value.hash;
        if (stamp == null || stamp.hash != hash) {
          registrations[key] = SyncStamp(
            hash: hash,
            version: _state.stampIssuer.next(),
          );
        }
        // 本地重新设置封面（哪怕暂时不能同步）也要清掉旧墓碑。
        if (tombstone != null) removedTombstones.add(key);
        continue;
      }

      // 有墓碑时一律取新版本：即使内容哈希与旧登记相同，也不能复用删除前
      // 的旧戳去和墓碑比大小（否则重设的封面会被对端当成陈旧记录跳过）。
      final stampUnchanged =
          tombstone == null && stamp != null && stamp.hash == data.hash;
      final version =
          stampUnchanged ? stamp.version : _state.stampIssuer.next();
      if (!stampUnchanged) {
        registrations[key] = SyncStamp(hash: data.hash, version: version);
      }
      if (tombstone != null) removedTombstones.add(key);
      final record = SyncRecord(
        key: key,
        version: version,
        data: data.data,
      );
      records.add(record);
      // 刚开启类别的第一轮不逐张追加已有封面：控制面已重置快照发布，
      // 全量快照会携带它们。此后的首次登记 / 内容变化 / 墓碑后重设仍写
      // 日志，让已开启的对端在快照之外立刻收到。
      final firstRegistration = stamp == null && tombstone == null;
      if (!stampUnchanged &&
          enabled &&
          !(firstAfterEnable && firstRegistration)) {
        changes.add((category: SyncCategory.covers, record: record));
      }
    }

    // 本轮之前就存在的墓碑继续外发；被本地重新设置封面的键不再发墓碑。
    final allTombstones = {..._state.coverTombstones, ...newTombstones};
    for (final entry in allTombstones.entries) {
      if (current.containsKey(entry.key)) continue;
      if (removedTombstones.contains(entry.key)) continue;
      records.add(SyncRecord.tombstone(
        key: entry.key,
        version: entry.value.version,
        deletedAt: entry.value.version.physical,
      ));
    }

    // 先追加日志、后写登记：追加失败时保留旧登记，下一轮仍能检测到变更。
    final journal = _journal;
    if (journal != null && changes.isNotEmpty) {
      await journal.appendAll(changes);
    }
    for (final key in removedStamps) {
      _state.removeCoverStamp(key);
    }
    for (final key in removedTombstones) {
      _state.removeCoverTombstone(key);
    }
    for (final entry in registrations.entries) {
      _state.putCoverStamp(entry.key, entry.value);
    }
    for (final entry in newTombstones.entries) {
      _state.putCoverTombstone(entry.key, entry.value);
    }
    return {SyncCategory.covers: records};
  }

  /// 读取并缓存一张封面的 base64；无法同步时返回 null（不影响本地封面）。
  Future<({String hash, Map<String, Object?> data})?> _recordData(
    String key,
    CustomCoverEntry entry,
  ) async {
    // 命中后移到队尾：LinkedHashMap 按插入顺序淘汰，队首是最久未用的。
    final cached = _base64Cache.remove(key);
    if (cached != null && cached.hash.isNotEmpty && cached.hash == entry.hash) {
      _base64Cache[key] = cached;
      return (
        hash: cached.hash,
        data: _recordDataOf(cached.hash, cached.base64, entry.updatedAt)
      );
    }

    final bytes = key == SyncRecordKeys.defaultCoverKey
        ? await _store.readDefaultCover()
        : await _store.readTrackCoverByKey(key);
    if (bytes == null) {
      _logUnsyncable(key, '读取失败');
      return null;
    }
    if (!CustomCoverStore.canSyncImageBytes(bytes)) {
      _base64Cache.remove(key);
      _logUnsyncable(
        key,
        bytes.length > CustomCoverStore.maxSyncBytes ? '超过同步大小上限' : '图片损坏',
      );
      return null;
    }
    final hash = sha256.convert(bytes).toString();
    final base64 = base64Encode(bytes);
    _cacheBase64(key, (hash: hash, base64: base64));
    return (hash: hash, data: _recordDataOf(hash, base64, entry.updatedAt));
  }

  /// 写入 base64 缓存并淘汰最久未用的条目（内存不随曲库增长）。
  void _cacheBase64(String key, ({String hash, String base64}) value) {
    _base64Cache.remove(key);
    _base64Cache[key] = value;
    while (_base64Cache.length > _base64CacheLimit) {
      _base64Cache.remove(_base64Cache.keys.first);
    }
  }

  static Map<String, Object?> _recordDataOf(
    String hash,
    String base64,
    int updatedAt,
  ) =>
      {
        'image': base64,
        'mime': _mime,
        'hash': hash,
        'updatedAt': updatedAt,
      };

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    if (!ready) return SyncApplyOutcome.none;
    var applied = 0;
    var skipped = 0;
    for (final record in records[SyncCategory.covers] ?? const <SyncRecord>[]) {
      if (record.key.isEmpty) {
        skipped++;
        continue;
      }
      final isDefault = record.key == SyncRecordKeys.defaultCoverKey;
      final current =
          isDefault ? _store.defaultEntry : _store.trackEntry(record.key);
      final stamp = _state.coverStamps[record.key];
      final tombstone = _state.coverTombstones[record.key];

      if (record.deleted) {
        final outcome = await _applyTombstone(
          record: record,
          isDefault: isDefault,
          current: current,
          stamp: stamp,
          tombstone: tombstone,
        );
        applied += outcome.applied;
        skipped += outcome.skipped;
        continue;
      }

      // 墓碑不输给更旧（或同版本）的图片：旧备份 / 陈旧对端不能复活封面。
      if (tombstone != null && !record.version.isNewerThan(tombstone.version)) {
        skipped++;
        continue;
      }
      if (stamp != null) {
        if (stamp.version.isNewerThan(record.version)) {
          skipped++;
          continue;
        }
        // 同版本同内容 = 幂等重放；同版本不同内容 = 全量快照的强制交付，
        // 必须继续 decode 并修回远端视图。
        final remoteHash = record.data?['hash'];
        if (stamp.version == record.version &&
            current != null &&
            current.hash.isNotEmpty &&
            stamp.hash == current.hash &&
            (remoteHash is! String || remoteHash == stamp.hash)) {
          skipped++;
          continue;
        }
      }

      final decoded = _decode(record);
      if (decoded == null) {
        _logUnsyncable(record.key, '远端图片损坏或超限');
        skipped++;
        continue;
      }
      if (current != null && current.hash == decoded.hash) {
        // 内容已经一致：只更新登记，不重写文件。
        _state.putCoverStamp(
          record.key,
          SyncStamp(hash: decoded.hash, version: record.version),
        );
        if (tombstone != null) _state.removeCoverTombstone(record.key);
        applied++;
        continue;
      }
      if (isDefault) {
        await _store.applySyncedDefaultCover(decoded.bytes);
      } else {
        await _store.applySyncedTrackCover(record.key, decoded.bytes);
      }
      _state.putCoverStamp(
        record.key,
        SyncStamp(hash: decoded.hash, version: record.version),
      );
      if (tombstone != null) _state.removeCoverTombstone(record.key);
      applied++;
    }
    return SyncApplyOutcome(applied: applied, skipped: skipped);
  }

  Future<SyncApplyOutcome> _applyTombstone({
    required SyncRecord record,
    required bool isDefault,
    required CustomCoverEntry? current,
    required SyncStamp? stamp,
    required SyncStamp? tombstone,
  }) async {
    if (stamp != null && !record.version.isNewerThan(stamp.version)) {
      return const SyncApplyOutcome(skipped: 1);
    }
    if (stamp == null &&
        tombstone != null &&
        !record.version.isNewerThan(tombstone.version)) {
      return const SyncApplyOutcome(skipped: 1);
    }
    var applied = 0;
    if (current != null) {
      if (isDefault) {
        await _store.applySyncedDefaultDelete();
      } else {
        await _store.applySyncedTrackDelete(record.key);
      }
      applied = 1;
    }
    _state.removeCoverStamp(record.key);
    _state.putCoverTombstone(
      record.key,
      SyncStamp(version: record.version),
    );
    return SyncApplyOutcome(applied: applied, skipped: applied == 0 ? 1 : 0);
  }

  /// base64 → 图片字节；损坏 / 超限 / 非图片一律返回 null（跳过，不抛）。
  ({Uint8List bytes, String hash})? _decode(SyncRecord record) {
    final raw = record.data?['image'];
    if (raw is! String || raw.isEmpty) return null;
    // base64 长度先于解码判定：超过 500KB 字节上限的记录直接拒绝。
    if (raw.length > _maxBase64Length) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(raw);
    } catch (_) {
      return null;
    }
    if (!CustomCoverStore.canSyncImageBytes(bytes)) return null;
    return (bytes: bytes, hash: sha256.convert(bytes).toString());
  }

  void _logUnsyncable(String key, String reason) {
    if (!_unsyncableLogged.add(key)) return;
    _logger.warning('自定义封面「$key」$reason，已跳过同步（本地封面不受影响）');
  }
}
