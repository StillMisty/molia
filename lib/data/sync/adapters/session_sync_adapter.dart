import '../../../domain/models/device_sync.dart';
import '../../../domain/models/download.dart' show kLocalSourceKey;
import '../../../domain/ports/playback_session_sync.dart';
import '../sync_adapter.dart';
import '../sync_book.dart';
import '../sync_journal.dart';
import '../sync_stamp.dart';

/// 上次播放会话适配器：把「上次播放的队列 + 下标 + 进度 + 模式」带到其它设备
/// （换设备接着听的轻量版，非实时控制）。
///
/// - 记录键固定 [SyncRecordKeys.sessionKey]；`savedAt`（会话写入时间）是内容
///   时间，版本戳在内容变化时向发号器现取；正在播放的设备持续刷新从而抢占；
/// - **本地清空不回传删除**：会话是「最近活动」的指针，停止播放只影响本机；
///   远端更新的会话（版本更大）到达时仍会重新填充；
/// - 应用后经 [onChanged] 让播放器重载恢复态（仅在没有真实播放时生效）。
class SessionSyncAdapter implements SyncAdapter {
  SessionSyncAdapter({
    required PlaybackSessionSyncPort port,
    required SyncStampLedger state,
    SyncJournalAppender? journal,
    Future<void> Function()? onChanged,
  })  : _port = port,
        _state = state,
        _journal = journal,
        _onChanged = onChanged;

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

  @override
  Set<SyncCategory> get categories => const {SyncCategory.session};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect(
      {bool fresh = false}) async {
    final loaded = await _port.loadRaw();
    // 本地下载曲目不同步：文件是设备本机的持久副本，其它设备无法播放。
    final raw = loaded == null ? null : _withoutLocalTracks(loaded);
    if (loaded != null && raw == null) {
      // 会话里全是本地曲目：没有可同步内容，也不回传删除。
      return const {};
    }
    final stamp = _state.sessionStamp;
    if (raw == null) {
      // 本地会话被清空（停止播放）：不回传删除；保持登记不变，
      // 远端版本更大的会话仍可在后续轮次重新填充。
      if (stamp == null) {
        _state.setSessionStamp(const SyncStamp());
      }
      return const {};
    }

    final savedAt = (raw[kPlaybackSessionSavedAtKey] as num?)?.toInt() ?? 0;
    final hash = '$savedAt';
    final SyncStamp effective;
    if (stamp == null || stamp.hash != hash) {
      // 没有 savedAt 的存量会话：零值戳（让新会话胜出），
      // 下次保存带来 savedAt 后自然参与 LWW。
      final version =
          savedAt > 0 ? _state.stampIssuer.next() : SyncVersion.zero;
      effective = SyncStamp(hash: hash, version: version);
      // 首次登记不是变更（初始视图由全量快照覆盖）；真实变化追加日志。
      // 登记必须在追加成功后才写：追加失败时保留旧登记，下一轮重新检测。
      final journal = _journal;
      if (journal != null && stamp != null) {
        await journal.appendAll([
          (
            category: SyncCategory.session,
            record: SyncRecord(
              key: SyncRecordKeys.sessionKey,
              version: effective.version,
              data: raw,
            ),
          ),
        ]);
      }
      _state.setSessionStamp(effective);
    } else {
      effective = stamp;
    }
    return {
      SyncCategory.session: [
        SyncRecord(
          key: SyncRecordKeys.sessionKey,
          version: effective.version,
          data: raw,
        ),
      ],
    };
  }

  /// 本机保存会话（组合根在会话存储的保存回调上接线）：**立即**登记并追加
  /// 日志，写入后进程被杀也不丢这次变更。
  ///
  /// 合并窗口内的高频进度保存只登记一次：会话载荷是整份队列（体积远大于其它
  /// 类别），每次保存都追加会把日志硬上限撑爆；窗口外的变更由下一轮统一登记
  /// （哈希检测），两者互为兜底。
  Future<void> noteLocalSave() async {
    final now = _state.nowMs();
    if (_lastImmediateAppendAt > 0 &&
        now - _lastImmediateAppendAt < immediateWindowMs) {
      return;
    }
    final loaded = await _port.loadRaw();
    final raw = loaded == null ? null : _withoutLocalTracks(loaded);
    if (loaded != null && raw == null) return;
    final stamp = _state.sessionStamp;
    if (raw == null) {
      if (stamp == null) _state.setSessionStamp(const SyncStamp());
      return;
    }
    final savedAt = (raw[kPlaybackSessionSavedAtKey] as num?)?.toInt() ?? 0;
    final hash = '$savedAt';
    if (stamp != null && stamp.hash == hash) return;
    final version = savedAt > 0 ? _state.stampIssuer.next() : SyncVersion.zero;
    final journal = _journal;
    if (journal != null && stamp != null) {
      // 先追加、后登记：追加失败时不写登记也不推进合并窗口，下次保存重试。
      await journal.appendAll([
        (
          category: SyncCategory.session,
          record: SyncRecord(
            key: SyncRecordKeys.sessionKey,
            version: version,
            data: raw,
          ),
        ),
      ]);
    }
    _state.setSessionStamp(SyncStamp(hash: hash, version: version));
    _lastImmediateAppendAt = now;
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    final list = records[SyncCategory.session] ?? const <SyncRecord>[];
    SyncRecord? record;
    for (final item in list) {
      if (item.key == SyncRecordKeys.sessionKey) {
        record = item;
        break;
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
    } else {
      if (data == null || data.isEmpty) {
        return const SyncApplyOutcome(applied: 0, skipped: 1);
      }
      await _port.applyRemote(data.map((k, v) => MapEntry(k.toString(), v)));
      _state.setSessionStamp(SyncStamp(
        hash: '$savedAt',
        version: record.version,
      ));
    }
    final changed = _onChanged;
    if (changed != null) await changed();
    return const SyncApplyOutcome(applied: 1);
  }

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
      final isLocal = track is Map && track['sourceKey'] == kLocalSourceKey;
      if (isLocal) {
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
