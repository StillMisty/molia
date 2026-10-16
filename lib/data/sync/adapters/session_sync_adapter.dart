import '../../../domain/models/device_sync.dart';
import '../../../domain/models/download.dart' show kLocalSourceKey;
import '../../../services/playback_session_store.dart';
import '../sync_adapter.dart';
import '../sync_state_store.dart';

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
    required PlaybackSessionStore store,
    required SyncStateStore state,
    Future<void> Function()? onChanged,
  })  : _store = store,
        _state = state,
        _onChanged = onChanged;

  final PlaybackSessionStore _store;
  final SyncStateStore _state;
  final Future<void> Function()? _onChanged;

  @override
  Set<SyncCategory> get categories => const {SyncCategory.session};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async {
    final loaded = await _store.loadRaw();
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

    final savedAt =
        (raw[PlaybackSessionStore.savedAtKey] as num?)?.toInt() ?? 0;
    final hash = '$savedAt';
    final SyncStamp effective;
    if (stamp == null || stamp.hash != hash) {
      // 功能上线前的存量会话没有 savedAt：零值戳（让新会话胜出），
      // 下次保存带来 savedAt 后自然参与 LWW。
      final version = savedAt > 0 ? _state.stampIssuer.next() : SyncVersion.zero;
      effective = SyncStamp(hash: hash, version: version);
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

    final stamp = _state.sessionStamp;
    if (stamp != null && !record.version.isNewerThan(stamp.version)) {
      return const SyncApplyOutcome(applied: 0, skipped: 1);
    }

    if (record.deleted) {
      await _store.clear();
      _state.setSessionStamp(SyncStamp(version: record.version));
    } else {
      final data = record.data;
      if (data == null || data.isEmpty) {
        return const SyncApplyOutcome(applied: 0, skipped: 1);
      }
      await _store.saveRaw(data.map((k, v) => MapEntry(k.toString(), v)));
      final savedAt =
          (data[PlaybackSessionStore.savedAtKey] as num?)?.toInt() ?? 0;
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
