import 'dart:async';

import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/data/sync/sync_stamp.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/library_sync_store.dart';
import 'package:molia/domain/ports/sync_transport.dart';

/// 测试用发号器（固定/可注入时钟 + 设备 id）：给不关心同步语义的仓库测试用。
SyncStampIssuer testStampIssuer({
  int Function()? clock,
  String deviceId = '',
}) =>
    SyncStampIssuer(
      clock: clock ?? () => DateTime.now().millisecondsSinceEpoch,
      deviceId: () => deviceId,
    );

/// 测试用内存密钥存储（替代 flutter_secure_storage）。
class MemorySyncSecretStore implements SettingsSecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// 资料库同步面的计数包装：统计导出调用次数（验证指纹门控不读行）。
class CountingLibrarySyncStore implements LibrarySyncStore {
  CountingLibrarySyncStore(this.delegate);

  final LibrarySyncStore delegate;
  int exportCalls = 0;
  int fingerprintCalls = 0;

  @override
  Future<List<PlaylistSyncRecord>> syncExportPlaylists() {
    exportCalls++;
    return delegate.syncExportPlaylists();
  }

  @override
  Future<List<PlaylistTrackSyncRecord>> syncExportPlaylistTracks() {
    exportCalls++;
    return delegate.syncExportPlaylistTracks();
  }

  @override
  Future<List<PlayHistorySyncRecord>> syncExportHistory() {
    exportCalls++;
    return delegate.syncExportHistory();
  }

  @override
  Future<List<SyncTombstoneRecord>> syncExportTombstones(
    Iterable<String> categories,
  ) {
    exportCalls++;
    return delegate.syncExportTombstones(categories);
  }

  @override
  Future<Map<SyncCategory, String>> syncFingerprints(
    Iterable<SyncCategory> categories,
  ) {
    fingerprintCalls++;
    return delegate.syncFingerprints(categories);
  }

  @override
  Future<({int applied, int skipped})> syncApplyLibrary({
    List<PlaylistSyncRecord> playlists = const [],
    List<PlaylistTrackSyncRecord> tracks = const [],
    List<SyncTombstoneRecord> tombstones = const [],
  }) =>
      delegate.syncApplyLibrary(
        playlists: playlists,
        tracks: tracks,
        tombstones: tombstones,
      );

  @override
  Future<({int applied, int skipped})> syncApplyHistory({
    List<PlayHistorySyncRecord> entries = const [],
    List<SyncTombstoneRecord> tombstones = const [],
  }) =>
      delegate.syncApplyHistory(entries: entries, tombstones: tombstones);
}

/// 测试用内存传输：可注入远端快照、失败计数与不可用原因，并记录推送内容。///
/// 默认把「可用快照数」当作本轮探测到的对端数（有快照 = 见过一个对端），
/// 需要构造「探测到对端但没拿到数据」时用 [peersSeenOverride]。
class FakeSyncTransport implements SyncTransport {
  FakeSyncTransport({this.kind = 'lan', this.unavailableReason});

  @override
  final String kind;

  @override
  String? unavailableReason;

  @override
  String? unavailableDetail;

  bool _running = false;
  final List<SyncEnvelope> available = [];
  final List<SyncEnvelope> pushed = [];
  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();

  /// 覆盖 pull 报告的探测对端数（null = 用 [available] 长度）。
  int? peersSeenOverride;

  /// pull 报告的「内容未变而跳过」对端数。
  int pullSkippedUnchanged = 0;

  /// pull 报告的「接触成功」（远端可达；零快照也算，如 WebDAV 目录可读）。
  bool pullContacted = false;

  /// pull 报告「接触过」的对端 id（null = 由 [available] 推导）。
  List<String>? seenIdsOverride;

  /// pull / push 报告的失败数（用于构造部分失败与全失败）。
  int pullFailures = 0;
  int pushFailures = 0;

  /// pull 被调用的次数（验证入站轮不拉取）。
  int pullCount = 0;

  /// pull 报告的原因（不伴随失败计数：验证传输级错误不被吞）。
  SyncIssue? pullError;

  /// push 失败时报告的对端 id（走名册失败路径）。
  List<String> pushFailedIds = const [];

  /// pull 前执行的钩子（模拟传输侧学到手动对端身份等）。
  Future<void> Function()? onPull;

  /// 最近一次 pull 收到的请求（断言游标 / 全量兜底对端）。
  SyncPullRequest? lastRequest;

  /// pull 抛异常（模拟传输层崩溃）。
  bool throwOnPull = false;

  @override
  bool get isRunning => _running;

  /// 假传输模拟局域网，但测试不关心发现端口（可注入分族端口验证展示）。
  ({int v4, int v6}) discoveryPortsOverride = (v4: 0, v6: 0);

  @override
  ({int v4, int v6}) get discoveryPorts => discoveryPortsOverride;

  /// 假传输模拟局域网（按需实时快照）。
  @override
  bool get servesLiveSnapshot => true;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<SyncPullResult> pull([SyncPullRequest request = SyncPullRequest.none]) async {
    pullCount++;
    lastRequest = request;
    await onPull?.call();
    if (throwOnPull) throw StateError('拉取失败（测试注入）');
    return SyncPullResult(
      envelopes: List.of(available),
      peersSeen: peersSeenOverride ?? available.length,
      skippedUnchanged: pullSkippedUnchanged,
      failedPeers: pullFailures,
      contacted: pullContacted,
      seenIds: seenIdsOverride ??
          [
            for (final envelope in available)
              if (envelope.deviceId.isNotEmpty) envelope.deviceId,
          ],
      error: pullError ??
          (pullFailures > 0
              ? const SyncIssue(
                  code: SyncIssueCode.pullFailed, detail: '拉取失败（测试注入）')
              : null),
    );
  }

  @override
  Future<SyncPushResult> push(SyncEnvelope envelope) async {
    pushed.add(envelope);
    if (pushFailures > 0) {
      return SyncPushResult(
        failedPeers: pushFailures,
        failedIds: pushFailedIds,
        error: const SyncIssue(
            code: SyncIssueCode.pushFailed, detail: '推送失败（测试注入）'),
      );
    }
    return const SyncPushResult(succeededPeers: 1);
  }

  /// deleteRemote 的结果（默认 false：没有可清理的远端文件）。
  bool deleteRemoteResult = false;

  /// deleteRemote 抛错（模拟服务端拒绝 / 网络故障）。
  bool deleteRemoteThrows = false;
  final List<String> deletedRemotes = [];

  @override
  Future<bool> deleteRemote(String deviceId) async {
    deletedRemotes.add(deviceId);
    if (deleteRemoteThrows) {
      throw StateError('清理失败（测试注入）');
    }
    return deleteRemoteResult;
  }

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;

  /// 模拟对端主动推送。
  void emitIncoming(SyncEnvelope envelope) => _incoming.add(envelope);
}
