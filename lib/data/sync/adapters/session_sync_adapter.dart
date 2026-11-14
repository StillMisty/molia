import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../domain/models/device_sync.dart';
import '../../../domain/models/download.dart' show kLocalSourceKey;
import '../../../domain/ports/playback_session_sync.dart';
import '../sync_adapter.dart';
import '../sync_book.dart';
import '../sync_journal.dart';
import '../sync_stamp.dart';

/// 队列未变、只有游标变化时的增量记录类别。
const String _sessionCursorKind = 'sessionCursor';

/// 游标增量记录的格式版本（字段增删时递增，旧版本接收方跳过即可）。
const int _sessionCursorVersion = 1;

/// 上次播放会话适配器：把「上次播放的队列 + 下标 + 进度 + 模式」带到其它设备
/// （换设备接着听的轻量版，非实时控制）。
///
/// - 记录键固定 [SyncRecordKeys.sessionKey]；`savedAt`（会话写入时间）是内容
///   时间，版本戳在内容变化时向发号器现取；正在播放的设备持续刷新从而抢占；
/// - **本地清空不回传删除**：会话是「最近活动」的指针，停止播放只影响本机；
///   远端更新的会话（版本更大）到达时仍会重新填充；
/// - 应用后经 [onChanged] 让播放器重载恢复态（仅在没有真实播放时生效）。
/// - **游标增量**：队列内容未变时只追加「下标 / 进度 / 模式 / 上下文」，
///   不重复写含每首 raw payload 的整份 JSON（大队列下 MB 级）；
///   本地整份记录仍由首次同步、队列变化与全量快照负责。
class SessionSyncAdapter implements SyncAdapter {
  SessionSyncAdapter({
    required this._port,
    required this._state,
    this._journal,
    this._onChanged,
  });

  /// 会话读写端口（生产 = `PlaybackSessionCoordinator`，保证远端写入与本地
  /// 保存共用同一个 store 写队列；测试也可直接注入 store）。
  final PlaybackSessionSyncPort _port;
  final SyncStampLedger _state;

  /// 增量日志（可选）：`savedAt` 变化（会话内容变化）时追加；首次登记
  /// 不算变更（初始视图由全量快照覆盖）。
  final SyncJournalAppender? _journal;
  final Future<void> Function()? _onChanged;

  /// 写入点即时追加的合并窗口（见 [noteLocalSave]）。
  static const int immediateWindowMs = 60 * 1000;
  int _lastImmediateAppendAt = 0;

