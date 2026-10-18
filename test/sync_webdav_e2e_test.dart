import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/domain/ports/sync_transport.dart';

import 'support/fake_webdav_server.dart';
import 'support/sync_network.dart';

/// 多设备端到端：真实 WebDAV 传输（块 / 回执 / 裁剪在真实 HTTP 上跑一遍）
/// + 真实增量日志与 worker 编解码端口。覆盖「块布局 + 游标 + ack + compact」
/// 咬合的地方——传输单测与引擎单测各测一半，咬合处只在这里验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';

  late FakeWebDavServer server;
  late SyncNetwork network;
  HttpOverrides? savedOverrides;

  setUpAll(() {
    // flutter_test 默认装「拦截真实 HTTP（一律 400）」的 HttpOverrides；
    // 本测试跑真实 HTTP 到本机假 DAV 服务。
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    HttpOverrides.global = savedOverrides;
  });

  setUp(() async {
    server = FakeWebDavServer();
    await server.start();
    network = SyncNetwork(passphrase: passphrase, webdavBaseUrl: server.baseUrl);
  });

  tearDown(() async {
    await network.dispose();
    await server.stop();
  });

  test('两台设备经 WebDAV 收敛：一次变更一个块、回执往返、无旧命名', () async {
    final a = await network.addDevice('devA', kind: SyncTransportKind.webdav);
    final b = await network.addDevice('devB', kind: SyncTransportKind.webdav);
    expect(a.transport.kind, SyncTransportKind.webdav);

    // 首轮：A 发布快照（bootstrap 用）+ 回执；此时还没有增量块。
    await a.engine.syncNow();
    expect(server.files.keys, contains('devA.acks.msync'));
    expect(_names(server, 'devA', '.snapshot.msync'), hasLength(1));
    expect(_names(server, 'devA', '.chunk.msync'), isEmpty);

    // B 首次引导（读快照）→ 收敛；
    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(b.prefs.getString('theme_mode'), 'dark');

    // 后续两次变更：每次只新增一个块（旧块与快照都不重写）。
    for (final value in ['light', 'dark']) {
      await a.setSetting('theme_mode', value);
      await a.engine.syncNow();
      await b.engine.syncNow();
      expect(b.prefs.getString('theme_mode'), value);
    }
    final chunks = _names(server, 'devA', '.chunk.msync').toList()..sort();
    expect(chunks, hasLength(3), reason: '一次变更一个块（不是整窗重写）');
    expect(_names(server, 'devA', '.snapshot.msync'), hasLength(1),
        reason: '快照只在引导 / 硬上限重写时发布');

    // 回执往返：A 的名册里学到 B 已消费到哪（对端 ack 进入 ackedSeq）。
    for (var i = 0; i < 2; i++) {
      await a.engine.syncNow();
      await b.engine.syncNow();
    }
    final peer = a.state.peers.firstWhere((item) => item.deviceId == 'devB');
    expect(peer.ackedSeq, greaterThan(0), reason: 'B 的 ack 经回执文件回到 A');
    expect(await a.journal.headSeq(), 3);

    // 命名只有 v3 形态（没有旧命名残留）。
    for (final name in server.files.keys) {
      expect(
        name.endsWith('.acks.msync') ||
            name.endsWith('.chunk.msync') ||
            name.endsWith('.snapshot.msync'),
        isTrue,
        reason: '意外文件：$name',
      );
    }
  });

  test('落后超出窗口：硬上限重写快照 → 对端 bootstrap，旧块被裁剪', () async {
    // A 的日志窗口只保留 1 条：连续变更会触发硬上限，把快照覆盖推进到头部
    // （并重发快照），落后对端因此能重新引导。
    final a = await network.addDevice(
      'devA',
      kind: SyncTransportKind.webdav,
      deviceLimits: const SyncJournalLimits(maxEntries: 1),
    );
    final b = await network.addDevice('devB', kind: SyncTransportKind.webdav);

    for (final value in ['v1', 'v2', 'v3']) {
      await a.setSetting('theme_mode', value);
      await a.engine.syncNow();
    }
    // A 已把覆盖推进并重发快照：远端至少有两个快照 epoch，旧块被裁掉。
    expect(_names(server, 'devA', '.snapshot.msync').length, greaterThan(1));
    expect(await a.journal.baseSeq(), greaterThan(0));

    // B 从未同步过：缺口 → 读最新快照 bootstrap，拿到最新值。
    await b.engine.syncNow();
    expect(b.prefs.getString('theme_mode'), 'v3');
  });
}

/// 某台设备的远端文件（文件名形如 `<deviceId>.<...>`）。
Iterable<String> _names(FakeWebDavServer server, String device, String suffix) =>
    server.files.keys.where(
      (name) => name.startsWith('$device.') && name.endsWith(suffix),
    );
