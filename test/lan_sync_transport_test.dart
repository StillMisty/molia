import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_codec_port.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/transport/lan_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

import 'support/lan_runtime.dart';
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
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devA',
        deviceName: '设备A',
        passphrase: passphrase,
        udpPort: 47891,
      ),
      codec: codecPort,
      snapshotProvider: () async => envA,
    );
    final transportB = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devB',
        deviceName: '设备B',
        passphrase: passphrase,
        udpPort: 47892,
      ),
      codec: codecPort,
      snapshotProvider: () async => envB,
      probeTargets: const [(host: '127.0.0.1', port: 47891)],
      probeWindow: const Duration(milliseconds: 250),
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
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devA',
        deviceName: '设备A',
        passphrase: passphrase,
        udpPort: 47974,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devA'),
      probeTargets: const [(host: '127.0.0.1', port: 47975)],
      probeWindow: const Duration(milliseconds: 250),
    );
    final transportB = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devB',
        deviceName: '设备B',
        passphrase: passphrase,
        udpPort: 47975,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devB'),
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
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devA',
        deviceName: '设备A',
        passphrase: passphrase,
        udpPort: 47893,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devA'),
    );
    final transportC = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devC',
        deviceName: '设备C',
        passphrase: 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
        udpPort: 47894,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devC'),
      probeTargets: const [(host: '127.0.0.1', port: 47893)],
      probeWindow: const Duration(milliseconds: 250),
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
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devA',
        deviceName: '设备A',
        passphrase: passphrase,
        onHttpPortBound: (port) => portA = port,
        localAddresses: () async => const [],
        udpPort: 47881,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devA'),
    );
    final transportC = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devC',
        deviceName: '设备C',
        passphrase: 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
        // 手动地址是「预期对端」：发现层拿不到对端（口令不同 MAC 验不过），
        // 仍能走 HTTP 直连并由解密失败触发归属。
        manualPeers: () => [
          ManualPeer(host: '127.0.0.1', httpPort: portA, deviceId: 'devA'),
        ],
        localAddresses: () async => const [],
        udpPort: 47882,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devC'),
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
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devA',
        deviceName: '设备A',
        passphrase: passphrase,
        // 只有持久化端点（没有本轮 manual / presence）：失败不计数，但 UI
        // 仍要知道是哪台没连上。
        knownPeers: () => const [
          LanPeerEndpoint(
            deviceId: 'devGhost',
            host: '127.0.0.1',
            httpPort: 1,
            verifiedAt: 1,
          ),
        ],
        localAddresses: () async => const [],
        udpPort: 47883,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devA'),
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
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devA',
        deviceName: '设备A',
        passphrase: passphrase,
        udpPort: 47896,
      ),
      codec: codecPort,
      snapshotProvider: () async => envA,
      snapshotIdProvider: () => ownSnapshotId,
    );
    final transportB = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devB',
        deviceName: '设备B',
        passphrase: passphrase,
        udpPort: 47897,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47896)],
      probeWindow: const Duration(milliseconds: 250),
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
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devA',
        deviceName: '设备A',
        passphrase: passphrase,
        udpPort: 47898,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devA', value: 'full'),
      journalProvider: serve,
      snapshotIdProvider: () => 'hash-full',
      journalHeadProvider: () => 3,
    );
    final transportB = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devB',
        deviceName: '设备B',
        passphrase: passphrase,
        udpPort: 47899,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47898)],
      probeWindow: const Duration(milliseconds: 250),
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

  test('未启动时 pull/push 为空操作；start/stop 幂等', () async {
    final transport = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devX',
        deviceName: 'X',
        passphrase: passphrase,
        udpPort: 47895,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devX'),
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

  // 端口降级 / 双栈 / 候选地址交换（Windows 保留端口场景）

  test('上一轮 presence 无本轮 ack：指纹命中缓存也不能跳过 GET', () async {
    final envA = envelope('devA', value: 'light').withSnapshotId('hash-1');
    final transportA = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devA',
        deviceName: '设备A',
        passphrase: passphrase,
        localAddresses: () async => const [],
        udpPort: 47977,
      ),
      codec: codecPort,
      snapshotProvider: () async => envA,
      snapshotIdProvider: () => 'hash-1',
    );
    var cellular = false;
    final transportB = LanSyncTransport(
      runtime: lanRuntime(
        codec: codec,
        deviceId: 'devB',
        deviceName: '设备B',
        passphrase: passphrase,
        isCellular: () => cellular,
        localAddresses: () async => const [],
        udpPort: 47978,
      ),
      codec: codecPort,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47977)],
      probeWindow: const Duration(milliseconds: 250),
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
