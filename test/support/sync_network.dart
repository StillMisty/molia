import 'dart:async';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/history_sync_adapter.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'memory_database.dart';
import 'sync_test_support.dart';

/// 测试用同步网络：多台设备用**真实编解码**交换增量窗口 / 全量快照。
///
/// 服务端语义对齐局域网直连的 `GET /journal?since=`：
/// - 游标在窗口内（`since >= baseSeq`）→ 返回该游标之后的增量窗口；
/// - 游标落后于窗口起点（或引擎显式要求全量）→ 返回全量快照（bootstrap）。
///
/// 加密 / 解密次数与传输字节数在 [SyncNetwork] 上统计：验收断言
/// 「解密次数与字节数恒定，不随库大小变化」用它。
class SyncNetwork {
  SyncNetwork({required this.passphrase, this.limits = const SyncJournalLimits()}) {
    // 多设备各自一个内存库：不是「同一执行器被重复打开」，无需告警。
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  }

  final String passphrase;
  final SyncJournalLimits limits;

  /// 迭代数调低：测试只关心协议路径，不需要真实口令强度。
  final SyncCodec codec = SyncCodec(iterations: 1000);

  final Map<String, SyncDevice> devices = {};

  int encryptions = 0;
  int decryptions = 0;
  int bytesTransferred = 0;

  /// 拉取方向的分对端统计：载荷字节与解密次数（验收断言「各拉 1 次增量、
  /// 字节数不随库大小变化」用它）。
  final Map<String, int> pullBytesByPeer = {};
  final Map<String, int> pullDecryptionsByPeer = {};

  /// 服务端按 bootstrap（全量快照）/ 增量窗口分别应答的次数。
  int bootstrapServed = 0;
  int deltaServed = 0;

  void resetCounters() {
    encryptions = 0;
    decryptions = 0;
    bytesTransferred = 0;
    bootstrapServed = 0;
    deltaServed = 0;
    pullBytesByPeer.clear();
    pullDecryptionsByPeer.clear();
  }

  Future<SyncDevice> addDevice(
    String id, {
    SyncJournalLimits? deviceLimits,
    List<SettingsKey<Object?>> keys = const [kThemeMode],
    int Function()? clock,
  }) async {
    final db = openMemoryDatabase();
    final device = SyncDevice._(
      network: this,
      id: id,
      db: db,
      limits: deviceLimits ?? limits,
      keys: keys,
      clock: clock,
    );
    devices[id] = device;
    await device.init();
    return device;
  }

  Future<void> dispose() async {
    for (final device in devices.values) {
      device.engine.dispose();
      await device.db.close();
    }
    devices.clear();
  }
}

/// 网络里的一台设备：状态存储 + 增量日志 + 设置适配器 + 引擎 + 传输。
class SyncDevice {
  SyncDevice._({
    required this.network,
    required this.id,
    required this.db,
    required SyncJournalLimits limits,
    required List<SettingsKey<Object?>> keys,
    int Function()? clock,
  })  : _limits = limits,
        _keys = keys,
        _clock = clock;

  final SyncNetwork network;
  final String id;
  final MoliaDatabase db;
  final SyncJournalLimits _limits;
  final List<SettingsKey<Object?>> _keys;
  final int Function()? _clock;

  late final SharedPreferences prefs;
  late final SyncStateStore state;
  late final SyncJournalRepository journal;
  late final SettingsRegistry settings;
  late final PrefsSyncAdapter settingsAdapter;
  late final LibraryRepository library;
  late final HistorySyncAdapter historyAdapter;
  late final NetworkTransport transport;
  late final SyncEngine engine;

