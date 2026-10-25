import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_codec_port.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/transport/lan_discovery.dart';
import 'package:molia/data/sync/transport/lan_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/utils/peer_address.dart';

import 'support/sync_network.dart';

/// 局域网直连传输测试：回环上的探测、拉取、推送与口令不匹配跳过。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final codec = SyncCodec(iterations: 1000);
  // 传输只依赖编解码端口；单测用进程内实现（worker isolate 由专门测试覆盖）。
  final codecPort = InlineSyncCodecPort(codec);

  SyncEnvelope envelope(String deviceId, {String value = 'v'}) => SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceId,
        producedAt: 1,
        records: {
          SyncCategory.settings: [
            SyncRecord(
              key: 'theme_mode',
              version: SyncVersion(physical: 10, deviceId: deviceId),
              data: {'v': value},
            ),
          ],
        },
      );

  test('探测 → 拉取 → 推送：两台设备交换加密快照', () async {
    final envA = envelope('devA', value: 'light');
    final envB = envelope('devB', value: 'dark');
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envA,
      udpPort: 47891,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envB,
      probeTargets: const [(host: '127.0.0.1', port: 47891)],
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47892,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });

    await transportA.start();
    await transportB.start();
    expect(transportA.isRunning, isTrue);

    final pullResult = await transportB.pull();
    final pulled = pullResult.envelopes;
    expect(pulled, hasLength(1));
    expect(pulled.single.deviceId, 'devA');
    expect(pullResult.failedIssues, isEmpty, reason: '读取成功的设备不再标失败');
    expect(pulled.single.recordsOf(SyncCategory.settings).single.data, {
      'v': 'light',
    });

    final received = transportA.incoming.first;
    await transportB.push(envB);
    final inbound = await received.timeout(const Duration(seconds: 3));
    expect(inbound.deviceId, 'devB');
    expect(inbound.recordsOf(SyncCategory.settings).single.data, {'v': 'dark'});
  });

  test('pull 发现的对端在随后的 push 里仍是预期对端（失败计数不丢）', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      probeTargets: const [(host: '127.0.0.1', port: 47975)],
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47974,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      udpPort: 47975,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    // A 在本轮探测窗口里听到 B（presence.lastHeardAt 属于本轮起点之后）。
    // 轮次窗口显式传给 pull 与 push：两者共享同一个起点，不依赖传输内部
    // 「pull 刚跑过」的隐藏状态。
    final window = SyncRoundWindow(
      startedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final pulled = await transportA.pull(SyncPullRequest(window: window));
    expect(pulled.peersSeen, 1);
    expect(transportA.presenceCount, 1);

    // B 掉线后，同一个引擎轮次的 push 仍应把 B 当成预期对端：失败必须
    // 计入 failedPeers / failedIds，名册才能看到真实推送失败。
    await transportB.stop();
    final pushed = await transportA.push(envelope('devA'), window: window);

    expect(pushed.failedPeers, 1);
    expect(pushed.failedIds, contains('devB'));
  });

  test('口令不同的对端返回空结果（解密失败静默跳过）', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      udpPort: 47893,
    );
    final transportC = LanSyncTransport(
      deviceId: 'devC',
      deviceName: () => '设备C',
      codec: codecPort,
      passphraseProvider: () async => 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
      snapshotProvider: () async => envelope('devC'),
      probeTargets: const [(host: '127.0.0.1', port: 47893)],
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47894,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportC.stop();
    });
    await transportA.start();
    await transportC.start();

    final mismatched = await transportC.pull();
    expect(mismatched.envelopes, isEmpty);
    // 唯一对端解密失败 = 不可达：不算接触成功。
    expect(mismatched.contacted, isFalse);
  });

  test('解密失败归属到具体设备：不进 seenIds，但失败不伪装成成功', () async {
    var portA = 0;
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      onHttpPortBound: (port) => portA = port,
      localAddressesProvider: () async => const [],
      udpPort: 47881,
    );
    final transportC = LanSyncTransport(
      deviceId: 'devC',
      deviceName: () => '设备C',
      codec: codecPort,
      passphraseProvider: () async => 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
      snapshotProvider: () async => envelope('devC'),
      // 手动地址是「预期对端」：发现层拿不到对端（口令不同 MAC 验不过），
      // 仍能走 HTTP 直连并由解密失败触发归属。
      manualPeersProvider: () => [
        ManualPeer(host: '127.0.0.1', httpPort: portA, deviceId: 'devA'),
      ],
      localAddressesProvider: () async => const [],
      udpPort: 47882,
      probeWindow: const Duration(milliseconds: 100),
    );
    addTearDown(() async {
      await transportA.stop();
      await transportC.stop();
    });
    await transportA.start();
    await transportC.start();

    final result = await transportC.pull();
    expect(result.envelopes, isEmpty);
    expect(result.failedPeers, 1);
    expect(result.failedIssues.keys, ['devA']);
    expect(
      result.failedIssues['devA']?.code,
      SyncIssueCode.peerDecryptFailed,
      reason: '解密失败不能被笼统记成读取失败',
    );
    expect(result.seenIds, isNot(contains('devA')));
    expect(result.contacted, isFalse);
  });

  test('试探性端点读取失败：有失败归属，但不计入 failedPeers / partial', () async {
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      // 只有持久化端点（没有本轮 manual / presence）：失败不计数，但 UI
      // 仍要知道是哪台没连上。
      knownPeersProvider: () => const [
        LanPeerEndpoint(
          deviceId: 'devGhost',
          host: '127.0.0.1',
          httpPort: 1,
          verifiedAt: 1,
        ),
      ],
      localAddressesProvider: () async => const [],
      udpPort: 47883,
      probeWindow: const Duration(milliseconds: 100),
    );
    addTearDown(transport.stop);
    await transport.start();

    final result = await transport.pull();
    expect(result.envelopes, isEmpty);
    expect(result.failedPeers, 0, reason: '试探性对端失败不把整轮打成 partial');
    expect(result.peersSeen, 0);
    expect(result.failedIssues.keys, ['devGhost'], reason: '失败仍归属到具体设备');
    expect(result.failedIssues['devGhost']?.code, SyncIssueCode.peerReadFailed);
    expect(result.seenIds, isEmpty);
  });

  test('对端 snapshotId 未变：跳过 GET 并计入 skippedUnchanged', () async {
    var envA = envelope('devA', value: 'light').withSnapshotId('hash-1');
    var ownSnapshotId = 'hash-1';
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envA,
      snapshotIdProvider: () => ownSnapshotId,
      udpPort: 47896,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47896)],
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47897,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    final first = await transportB.pull();
    expect(first.envelopes, hasLength(1));
    expect(first.skippedUnchanged, 0);
    // 第一次拉到快照 = 一次 GET（本用例用单播目标，不涉及广播）。
    expect(transportB.snapshotGetCount, 1);
    expect(transportB.broadcastCount, 0);

    // 探测应答的内容指纹与上次拉到的一致：不 GET、不解密、不传字节。
    final decryptionsBefore = codec.decryptions;
    final derivationsBefore = codec.pbkdf2Derivations;
    final second = await transportB.pull();
    expect(second.envelopes, isEmpty);
    expect(second.skippedUnchanged, 1);
    expect(second.bytesIn, 0);
    expect(codec.decryptions, decryptionsBefore, reason: '未变跳过：没有解密动作');
    expect(codec.pbkdf2Derivations, derivationsBefore, reason: '未变跳过：没有密钥派生');
    expect(transportB.snapshotGetCount, 1, reason: '未变跳过：没有 GET');

    // 对端内容变化（新指纹）：重新拉取。
    envA = envelope('devA', value: 'dark').withSnapshotId('hash-2');
    ownSnapshotId = 'hash-2';
    final third = await transportB.pull();
    expect(third.envelopes, hasLength(1));
    expect(third.skippedUnchanged, 0);
    expect(
      third.envelopes.single.recordsOf(SyncCategory.settings).single.data,
      {'v': 'dark'},
    );
  });

  test('增量端点：按游标返回窗口，游标落后时回全量快照', () async {
    // 服务端语义由 journalProvider 决定（生产 = SyncEngine.serveJournal）。
    final serveCalls = <int>[];
    Future<SyncEnvelope> serve(int since) async {
      serveCalls.add(since);
      if (since < 0) {
        // 游标落后于窗口起点：bootstrap 全量快照。
        return envelope('devA', value: 'full').withSnapshotId('hash-full');
      }
      return SyncEnvelope(
        deviceId: 'devA',
        deviceName: '设备A',
        producedAt: 1,
        snapshotId: 'hash-full',
        journalHead: 3,
        baseSeq: 0,
        windowStart: 3,
        windowEnd: 3,
        journal: [
          SyncJournalEntry(
            seq: 3,
            category: SyncCategory.settings,
            record: SyncRecord(
              key: 'theme_mode',
              version: const SyncVersion(physical: 10, deviceId: 'devA'),
              data: const {'v': 'delta'},
            ),
          ),
        ],
      );
    }

    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'full'),
      journalProvider: serve,
      snapshotIdProvider: () => 'hash-full',
      journalHeadProvider: () => 3,
      udpPort: 47898,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47898)],
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47899,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    // 游标 -1（未消费）：对端回全量快照。
    final bootstrap = await transportB.pull();
    expect(bootstrap.envelopes.single.isDelta, isFalse);

    // 游标 0：对端回增量窗口（只带 seq > 0 的条目）。
    final delta = await transportB.pull(syncPullRequest(cursors: {'devA': 0}));
    expect(serveCalls, contains(0), reason: '增量端点按游标请求');
    final payload = delta.envelopes.single;
    expect(payload.isDelta, isTrue);
    expect(payload.journal, hasLength(1));
    expect(payload.journal!.single.record.data, {'v': 'delta'});

    // 游标已到对端头部 + 指纹未变：跳过 GET。
    final skipped = await transportB.pull(
      syncPullRequest(cursors: {'devA': 3}),
    );
    expect(skipped.envelopes, isEmpty);
    expect(skipped.skippedUnchanged, 1);
  });

  test('HTTP 路径：只服务 /molia-sync/v2/*，旧 v1 路径 404', () async {
    var httpPort = 0;
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      onHttpPortBound: (port) => httpPort = port,
      localAddressesProvider: () async => const [],
      udpPort: 47956,
    );
    addTearDown(transport.stop);
    await transport.start();
    expect(httpPort, greaterThan(0));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<int> status(String path) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$httpPort$path'),
      );
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    // 旧命名空间的路径直接 404，不识别、不提示。
    expect(await status('/molia-sync/v1/snapshot'), HttpStatus.notFound);
    expect(await status('/molia-sync/v1/journal'), HttpStatus.notFound);
    // 新路径照常服务（快照 + 增量端点）。
    expect(await status(LanSyncTransport.snapshotPath), HttpStatus.ok);
    expect(await status(LanSyncTransport.journalPath), HttpStatus.ok);
  });

  test('未启动时 pull/push 为空操作；start/stop 幂等', () async {
    final transport = LanSyncTransport(
      deviceId: 'devX',
      deviceName: () => 'X',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devX'),
      udpPort: 47895,
    );
    expect((await transport.pull()).envelopes, isEmpty);
    await transport.push(envelope('devX'));
    await transport.start();
    await transport.start();
    expect(transport.isRunning, isTrue);
    await transport.stop();
    await transport.stop();
    expect(transport.isRunning, isFalse);
  });

  // ---- 端口降级 / 双栈 / 候选地址交换（Windows 保留端口场景） ----

  test('首选探测端口被占用：UDP 降级到系统分配端口，传输照常运行且双向可达', () async {
    // 占位 socket 不设 SO_REUSEADDR：transport 的 reuseAddress 绑定会失败
    // （模拟 Windows 保留端口块，errno 10013 / 10048）。
    final occupant = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      47941,
      reuseAddress: false,
    );
    addTearDown(occupant.close);

    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      probeTargets: const [(host: '127.0.0.1', port: 47942)],
      probeWindow: const Duration(milliseconds: 250),
      localAddressesProvider: () async => const [],
      udpPort: 47941,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB', value: 'dark'),
      probeWindow: const Duration(milliseconds: 250),
      localAddressesProvider: () async => const [],
      udpPort: 47942,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    expect(transportA.isRunning, isTrue);
    expect(transportA.unavailableReason, isNull, reason: 'HTTP 端点能起来就不算传输启动失败');
    expect(transportA.discoveryPorts.v4, greaterThan(0));
    expect(transportA.discoveryPorts.v4, isNot(47941), reason: '降级后不再用被占端口');

    // A 主动探测 B：B 从非回复探测登记 A，A 从应答的地址候选 / 源地址拉到 B。
    final fromB = await transportA.pull();
    expect(fromB.envelopes.single.deviceId, 'devB');
    // B 靠上一轮学到的探测端点单播 A，反向也能拉。
    final fromA = await transportB.pull();
    expect(fromA.envelopes.single.deviceId, 'devA');
  });

  test('UDP 两族都不可用：手动地址 HTTP 直连照常；无对端时报 probePortUnavailable', () async {
    var serverHttpPort = 0;
    final server = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB', value: 'dark'),
      onHttpPortBound: (port) => serverHttpPort = port,
      localAddressesProvider: () async => const [],
      udpPort: 47943,
    );
    addTearDown(server.stop);
    await server.start();
    expect(serverHttpPort, greaterThan(0));

    // 模拟「两族绑定都失败」（Windows 保留端口块 / 网络栈受限）。
    Future<RawDatagramSocket> unavailable(InternetAddress address, int port) =>
        Future.error(const SocketException('模拟系统保留端口', osError: null));

    final manual = <ManualPeer>[];
    final client = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      udpBinder: unavailable,
      manualPeersProvider: () => manual,
      localAddressesProvider: () async => const [],
      udpPort: 47944,
    );
    addTearDown(client.stop);
    await client.start();

    expect(client.isRunning, isTrue, reason: 'UDP 不可用不该让整个传输失败');
    expect(client.unavailableReason, isNull);
    expect(
        client.discoveryPorts,
        (
          v4: 0,
          v6: 0,
        ),
        reason: '没有 UDP socket = 两族探测端口都不可用');

    // 没有可直连的对端：原因码是「探测端口不可用」而不是「启动失败」。
    final empty = await client.pull();
    expect(empty.peersSeen, 0);
    expect(empty.error?.code, SyncIssueCode.probePortUnavailable);

    // 地址簿里学到过 HTTP 端点的对端：不依赖 UDP 也能直连拉取。
    manual.add(ManualPeer(host: '127.0.0.1', httpPort: serverHttpPort));
    final pulled = await client.pull();
    expect(pulled.peersSeen, 1);
    expect(pulled.envelopes.single.deviceId, 'devB');
  });

  test('IPv6 单播探测（::1）：学习对端并拉取', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      localAddressesProvider: () async => const [],
      udpPort: 47945,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '::1', port: 47945)],
      probeWindow: const Duration(milliseconds: 250),
      localAddressesProvider: () async => const [],
      udpPort: 47946,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    final pulled = (await transportB.pull()).envelopes;
    expect(pulled.single.deviceId, 'devA');
    expect(pulled.single.recordsOf(SyncCategory.settings).single.data, {
      'v': 'light',
    });
  });

  test('手动 IPv6 对端：方括号写法归一 + HTTP 直连拉取', () async {
    var serverHttpPort = 0;
    final server = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      onHttpPortBound: (port) => serverHttpPort = port,
      localAddressesProvider: () async => const [],
      udpPort: 47947,
    );
    final client = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      manualPeersProvider: () => [
        ManualPeer(host: '[::1]', probePort: 47947, httpPort: serverHttpPort),
      ],
      probeWindow: const Duration(milliseconds: 250),
      localAddressesProvider: () async => const [],
      udpPort: 47948,
    );
    addTearDown(() async {
      await server.stop();
      await client.stop();
    });
    await server.start();
    await client.start();

    final pulled = (await client.pull()).envelopes;
    expect(pulled.single.deviceId, 'devA', reason: 'IPv6 主机的 URI 要加方括号');
  });

  test('非回复探测也登记对端：B 探测 A 后，A 反向也能发现并拉取 B', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      probeWindow: const Duration(milliseconds: 250),
      localAddressesProvider: () async => const [],
      udpPort: 47949,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB', value: 'dark'),
      probeTargets: const [(host: '127.0.0.1', port: 47949)],
      probeWindow: const Duration(milliseconds: 250),
      localAddressesProvider: () async => const [],
      udpPort: 47950,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    // B 单向往 A 探测：B 学到 A 并拉到快照；A 没有配置任何探测目标。
    expect((await transportB.pull()).envelopes.single.deviceId, 'devA');

    // A 仅凭 B 的非回复探测（源地址 + 自报端口）就能反向单播并拉取：
    // 「发送方也在线」不必等它先应答。
    final reverse = await transportA.pull();
    expect(reverse.envelopes.single.deviceId, 'devB');
  });

  test('v6 独立降级：v4 仍绑首选端口，分族端口各自如实上报', () async {
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      // 模拟 IPv6 栈不可用（禁用 / 无 v6 地址）：只让 v6 绑定失败。
      udpBinder: (address, port) {
        if (address.type == InternetAddressType.IPv6) {
          return Future.error(const SocketException('模拟 IPv6 不可用'));
        }
        return RawDatagramSocket.bind(address, port, reuseAddress: true);
      },
      udpPort: 47955,
    );
    addTearDown(transport.stop);
    await transport.start();

    expect(transport.isRunning, isTrue);
    expect(transport.discoveryPorts.v4, 47955, reason: 'v4 照常绑首选端口');
    expect(transport.discoveryPorts.v6, 0, reason: 'v6 独立降级不影响 v4');
  });

  test('注入的地址候选走统一可路由过滤：回环 / link-local / zone / 非字面量不进公告', () async {
    // 接收端只抓公告（不实现 peer 协议）：直接看线上 MSD/1 载荷里的 addrs。
    final catcher = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      47953,
      reuseAddress: false,
    );
    addTearDown(catcher.close);
    final packets = <List<int>>[];
    catcher.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = catcher.receive();
      if (datagram != null) packets.add(datagram.data);
    });

    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      // 注入的 provider 不做过滤（真实的 LocalEndpointsService 会过滤）：
      // 传输侧必须用同一判定再兜一遍。
      localAddressesProvider: () async => const [
        '127.0.0.1',
        '169.254.10.1',
        'fe80::1%eth0',
        'not-an-ip',
        '10.0.0.5',
        '10.0.0.5',
      ],
      probeTargets: const [(host: '127.0.0.1', port: 47953)],
      probeWindow: const Duration(milliseconds: 200),
      udpPort: 47954,
    );
    addTearDown(transport.stop);
    await transport.start();
    await transport.pull();

    expect(packets, isNotEmpty);
    final key = codec.discoveryKey(passphrase);
    final announce = packets
        .map((packet) => Msd1.decode(Uint8List.fromList(packet), key))
        .whereType<LanDiscoveryMessage>()
        .firstWhere((message) => message.isAnnounce);
    expect(announce.deviceId, 'devA');
    expect(announce.addresses, ['10.0.0.5'], reason: '可路由判定与去重对注入路径同样生效');
  });

  test('候选地址优先尝试：不可达的候选回落到观测源地址', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      // TEST-NET-3：保留给文档的地址，保证不可达。
      localAddressesProvider: () async => const ['192.0.2.10'],
      udpPort: 47951,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47951)],
      probeWindow: const Duration(milliseconds: 250),
      requestTimeout: const Duration(milliseconds: 150),
      localAddressesProvider: () async => const [],
      udpPort: 47952,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    final pulled = (await transportB.pull()).envelopes;
    expect(pulled.single.deviceId, 'devA');
  });

  // ---- MSD/1 发现层改造 ----

  test('已知端点直连：有候选不广播；第二次未变跳过且 0 广播', () async {
    var serverHttpPort = 0;
    final server = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      snapshotIdProvider: () => 'snap-1',
      onHttpPortBound: (port) => serverHttpPort = port,
      localAddressesProvider: () async => const [],
      udpPort: 47961,
    );
    final verified = <LanPeerEndpoint>[];
    final client = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      knownPeersProvider: () => [
        LanPeerEndpoint(
          deviceId: 'devA',
          host: '127.0.0.1',
          httpPort: serverHttpPort,
          probePort: 47961,
          verifiedAt: 1,
        ),
      ],
      onPeerVerified: verified.add,
      localAddressesProvider: () async => const [],
      udpPort: 47962,
    );
    addTearDown(() async {
      await server.stop();
      await client.stop();
    });
    await server.start();
    await client.start();

    final first = await client.pull();
    expect(first.envelopes.single.deviceId, 'devA');
    expect(first.contacted, isTrue);
    expect(client.snapshotGetCount, 1);
    expect(client.broadcastCount, 0, reason: '有已知端点只单播，不广播');
    // 回环不是可路由地址：即使 HTTP 解密成功也不写回端点表（否则换网必失效）。
    expect(verified, isEmpty, reason: '只持久化可路由地址');

    final second = await client.pull();
    expect(second.envelopes, isEmpty);
    expect(second.skippedUnchanged, 1);
    expect(client.snapshotGetCount, 1, reason: '未变跳过：没有 GET');
    expect(client.broadcastCount, 0, reason: '空闲轮 0 广播');
  });

  test('换网事件：接口指纹变化 → epoch++ / 重绑 UDP 后仍可用', () async {
    var addresses = <String>['10.0.0.5'];
    final networkChanges = StreamController<void>();
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      localAddressesProvider: () async => addresses,
      networkChanges: networkChanges.stream,
      udpPort: 47963,
    );
    addTearDown(() async {
      await transport.stop();
      await networkChanges.close();
    });
    await transport.start();
    expect(transport.networkEpoch, 1);
    final ports = transport.discoveryPorts;
    expect(ports.v4, greaterThan(0));

    addresses = ['10.0.1.5'];
    networkChanges.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(transport.networkEpoch, 2);
    expect(transport.discoveryPorts.v4, ports.v4, reason: '重绑尽力保持原端口');
    expect(transport.isRunning, isTrue);
  });

  test('蜂窝：0 广播 / 组播；已知端点仍可直连 HTTP', () async {
    var serverHttpPort = 0;
    final server = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      onHttpPortBound: (port) => serverHttpPort = port,
      localAddressesProvider: () async => const [],
      udpPort: 47964,
    );
    final client = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      knownPeersProvider: () => [
        LanPeerEndpoint(
          deviceId: 'devA',
          host: '127.0.0.1',
          httpPort: serverHttpPort,
          probePort: 47964,
          verifiedAt: 1,
        ),
      ],
      isCellular: () => true,
      localAddressesProvider: () async => const [],
      udpPort: 47965,
    );
    addTearDown(() async {
      await server.stop();
      await client.stop();
    });
    await server.start();
    await client.start();

    final pulled = await client.pull();
    expect(pulled.envelopes.single.deviceId, 'devA');
    expect(client.broadcastCount, 0, reason: '蜂窝不广播');
    expect(client.presenceCount, 0, reason: '蜂窝连单播公告也不发');
  });

  test('旧 JSON 包静默丢弃；合法 MSD/1 公告才产生 sighting', () async {
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      localAddressesProvider: () async => const [],
      udpPort: 47966,
    );
    final sightings = <LanPeerSighting>[];
    final subscription = transport.sightings.listen(sightings.add);
    final emitter = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() async {
      await subscription.cancel();
      await transport.stop();
      emitter.close();
    });
    await transport.start();
    final discoveryPort = transport.discoveryPorts.v4;
    expect(discoveryPort, greaterThan(0));

    emitter.send(
      utf8.encode(
        jsonEncode({
          'm': 'molia-sync.probe',
          'v': 1,
          'deviceId': 'devLegacy',
          'port': 1234,
        }),
      ),
      InternetAddress.loopbackIPv4,
      discoveryPort,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(sightings, isEmpty, reason: '旧 JSON 不识别、不产生 presence');
    expect(transport.presenceCount, 0);

    final key = codec.discoveryKey(passphrase);
    final packet = Msd1.encode(
      LanDiscoveryMessage(
        type: Msd1.typeAnnounce,
        deviceId: 'devModern',
        name: '新设备',
        httpPort: 43210,
        probePort: 47825,
        addresses: const [],
        snapshotId: '',
        journalHead: null,
        categories: const [],
        nonce: 'nonce-modern',
        bootId: 'boot-modern',
      ),
      key,
    );
    emitter.send(packet, InternetAddress.loopbackIPv4, discoveryPort);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(sightings, hasLength(1));
    expect(sightings.single.deviceId, 'devModern');
    expect(transport.presenceCount, 1);
  });

  test('蜂窝 + 无已知端点：不误报 discoverySilent', () async {
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      isCellular: () => true,
      localAddressesProvider: () async => const [],
      udpPort: 47967,
    );
    addTearDown(transport.stop);
    await transport.start();

    final pulled = await transport.pull();
    expect(pulled.peersSeen, 0);
    expect(pulled.contacted, isFalse);
    expect(pulled.error, isNull, reason: '蜂窝跳过发现不是网络隔离');
  });

  test('后台 + 无候选：不误报 discoverySilent / broadcastUnavailable', () async {
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      localAddressesProvider: () async => const [],
      udpPort: 47968,
    );
    addTearDown(transport.stop);
    await transport.start();
    transport.onAppHidden();

    final pulled = await transport.pull();
    expect(pulled.peersSeen, 0);
    expect(pulled.contacted, isFalse);
    expect(pulled.error, isNull, reason: '后台主动探测被策略跳过，不代表对端离线');
  });

  test('端点被另一台设备复用：按解密后的 deviceId 记 seen，不回调旧 id', () async {
    var serverHttpPort = 0;
    final server = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB', value: 'real'),
      onHttpPortBound: (port) => serverHttpPort = port,
      localAddressesProvider: () async => const [],
      udpPort: 47969,
    );
    final verified = <LanPeerEndpoint>[];
    final client = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      knownPeersProvider: () => [
        LanPeerEndpoint(
          deviceId: 'devWrong',
          host: '127.0.0.1',
          httpPort: serverHttpPort,
          verifiedAt: 1,
        ),
      ],
      onPeerVerified: verified.add,
      localAddressesProvider: () async => const [],
      udpPort: 47970,
    );
    addTearDown(() async {
      await server.stop();
      await client.stop();
    });
    await server.start();
    await client.start();

    final pulled = await client.pull();
    expect(pulled.envelopes.single.deviceId, 'devB', reason: '数据仍交给引擎');
    expect(pulled.seenIds, contains('devB'));
    expect(pulled.seenIds, isNot(contains('devWrong')));
    expect(verified, isEmpty, reason: '不能把复用端点写回错误的 deviceId');
  });

  test('回前台 HTTP 重绑失败：置为未运行并可重新 start', () async {
    var now = 1000;
    var probeAlive = true;
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      httpProbe: (port) async => probeAlive,
      nowMs: () => now,
      localAddressesProvider: () async => const [],
      udpPort: 47971,
    );
    addTearDown(transport.stop);
    await transport.start();
    expect(transport.isRunning, isTrue);
    expect(transport.unavailableReason, isNull);

    transport.onAppHidden();
    now += 16000;
    probeAlive = false;
    await transport.onAppResumed();

    expect(transport.isRunning, isFalse, reason: '重绑失败必须让状态面可见');
    expect(transport.unavailableReason, SyncUnavailableReason.startFailed);
    expect(transport.unavailableDetail, isNotNull);

    // 下一轮 SyncTransportRuntime.ensureRunning 重新 start：端口恢复后应能恢复运行。
    probeAlive = true;
    await transport.start();
    expect(transport.isRunning, isTrue);
    expect(transport.unavailableReason, isNull);
  });

  test('connectivity 事件无条件重绑 UDP（接口指纹未变）', () async {
    var binds = 0;
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      localAddressesProvider: () async => const ['10.0.0.5'],
      udpBinder: (address, port) {
        binds++;
        return RawDatagramSocket.bind(address, port, reuseAddress: true);
      },
      udpPort: 47972,
    );
    addTearDown(transport.stop);
    await transport.start();
    final baseline = binds;
    final epoch = transport.networkEpoch;
    expect(baseline, greaterThan(0));

    await transport.onNetworkChanged();

    expect(binds, greaterThan(baseline), reason: 'Wi-Fi 重连即使 IP 不变也要重绑');
    expect(transport.networkEpoch, epoch, reason: '指纹未变不升级 epoch');
    expect(transport.discoveryPorts.v4, greaterThan(0));
  });

  test('pull 检测到静默换 IP：重绑 UDP 且公告带新地址', () async {
    var now = 1000000;
    var cellular = true;
    var addresses = <String>['10.0.0.5'];
    var binds = 0;
    final catcher = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      47974,
      reuseAddress: false,
    );
    final packets = <List<int>>[];
    catcher.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = catcher.receive();
      if (datagram != null) packets.add(datagram.data);
    });
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      localAddressesProvider: () async => addresses,
      udpBinder: (address, port) {
        binds++;
        return RawDatagramSocket.bind(address, port, reuseAddress: true);
      },
      probeTargets: const [(host: '127.0.0.1', port: 47974)],
      probeWindow: const Duration(milliseconds: 150),
      nowMs: () => now,
      isCellular: () => cellular,
      udpPort: 47973,
    );
    addTearDown(() async {
      await transport.stop();
      catcher.close();
    });
    // 蜂窝启动不公告，避免 start burst 干扰抓包；启动后切回 Wi-Fi 再 pull。
    await transport.start();
    cellular = false;
    packets.clear();
    final baseline = binds;

    addresses = ['10.0.1.5'];
    now += 61000;
    await transport.pull();

    expect(binds, greaterThan(baseline), reason: '静默换 IP 后必须重绑旧 socket');
    expect(transport.networkEpoch, 2);
    final key = codec.discoveryKey(passphrase);
    final announcements = packets
        .map((packet) => Msd1.decode(Uint8List.fromList(packet), key))
        .whereType<LanDiscoveryMessage>()
        .where((message) => message.isAnnounce)
        .toList();
    expect(announcements, isNotEmpty);
    expect(
      announcements.any((message) => message.addresses.contains('10.0.1.5')),
      isTrue,
      reason: '重绑后的公告要带新接口地址',
    );
  });

  test('端点持久化只接受可路由地址', () {
    expect(isRoutablePeerAddress('::1'), isFalse);
    expect(isRoutablePeerAddress('fe80::1'), isFalse);
    expect(isRoutablePeerAddress('fe80::1%eth0'), isFalse);
    expect(isRoutablePeerAddress('192.168.1.7'), isTrue);
  });

  test('上一轮 presence 无本轮 ack：指纹命中缓存也不能跳过 GET', () async {
    final envA = envelope('devA', value: 'light').withSnapshotId('hash-1');
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envA,
      snapshotIdProvider: () => 'hash-1',
      localAddressesProvider: () async => const [],
      udpPort: 47977,
    );
    var cellular = false;
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47977)],
      probeWindow: const Duration(milliseconds: 250),
      isCellular: () => cellular,
      localAddressesProvider: () async => const [],
      udpPort: 47978,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    final first = await transportB.pull();
    expect(first.envelopes.single.deviceId, 'devA');
    expect(transportB.snapshotGetCount, 1);

    // 第二轮切到蜂窝：不再发探测，也就不可能收到 A 的 ack。presence 仍是
    // 上一轮的旧 snap/head；即使与缓存一致，也不能据此跳过 GET。
    cellular = true;
    final second = await transportB.pull();
    expect(second.envelopes, hasLength(1));
    expect(second.skippedUnchanged, 0);
    expect(transportB.snapshotGetCount, 2, reason: '本轮没有新鲜指纹，必须重新拉取');
  });
}
