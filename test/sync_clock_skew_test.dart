import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/sync/adapters/playlist_sync_adapter.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 双实例集成（#28 的核心证据）：**A 的时钟快 365 天，B 之后的编辑仍被 A 采纳**。
///
/// 首版实现（版本戳 = 设备墙上时钟）这条用例必然失败：B 的戳永远小于 A 的
/// 超前戳，A 会把自己的旧值当成「更新」而丢弃 B 的编辑。v2 的 HLC-lite 让 B
/// 在拉取 A 的快照时吸收 A 的超前戳，下一次写入严格大于它，于是全组收敛。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';

  late SharedPreferences prefsA;
  late SharedPreferences prefsB;
  late SyncStateStore stateA;
  late SyncStateStore stateB;
  late MoliaDatabase dbA;
  late MoliaDatabase dbB;
  late LibraryRepository repoA;
  late LibraryRepository repoB;
  late SyncEngine engineA;
  late SyncEngine engineB;
  late FakeSyncTransport transportA;
  late FakeSyncTransport transportB;

  /// 独立的前缀存储：每台设备一份（先重置静态缓存再取实例）。
  ///
  /// 注意：`setMockInitialValues` 会替换全局存储，之后设备 A 的 `save()` 也会
  /// 落到设备 B 的存储上——但本测试不跨设备重读状态（各 state 的内存视图与
  /// 自己的 prefs 缓存才是读取来源），因此不影响隔离。
  Future<SharedPreferences> freshPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  setUp(() async {
    dbA = openMemoryDatabase();
    dbB = openMemoryDatabase();

    prefsA = await freshPrefs();
    final secretsA = MemorySyncSecretStore();
    // A 的钟快 365 天：版本戳（和服务名册的时钟偏移）都超前。
    final aheadNow = DateTime.now().add(const Duration(days: 365));
    stateA = SyncStateStore(
      preferences: prefsA,
      secrets: secretsA,
      clock: () => aheadNow.millisecondsSinceEpoch,
      deviceId: 'device-a',
    );
    await stateA.init();
    await stateA.writePassphrase(passphrase);
    await stateA.setEnabled(true);

    prefsB = await freshPrefs();
    final secretsB = MemorySyncSecretStore();
    stateB = SyncStateStore(
      preferences: prefsB,
      secrets: secretsB,
      clock: () => DateTime.now().millisecondsSinceEpoch,
      deviceId: 'device-b',
    );
    await stateB.init();
    await stateB.writePassphrase(passphrase);
    await stateB.setEnabled(true);

    repoA = LibraryRepository(
      databaseProvider: () => dbA,
      deviceIdProvider: () => stateA.deviceId,
      clock: () => stateA.nowMs(),
      stampIssuer: stateA.stampIssuer,
    );
    repoB = LibraryRepository(
      databaseProvider: () => dbB,
      deviceIdProvider: () => stateB.deviceId,
      clock: () => stateB.nowMs(),
      stampIssuer: stateB.stampIssuer,
    );
    // 发号器基线 ≧ 全库最大戳（组合根的接线在测试里显式复现）。
    stateA.stampIssuer.seed(await repoA.maxVersion());
    stateB.stampIssuer.seed(await repoB.maxVersion());

    transportA = FakeSyncTransport();
    transportB = FakeSyncTransport();
    engineA = SyncEngine(
      state: stateA,
      adapters: [PlaylistSyncAdapter(repository: repoA)],
      transports: {'lan': transportA},
      clock: () => DateTime.fromMillisecondsSinceEpoch(stateA.nowMs()),
      stamps: stateA.stampIssuer,
    );
    engineB = SyncEngine(
      state: stateB,
      adapters: [PlaylistSyncAdapter(repository: repoB)],
      transports: {'lan': transportB},
      clock: () => DateTime.fromMillisecondsSinceEpoch(stateB.nowMs()),
      stamps: stateB.stampIssuer,
    );
    await engineA.init();
    await engineB.init();
  });

  tearDown(() async {
    engineA.dispose();
    engineB.dispose();
    await repoA.dispose();
    await repoB.dispose();
    await dbA.close();
    await dbB.close();
  });

  test('A 时钟 +365 天：B 的编辑仍被 A 采纳（HLC 吸收超前戳）', () async {
    // 1) A 建歌单：版本戳 = A 的超前时钟。
    await repoA.createPlaylist('歌单');
    final aRecord = (await repoA.syncExportPlaylists())
        .firstWhere((playlist) => playlist.name == '歌单');
    final aVersion = aRecord.version;
    expect(
      aVersion.physical,
      greaterThan(DateTime.now().millisecondsSinceEpoch),
      reason: 'A 的版本戳来自快 365 天的时钟',
    );

    // 2) A 跑一轮拿到快照（没有对端也能产出推送视图）。
    await engineA.syncNow();
    final envA = engineA.lastEnvelope!;
    expect(envA.isSupported, isTrue);

    // 3) B 拉取 A 的快照：吸收超前戳 + 落地歌单。
    transportB.available.add(envA);
    final reportB = await engineB.syncNow();
    expect(reportB!.applied, 1);
    final playlistInB = await repoB.findPlaylistByName('歌单');
    expect(playlistInB, isNotNull);

    // 4) B 用**正常时钟**改名：版本戳被发号器抬到 A 的超前戳之上。
    await repoB.renamePlaylist(playlistInB!.id, 'B 改名');
    await engineB.syncNow();
    final bRecord = engineB
        .lastEnvelope!
        .recordsOf(SyncCategory.playlists)
        .firstWhere((record) => record.key == aRecord.syncId);
    final bVersion = bRecord.version;
    expect(
      bVersion.physical,
      aVersion.physical,
      reason: '吸收：B 的物理分量跟到 A 的超前值',
    );
    expect(
      bVersion.counter,
      greaterThan(aVersion.counter),
      reason: '同物理值内 counter 递增 → 严格更大',
    );
    expect(bVersion.isNewerThan(aVersion), isTrue);
    // 若按「B 的墙上时钟」发戳，B 的编辑会输给 A（这条用例在首版必失败）。
    expect(
      bVersion.physical,
      greaterThan(DateTime.now().millisecondsSinceEpoch),
      reason: 'B 的戳不是 B 的墙上时钟（被超前戳抬高）',
    );

    // 5) A 拉取 B 的编辑：B 的版本更大 → A 采纳。
    transportA.available.add(engineB.lastEnvelope!);
    final reportA = await engineA.syncNow();
    expect(reportA!.applied, 1);
    expect(
      await repoA.findPlaylistByName('B 改名'),
      isNotNull,
      reason: 'B 的编辑传播到 A 并被采纳',
    );
    expect(await repoA.findPlaylistByName('歌单'), isNull);

    // A 的名册把对端时钟偏移呈现出来（B 的 producedAt 比 A 的时钟小很多）。
    final peer = reportA.peers.firstWhere((p) => p.deviceId == 'device-b');
    expect(peer.clockSkewMs, isNotNull);
    expect(peer.clockSkewMs!, isNegative, reason: 'A 的钟快 → 偏移为负');
  });

  test('反向：B 的编辑先到、A 再改，A 的（吸收后的）修订仍胜出', () async {
    // A 建歌单并同步给 B。
    await repoA.createPlaylist('歌单');
    await engineA.syncNow();
    transportB.available.add(engineA.lastEnvelope!);
    await engineB.syncNow();

    // B 改名（版本 = A 超前戳 + 1）。
    final inB = await repoB.findPlaylistByName('歌单');
    await repoB.renamePlaylist(inB!.id, 'B 改名');
    await engineB.syncNow();
    final bEnvelope = engineB.lastEnvelope!;

    // A 先吸收 B 的版本再改名：A 的新版本严格大于 B 的。
    transportA.available.add(bEnvelope);
    await engineA.syncNow();
    final inA = await repoA.findPlaylistByName('B 改名');
    expect(inA, isNotNull);
    await repoA.renamePlaylist(inA!.id, 'A 再改');
    await engineA.syncNow(); // 刷新 A 的推送视图（含改名后的版本）

    // B 拉取 A 的最新视图：A 的修订胜出。
    transportB.available
      ..clear()
      ..add(engineA.lastEnvelope!);
    await engineB.syncNow();
    expect(await repoB.findPlaylistByName('A 再改'), isNotNull);
    expect(await repoB.findPlaylistByName('B 改名'), isNull);

    // 双方收敛到同一名字。
    expect(engineA.lastEnvelope, isNotNull);
    expect(
      (await repoA.syncExportPlaylists()).firstWhere((p) => p.name == 'A 再改'),
      isNotNull,
    );
  });
}