  /// 进程内最近一次「整份队列」对应的哈希。
  ///
  /// 只有它等于当前队列哈希时才能发游标增量：否则对端没有可对应的 tracks
  /// 底稿，游标记录（不含 tracks）无法落地。进程重启后为 null，第一次
  /// 收集 / 保存必须重新发整份。
  String? _lastFullQueueHash;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.session};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({
    bool fresh = false,
  }) async {
    final loaded = await _port.loadRaw();
    // 本地下载曲目不同步：文件是设备本机的持久副本，其它设备无法播放。
    final raw = loaded == null ? null : _withoutLocalTracks(loaded);
    if (loaded != null && raw == null) {
      // 会话里全是本地曲目：没有可同步内容，也不回传删除。
      _lastFullQueueHash = null;
      return const {};
    }
    final stamp = _state.sessionStamp;
    if (raw == null) {
      // 本地会话被清空（停止播放）：不回传删除；保持登记不变，
      // 远端版本更大的会话仍可在后续轮次重新填充。
      _lastFullQueueHash = null;
      if (stamp == null) {
        _state.setSessionStamp(const SyncStamp());
      }
      return const {};
    }

    final savedAt = (raw[kPlaybackSessionSavedAtKey] as num?)?.toInt() ?? 0;
    // 没有 savedAt 的会话不是本版写入的（旧数据 / 直改）：不上行、不登记，
    // 等下一次真实保存带来 savedAt 后再参与同步。
    if (savedAt <= 0) return const {};
    final hash = '$savedAt';
    final changed = stamp == null || stamp.hash != hash;
    final queueHash = _queueHashOf(raw);
    // 什么时候必须外发整份队列（而不是游标增量）：
    // - fresh：anti-entropy / 全量快照 / 备份 / 新对端引导，只有游标没有
    //   tracks 等于什么都没给；
    // - 没有增量日志：快照是唯一通道，游标对快照接收方无用；
    // - 进程内还没发过这份队列，或队列内容变了：对端没有可对应的底稿；
    // - 本次没有版本变化：同版本游标会被对端按幂等跳过，空闲轮快照也需要
    //   整份记录，直接复用现有整份（不产生额外写）。
    final full =
        fresh ||
        _journal == null ||
        !changed ||
        _lastFullQueueHash != queueHash;
    final data = full ? raw : _cursorData(raw, queueHash);
    final SyncStamp effective;
    if (changed) {
      final version = _state.stampIssuer.next();
      effective = SyncStamp(hash: hash, version: version);
      // 首次登记不是变更（初始视图由全量快照覆盖）；真实变化追加日志。
      // fresh 的整份记录已经随全量快照（备份 / anti-entropy / bootstrap）
      // 外发，再写一行 MB 级的整份日志纯属放大：只更新登记与整份底稿。
      // 登记必须在追加成功后才写：追加失败时保留旧登记，下一轮重新检测。
      final journal = _journal;
      if (!fresh && journal != null && stamp != null) {
        await journal.appendAll([
          (
            category: SyncCategory.session,
            record: SyncRecord(
              key: SyncRecordKeys.sessionKey,
              version: effective.version,
              data: data,
            ),
          ),
        ]);
      }
      // 追加成功（或首次登记无需追加）后才记住整份底稿；失败时保持旧值，
      // 下一轮仍会退回整份而不是发一个对端无法适用的游标。
      if (full) _lastFullQueueHash = queueHash;
      _state.setSessionStamp(effective);
    } else {
      effective = stamp;
      if (full) _lastFullQueueHash = queueHash;
    }
    return {
      SyncCategory.session: [
        SyncRecord(
          key: SyncRecordKeys.sessionKey,
          version: effective.version,
          data: data,
        ),
      ],
    };
  }

  /// 本机保存会话（组合根在会话存储的保存回调上接线）：**立即**登记并追加
  /// 日志，写入后进程被杀也不丢这次变更。
  ///
  /// 合并窗口内的高频进度保存只登记一次：会话载荷是整份队列（体积远大于其它
  /// 类别），每次保存都追加会把日志硬上限撑爆；窗口外的变更由下一轮统一登记
  /// （哈希检测），两者互为兜底。同队列的保存只追加游标增量，不重写整份队列。
  Future<void> noteLocalSave() async {
    final now = _state.nowMs();
    if (_lastImmediateAppendAt > 0 &&
        now - _lastImmediateAppendAt < immediateWindowMs) {
      return;
    }
    final loaded = await _port.loadRaw();
    final raw = loaded == null ? null : _withoutLocalTracks(loaded);
    if (loaded != null && raw == null) {
      _lastFullQueueHash = null;
      return;
    }
    final stamp = _state.sessionStamp;
    if (raw == null) {
      _lastFullQueueHash = null;
      if (stamp == null) _state.setSessionStamp(const SyncStamp());
      return;
    }
    final savedAt = (raw[kPlaybackSessionSavedAtKey] as num?)?.toInt() ?? 0;
    // 旧会话 / 缺 savedAt：无法排序也不该外发，等真实保存再来。
    if (savedAt <= 0) return;
    final hash = '$savedAt';
    if (stamp != null && stamp.hash == hash) return;
    final queueHash = _queueHashOf(raw);
    // 没有整份底稿时第一次保存必须发整份；窗口只影响「是否立刻追加」，
    // 不影响整份 / 游标的判定。
    final full = _lastFullQueueHash != queueHash;
    final data = full ? raw : _cursorData(raw, queueHash);
    final version = _state.stampIssuer.next();
    final journal = _journal;
    if (journal != null && stamp != null) {
      // 先追加、后登记：追加失败时不写登记也不推进合并窗口，下次保存重试。
      await journal.appendAll([
        (
          category: SyncCategory.session,
          record: SyncRecord(
            key: SyncRecordKeys.sessionKey,
            version: version,
            data: data,
          ),
        ),
      ]);
    }
    if (full) _lastFullQueueHash = queueHash;
    _state.setSessionStamp(SyncStamp(hash: hash, version: version));
    _lastImmediateAppendAt = now;
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final list = records[SyncCategory.session] ?? const <SyncRecord>[];
    // 日志窗口可能同时含同一会话的整份记录与游标增量：取版本最大的那条，
    // 不能按到达顺序取第一条，否则旧的整份会把更新的游标盖回去。
    SyncRecord? record;
    for (final item in list) {
      if (item.key != SyncRecordKeys.sessionKey) continue;
      if (record == null || item.version.isNewerThan(record.version)) {
        record = item;
      }
    }
    if (record == null) return SyncApplyOutcome.none;

    final data = record.data;
    final savedAt = (data?[kPlaybackSessionSavedAtKey] as num?)?.toInt() ?? 0;
    final stamp = _state.sessionStamp;
    if (stamp != null) {
      if (stamp.version.isNewerThan(record.version)) {
        return const SyncApplyOutcome(applied: 0, skipped: 1);
      }
      // 同版本（只会来自全量快照的强制交付）：比较**当前会话**与登记——
      // 一致则幂等跳过；不一致（本地会话被直改）用权威视图修回去。
      if (stamp.version == record.version) {
        final current = await _port.loadRaw();
        final currentSavedAt =
            (current?[kPlaybackSessionSavedAtKey] as num?)?.toInt() ?? 0;
        if (stamp.hash == '$currentSavedAt') {
          return const SyncApplyOutcome(applied: 0, skipped: 1);
        }
      }
    }

    if (record.deleted) {
      await _port.clearRemote();
      _state.setSessionStamp(SyncStamp(version: record.version));
      // 会话已清空：下一次本地保存必须重新发整份队列。
      _lastFullQueueHash = null;
    } else if (data != null && data['kind'] == _sessionCursorKind) {
      // 未识别的游标格式不能按当前字段强行合并；让 anti-entropy 的全量快照
      // 补，避免把未来版本的字段解释成错误的 index / position。
      if (data['v'] != _sessionCursorVersion) {
        return const SyncApplyOutcome(applied: 0, skipped: 1);
      }
      final queueHash = data['queueHash'];
      if (queueHash is! String || queueHash.isEmpty || savedAt <= 0) {
        return const SyncApplyOutcome(applied: 0, skipped: 1);
      }
      final current = await _port.loadRaw();
      if (current == null) {
        return const SyncApplyOutcome(applied: 0, skipped: 1);
      }
      final filtered = _withoutLocalTracks(current);
      // 本地只剩本地曲目就没有可合并的队列；队列内容与发送方不一致说明
      // 中间漏了整份记录：跳过，等 anti-entropy / 快照补。
      if (filtered == null || _queueHashOf(filtered) != queueHash) {
        return const SyncApplyOutcome(applied: 0, skipped: 1);
      }
      await _port.applyRemote(_mergeCursor(current, data));
      // 游标适用的前提就是双方队列一致：本地也具备了这个整份底稿。
      _lastFullQueueHash = queueHash;
      _state.setSessionStamp(
        SyncStamp(hash: '$savedAt', version: record.version),
      );
    } else {
      if (data == null || data.isEmpty || savedAt <= 0) {
        // 没有 savedAt 的远端会话无法排序（旧数据 / 损坏载荷）：跳过。
        return const SyncApplyOutcome(applied: 0, skipped: 1);
      }
      final payload = data.map((k, v) => MapEntry(k.toString(), v));
      await _port.applyRemote(payload);
      final filtered = _withoutLocalTracks(payload);
      _lastFullQueueHash = _queueHash(filtered?['tracks']);
      _state.setSessionStamp(
        SyncStamp(hash: '$savedAt', version: record.version),
      );
    }
    final changed = _onChanged;
    if (changed != null) await changed();
    return const SyncApplyOutcome(applied: 1);
  }

  /// 队列哈希：过滤掉本地下载曲目后，按身份 + 展示字段做 canonical 编码。
  ///
  /// 为什么不直接 `jsonEncode(track)`：JSON map 的键序取决于来源（本地
  /// store / 远端记录 / 旧版本），同一队列在发送端与接收端可能得到不同字节。
  /// 这里只取 `sourceKey` / `id` / `title` / `artists`：前两者是曲目身份，
  /// 后两者用于发现同 id 的元数据变化；不取 `payload` / `qualities`——直链
  /// 和逐曲元数据会在取链时刷新，纳入哈希会让每次刷新都退化成整份队列重发。
  /// 字段用长度前缀编码，避免标题里的分隔符造成拼接歧义。
  static String _queueHashOf(Map<String, dynamic> raw) {
    final filtered = _withoutLocalTracks(raw);
    return _queueHash(filtered?['tracks']);
  }

  static String _queueHash(Object? tracks) {
    final canonical = StringBuffer();
    if (tracks is! List) {
      canonical.write('no-tracks');
    } else {
      canonical
        ..write('tracks:')
        ..write(tracks.length)
        ..write(';');
      for (final track in tracks) {
        final map = track is Map ? track : const <Object?, Object?>{};
        _writeHashField(canonical, map['sourceKey']);
        _writeHashField(canonical, map['id']);
        _writeHashField(canonical, map['title']);
        final artists = map['artists'];
        final names = <String>[
          if (artists is List)
            for (final artist in artists)
              if (artist is Map && artist['name'] is String)
                artist['name'] as String,
        ];
        canonical
          ..write(names.length)
          ..write(';');
        for (final name in names) {
          _writeHashField(canonical, name);
        }
      }
    }
    return sha256.convert(utf8.encode(canonical.toString())).toString();
  }

  static void _writeHashField(StringBuffer out, Object? value) {
    final text = value is String ? value : '';
    out
      ..write(text.length)
      ..write(':')
      ..write(text)
      ..write(';');
  }

  /// 游标增量载荷：不含 tracks，只带对端合并所需的队列指纹与游标字段。
  static Map<String, Object?> _cursorData(
    Map<String, dynamic> raw,
    String queueHash,
  ) => {
    'kind': _sessionCursorKind,
    'v': _sessionCursorVersion,
    'queueHash': queueHash,
    kPlaybackSessionSavedAtKey:
        (raw[kPlaybackSessionSavedAtKey] as num?)?.toInt() ?? 0,
    'index': (raw['index'] as num?)?.toInt() ?? 0,
    'positionMs': (raw['positionMs'] as num?)?.toInt() ?? 0,
    'mode': raw['mode'],
    'context': raw['context'],
  };

  /// 把游标增量合并进本地原始会话：tracks（含本地曲目）保持不动。
  static Map<String, dynamic> _mergeCursor(
    Map<String, dynamic> local,
    Map<String, Object?> cursor,
  ) {
    final merged = Map<String, dynamic>.from(local);
    merged[kPlaybackSessionSavedAtKey] =
        (cursor[kPlaybackSessionSavedAtKey] as num?)?.toInt() ?? 0;
    final positionMs = (cursor['positionMs'] as num?)?.toInt() ?? 0;
    merged['positionMs'] = positionMs < 0 ? 0 : positionMs;
    if (cursor['mode'] is String) merged['mode'] = cursor['mode'];
    if (cursor.containsKey('context')) merged['context'] = cursor['context'];
    final tracks = merged['tracks'];
    if (tracks is List && tracks.isNotEmpty) {
      final requested = (cursor['index'] as num?)?.toInt() ?? 0;
      merged['index'] = _localIndexForFiltered(tracks, requested);
    } else {
      merged['index'] = 0;
    }
    return merged;
  }

  /// 游标里的下标是**过滤本地曲目后**的位置；本机还留着本地下载曲目时，
  /// 要映射回原始列表，否则会指向另一首歌。越界按过滤后队列末尾兜底。
  static int _localIndexForFiltered(List<Object?> tracks, int filteredIndex) {
    final positions = <int>[
      for (var i = 0; i < tracks.length; i++)
        if (!_isLocalTrack(tracks[i])) i,
    ];
    if (positions.isEmpty) return 0;
    final index = filteredIndex < 0
        ? 0
        : (filteredIndex >= positions.length
              ? positions.length - 1
              : filteredIndex);
    return positions[index];
  }

  static bool _isLocalTrack(Object? track) =>
      track is Map && track['sourceKey'] == kLocalSourceKey;

  /// 过滤会话里的本地下载曲目（`sourceKey = local`），并按删除数校正下标。
  ///
  /// 无本地曲目时返回原 map；过滤后没有剩余曲目时返回 null（无可同步会话）。
  static Map<String, dynamic>? _withoutLocalTracks(Map<String, dynamic> raw) {
    final tracks = raw['tracks'];
    if (tracks is! List) return raw;
    final index = (raw['index'] as num?)?.toInt() ?? 0;
    final kept = <Object?>[];
    var removedBeforeIndex = 0;
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      if (_isLocalTrack(track)) {
        if (i < index) removedBeforeIndex++;
        continue;
      }
      kept.add(track);
    }
    if (kept.length == tracks.length) return raw;
    if (kept.isEmpty) return null;
    return {
      ...raw,
      'tracks': kept,
      'index': (index - removedBeforeIndex).clamp(0, kept.length - 1),
    };
  }
}