  Future<void> init() async {
    // 每台设备一份独立的前缀存储（先重置静态缓存再取实例）。
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      deviceId: id,
      clock: _clock,
    );
    await state.init();
    await state.writePassphrase(network.passphrase);
    await state.setEnabled(true);
    journal = SyncJournalRepository(
      databaseProvider: () => db,
      limits: _limits,
      clock: _clock,
    );
    settings = SettingsRegistry(
      keys: _keys,
      preferences: prefs,
      secrets: secrets,
    );
    settingsAdapter = PrefsSyncAdapter(
      state: state,
      settings: settings,
      journal: journal,
    );
    library = LibraryRepository(
      databaseProvider: () => db,
      clock: () => state.nowMs(),
      stamps: state.stampIssuer,
      journal: journal,
    );
    historyAdapter = HistorySyncAdapter(repository: library);
    transport = NetworkTransport(this);
    engine = SyncEngine(
      state: state,
      adapters: [settingsAdapter, historyAdapter],
      transports: {SyncTransportKind.lan: transport},
      stamps: state.stampIssuer,
      journal: journal,
      clock: () => DateTime.fromMillisecondsSinceEpoch(state.nowMs()),
      inboundWindow: const Duration(milliseconds: 10),
    );
    await engine.init();
  }

  /// 直接写设置键（模拟用户操作；变化由下一轮的登记哈希检测并追加日志）。
  Future<void> setSetting(String key, Object? value) =>
      settings.writeRaw(_keyOf(key), value);

  SettingsKey<Object?> _keyOf(String name) =>
      _keys.firstWhere((key) => key.name == name);

  /// 服务端语义：按请求游标返回增量窗口或全量快照（bootstrap）。
  ///
  /// 走引擎的 [SyncEngine.serveJournal]（与局域网端点同一实现）；显式要求
  /// 全量时直接给最近一轮的全量快照。
  Future<SyncEnvelope> serve({required int since, required bool full}) async {
    final baseSeq = await journal.baseSeq();
    if (full || since < baseSeq) {
      network.bootstrapServed++;
      return engine.serveSnapshot();
    }
    network.deltaServed++;
    return engine.serveJournal(since: since);
  }

  Future<void> receive(SyncEnvelope envelope) async {
    await engine.onIncomingEnvelope(envelope);
  }
}

/// 测试用传输：pull 按游标取各对端载荷，push 投递到对端入站流（真实加解密）。
class NetworkTransport implements SyncTransport {
  NetworkTransport(this.device);

  final SyncDevice device;
  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();
  bool _running = false;

  @override
  String get kind => SyncTransportKind.lan;

  @override
  bool get isRunning => _running;

  @override
  ({int v4, int v6}) get discoveryPorts => (v4: 0, v6: 0);

  /// 测试网络模拟局域网直连（按需实时快照）。
  @override
  bool get servesLiveSnapshot => true;

  @override
  String? get unavailableReason => null;

  @override
  String? get unavailableDetail => null;

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;

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
    final envelopes = <SyncEnvelope>[];
    var bytesIn = 0;
    for (final peer in device.network.devices.values) {
      if (peer.id == device.id) continue;
      final payload = await peer.serve(
        since: request.cursorFor(peer.id),
        full: request.fullPeers.contains(peer.id),
      );
      final bytes = device.network.codec.encrypt(
        payload,
        device.network.passphrase,
      );
      device.network.encryptions++;
      device.network.bytesTransferred += bytes.length;
      device.network.pullBytesByPeer[peer.id] =
          (device.network.pullBytesByPeer[peer.id] ?? 0) + bytes.length;
      device.network.pullDecryptionsByPeer[peer.id] =
          (device.network.pullDecryptionsByPeer[peer.id] ?? 0) + 1;
      envelopes.add(
        device.network.codec.decrypt(bytes, device.network.passphrase),
      );
      device.network.decryptions++;
      bytesIn += bytes.length;
    }
    return SyncPullResult(
      envelopes: envelopes,
      peersSeen: device.network.devices.length - 1,
      bytesIn: bytesIn,
      contacted: true,
    );
  }

  @override
  Future<SyncPushResult> push(SyncEnvelope envelope) async {
    final bytes = device.network.codec.encrypt(envelope, device.network.passphrase);
    device.network.encryptions++;
    device.network.bytesTransferred += bytes.length;
    var delivered = 0;
    for (final peer in device.network.devices.values) {
      if (peer.id == device.id) continue;
      await peer.receive(
        device.network.codec.decrypt(bytes, device.network.passphrase),
      );
      device.network.decryptions++;
      delivered++;
    }
    return SyncPushResult(
      succeededPeers: delivered,
      bytesOut: bytes.length * delivered,
      succeededIds: [
        for (final peer in device.network.devices.values)
          if (peer.id != device.id) peer.id,
      ],
    );
  }

  @override
  Future<bool> deleteRemote(String deviceId) async => false;
}

/// 名册里指定对端的状态（缺失时报错，便于断言）。
SyncPeerState peerOf(SyncDevice device, String peerId) =>
    device.state.peers.firstWhere((peer) => peer.deviceId == peerId);

/// 直插数据库的辅助（构造「存量数据」：不进增量日志，只影响全量快照体积）。
Future<void> seedHistoryRows(MoliaDatabase db, int count, {int from = 0}) async {
  await db.batch((batch) {
    batch.insertAll(
      db.playHistory,
      [
        for (var i = from; i < from + count; i++)
          PlayHistoryCompanion.insert(
            sourceKey: 'kuwo',
            songId: 'seed-$i',
            title: '存量歌曲 $i',
            playedAt: i,
            raw: const Value('{"seed":true}'),
          ),
      ],
    );
  });
}
