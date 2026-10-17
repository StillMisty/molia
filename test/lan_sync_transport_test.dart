import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/transport/lan_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

/// 局域网直连传输测试：回环上的探测、拉取、推送与口令不匹配跳过。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final codec = SyncCodec(iterations: 1000);

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
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envA,
      udpPort: 47891,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
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

    final pulled = (await transportB.pull()).envelopes;
    expect(pulled, hasLength(1));
    expect(pulled.single.deviceId, 'devA');
    expect(
      pulled.single.recordsOf(SyncCategory.settings).single.data,
      {'v': 'light'},
    );

    final received = transportA.incoming.first;
    await transportB.push(envB);
    final inbound = await received.timeout(const Duration(seconds: 3));
    expect(inbound.deviceId, 'devB');
    expect(
      inbound.recordsOf(SyncCategory.settings).single.data,
      {'v': 'dark'},
    );
  });

  test('口令不同的对端返回空结果（解密失败静默跳过）', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      udpPort: 47893,
    );
    final transportC = LanSyncTransport(
      deviceId: 'devC',
      deviceName: () => '设备C',
      codec: codec,
      passphraseProvider: () async =>
          'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
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

  test('对端 snapshotId 未变：跳过 GET 并计入 skippedUnchanged', () async {
    var envA = envelope('devA', value: 'light').withSnapshotId('hash-1');
    var ownSnapshotId = 'hash-1';
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envA,
      snapshotIdProvider: () => ownSnapshotId,
      udpPort: 47896,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
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
    expect(codec.decryptions, decryptionsBefore,
        reason: '未变跳过：没有解密动作');
    expect(codec.pbkdf2Derivations, derivationsBefore,
        reason: '未变跳过：没有密钥派生');
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
      codec: codec,
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
      codec: codec,
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
    final delta = await transportB.pull(
      const SyncPullRequest(cursors: {'devA': 0}),
    );
    expect(serveCalls, contains(0), reason: '增量端点按游标请求');
    final payload = delta.envelopes.single;
    expect(payload.isDelta, isTrue);
    expect(payload.journal, hasLength(1));
    expect(payload.journal!.single.record.data, {'v': 'delta'});

    // 游标已到对端头部 + 指纹未变：跳过 GET。
    final skipped = await transportB.pull(
      const SyncPullRequest(cursors: {'devA': 3}),
    );
    expect(skipped.envelopes, isEmpty);
    expect(skipped.skippedUnchanged, 1);
  });

  test('本地忽略的设备：不拉取它的载荷', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      udpPort: 47903,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47903)],
      probeWindow: const Duration(milliseconds: 250),
      ignoredPeersProvider: (deviceId) => deviceId == 'devA',
      udpPort: 47904,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    final pulled = await transportB.pull();
    expect(pulled.envelopes, isEmpty);
    expect(pulled.peersSeen, 0, reason: '忽略的设备不参与本轮');
  });

  test('未启动时 pull/push 为空操作；start/stop 幂等', () async {
    final transport = LanSyncTransport(
      deviceId: 'devX',
      deviceName: () => 'X',
      codec: codec,
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
      codec: codec,
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
      codec: codec,
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
    expect(transportA.unavailableReason, isNull,
        reason: 'HTTP 端点能起来就不算传输启动失败');
    expect(transportA.discoveryPorts.v4, greaterThan(0));
    expect(transportA.discoveryPorts.v4, isNot(47941),
        reason: '降级后不再用被占端口');

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
      codec: codec,
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
      codec: codec,
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
      (v4: 0, v6: 0),
      reason: '没有 UDP socket = 两族探测端口都不可用',
    );

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
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      localAddressesProvider: () async => const [],
      udpPort: 47945,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
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
    expect(
      pulled.single.recordsOf(SyncCategory.settings).single.data,
      {'v': 'light'},
    );
  });

  test('手动 IPv6 对端：方括号写法归一 + HTTP 直连拉取', () async {
    var serverHttpPort = 0;
    final server = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      onHttpPortBound: (port) => serverHttpPort = port,
      localAddressesProvider: () async => const [],
      udpPort: 47947,
    );
    final client = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      manualPeersProvider: () => [
        ManualPeer(
          host: '[::1]',
          probePort: 47947,
          httpPort: serverHttpPort,
        ),
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
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      probeWindow: const Duration(milliseconds: 250),
      localAddressesProvider: () async => const [],
      udpPort: 47949,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
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
      codec: codec,
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

  test('注入的地址候选走统一可路由过滤：回环 / link-local / zone / 非字面量不进探测包', () async {
    // 接收端只抓探测包（不实现 peer 协议）：直接看线上载荷里的 addrs。
    final catcher = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      47953,
      reuseAddress: false,
    );
    addTearDown(catcher.close);
    final messages = <String>[];
    catcher.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = catcher.receive();
      if (datagram != null) messages.add(utf8.decode(datagram.data));
    });

    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
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

    expect(messages, isNotEmpty);
    final probe = jsonDecode(messages.first) as Map<String, dynamic>;
    expect(probe['m'], 'molia-sync.probe');
    expect(probe['addrs'], ['10.0.0.5'],
        reason: '可路由判定与去重对注入路径同样生效');
  });

  test('候选地址优先尝试：不可达的候选回落到观测源地址', () async {    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      // TEST-NET-3：保留给文档的地址，保证不可达。
      localAddressesProvider: () async => const ['192.0.2.10'],
      udpPort: 47951,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
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
}
