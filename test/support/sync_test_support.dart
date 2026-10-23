import 'dart:async';

import 'package:molia/data/molia_database.dart';
import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/data/sync/statistics_sync_store.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/sync/sync_stamp.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/sync_nearby_pairing.dart';
import 'package:molia/domain/ports/library_sync_store.dart';
import 'package:molia/domain/ports/sync_pairing.dart';
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

/// 测试用统计同步存储：与仓储共用同一个内存库 / 发号器 / 日志。
SqliteStatisticsSyncStore testStatisticsSyncStore(
  MoliaDatabase Function() databaseProvider, {
  int Function()? clock,
  String deviceId = '',
  SyncJournalRepository? journal,
}) =>
    SqliteStatisticsSyncStore(
      databaseProvider: databaseProvider,
      stamps: testStampIssuer(clock: clock, deviceId: deviceId),
      journal: journal,
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

  /// pull 失败时报告的设备与原因（走名册的失败归属路径）。
  Map<String, SyncIssue> pullFailedIssues = const {};

  /// pull 被调用的次数（验证入站轮不拉取）。
  int pullCount = 0;

  /// pull 报告的原因（不伴随失败计数：验证传输级错误不被吞）。
  SyncIssue? pullError;

  /// push 失败时报告的对端 id（走名册失败路径）。
  List<String> pushFailedIds = const [];

  /// push 成功时报告的对端 id（走名册成功接触路径）。
  List<String> pushSucceededIds = const [];

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

  /// start 被调用的次数（验证幂等：重复调用不重启传输）。
  int startCount = 0;

  @override
  Future<void> start() async {
    startCount++;
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<SyncPullResult> pull(
      [SyncPullRequest request = SyncPullRequest.none]) async {
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
      failedIssues: pullFailedIssues,
      error: pullError ??
          (pullFailures > 0
              ? const SyncIssue(
                  code: SyncIssueCode.pullFailed, detail: '拉取失败（测试注入）')
              : null),
    );
  }

  @override
  Future<SyncPushResult> push(
    SyncEnvelope envelope, {
    SyncRoundWindow? window,
  }) async {
    pushed.add(envelope);
    if (pushFailures > 0) {
      return SyncPushResult(
        failedPeers: pushFailures,
        failedIds: pushFailedIds,
        error: const SyncIssue(
            code: SyncIssueCode.pushFailed, detail: '推送失败（测试注入）'),
      );
    }
    return SyncPushResult(
      succeededPeers: 1,
      succeededIds: List.of(pushSucceededIds),
    );
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

/// 带发现事件与局域网生命周期的假传输（引擎 / 控制面接线测试用）。
class FakeSightingTransport extends FakeSyncTransport
    implements SyncSightingSource, SyncLanLifecycle {
  FakeSightingTransport({super.kind, super.unavailableReason});

  final StreamController<LanPeerSighting> _sightings =
      StreamController<LanPeerSighting>.broadcast();

  int announceCalls = 0;
  int resumeCalls = 0;
  int hiddenCalls = 0;
  int networkChangedCalls = 0;

  @override
  Stream<LanPeerSighting> get sightings => _sightings.stream;

  void emitSighting(LanPeerSighting sighting) => _sightings.add(sighting);

  @override
  Future<void> announceLocalChange() async {
    announceCalls++;
  }

  @override
  Future<void> onAppResumed() async {
    resumeCalls++;
  }

  @override
  void onAppHidden() {
    hiddenCalls++;
  }

  @override
  Future<void> onNetworkChanged() async {
    networkChangedCalls++;
  }

  @override
  Future<void> stop() async {
    if (!_sightings.isClosed) await _sightings.close();
    await super.stop();
  }
}

/// 可控 head / base 的日志替身（重置 = 头部归零）。
class FakeJournalStore implements SyncJournalStore {
  FakeJournalStore({required this.head});

  int head;
  int base = 0;
  int snapshot = -1;

  /// reset 抛错（模拟清理失败）与尝试次数（验证下次启动重试）。
  bool throwOnReset = false;
  int resetCount = 0;

  @override
  Future<int> headSeq() async => head;

  @override
  Future<int> baseSeq() async => base;

  @override
  Future<int> snapshotSeq() async => snapshot;

  @override
  Future<SyncJournalStats> stats() async => SyncJournalStats(
        headSeq: head,
        baseSeq: base,
        snapshotSeq: snapshot,
        entries: head - base,
        bytes: 0,
        oldestAt: 0,
      );

  @override
  Future<List<SyncJournalEntry>> window(
          {int since = -1, int limit = 0}) async =>
      const [];

  @override
  Future<int> windowBytes({int since = -1}) async => 0;

  @override
  Future<void> markSnapshotBuilt(int seq) async {
    snapshot = seq;
  }

  @override
  Future<int> compact({
    required int minAck,
    required int coverage,
    int? nowMs,
  }) async =>
      base;

  @override
  Future<void> reset() async {
    resetCount++;
    if (throwOnReset) throw StateError('清理失败（测试注入）');
    head = 0;
    base = 0;
    snapshot = -1;
  }
}

/// 测试用附近设备配对端口：候选 / 请求 / 确认码都由用例手动驱动。
///
/// 默认 `probeAddress` 返回 false（手动地址回退到旧的「立即接触」路径），
/// 避免不关心配对的既有用例被新路径改变行为；需要验证附近设备的用例
/// 自行打开 [probeResult] 并 emit 候选项。
class FakeSyncPairingPort implements SyncPairingPort {
  final StreamController<List<SyncNearbyDevice>> _nearby =
      StreamController<List<SyncNearbyDevice>>.broadcast();
  final StreamController<SyncPairingRequest> _incoming =
      StreamController<SyncPairingRequest>.broadcast();
  final StreamController<SyncPairingAttempt> _attempts =
      StreamController<SyncPairingAttempt>.broadcast();

  /// 当前候选（[emitNearby] 会整体替换）。
  final List<SyncNearbyDevice> nearby = [];

  bool _scanning = false;

  @override
  bool get scanning => _scanning;

  @override
  bool hasGroup = false;

  /// startScan 的返回值（false = 后台 / 蜂窝 / 传输未运行）。
  bool startScanResult = true;

  int startScanCalls = 0;
  int stopScanCalls = 0;

  /// probeAddress 的返回值与调用记录。
  bool probeResult = false;
  final List<({String host, int probePort})> probes = [];

  /// requestPairing 的调用记录与可注入结局。
  final List<SyncNearbyDevice> requestedDevices = [];
  SyncPairingResult? requestResult;
  Object? requestError;
  Completer<SyncPairingResult>? _requestCompleter;

  /// respond 的返回值 / 挂起门（busy 态用例）。
  SyncPairingOutcome respondResult = SyncPairingOutcome.accepted;
  Completer<SyncPairingOutcome>? respondCompleter;
  final List<({String requestId, bool accept})> responses = [];

  final List<String> cancelledRequests = [];
  bool disposed = false;

  @override
  Stream<List<SyncNearbyDevice>> get nearbyDevices => _nearby.stream;

  @override
  Stream<SyncPairingRequest> get incomingRequests => _incoming.stream;

  @override
  Stream<SyncPairingAttempt> get attempts => _attempts.stream;

  @override
  Future<bool> startScan() async {
    startScanCalls++;
    if (!startScanResult) return false;
    _scanning = true;
    _emitNearby();
    return true;
  }

  @override
  Future<bool> probeAddress(String host, {int probePort = 0}) async {
    probes.add((host: host, probePort: probePort));
    return probeResult;
  }

  @override
  void stopScan() {
    stopScanCalls++;
    _scanning = false;
    nearby.clear();
    _emitNearby();
  }

  @override
  Future<SyncPairingResult> requestPairing(SyncNearbyDevice device) {
    requestedDevices.add(device);
    final error = requestError;
    if (error != null) return Future.error(error);
    final immediate = requestResult;
    if (immediate != null) return Future.value(immediate);
    return (_requestCompleter ??= Completer<SyncPairingResult>()).future;
  }

  @override
  Future<SyncPairingOutcome> respond(
    String requestId, {
    required bool accept,
  }) {
    responses.add((requestId: requestId, accept: accept));
    final gate = respondCompleter;
    if (gate != null) return gate.future;
    return Future.value(respondResult);
  }

  @override
  Future<void> cancelPairing(String requestId) async {
    cancelledRequests.add(requestId);
    completeRequest(
      const SyncPairingResult(outcome: SyncPairingOutcome.cancelled),
    );
  }

  void emitNearby(List<SyncNearbyDevice> devices) {
    nearby
      ..clear()
      ..addAll(devices);
    _emitNearby();
  }

  void emitAttempt(SyncPairingAttempt attempt) => _attempts.add(attempt);

  void emitIncoming(SyncPairingRequest request) => _incoming.add(request);

  void completeRequest(SyncPairingResult result) {
    final completer = _requestCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.complete(result);
    _requestCompleter = null;
  }

  void completeRespond(SyncPairingOutcome outcome) {
    final completer = respondCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.complete(outcome);
    respondCompleter = null;
  }

  void _emitNearby() {
    if (!_nearby.isClosed) _nearby.add(List.unmodifiable(nearby));
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _nearby.close();
    await _incoming.close();
    await _attempts.close();
  }
}
