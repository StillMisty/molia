import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_codec_port.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/transport/webdav_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

import 'support/fake_webdav_server.dart';

/// WebDAV 传输测试：对本地假 DAV 服务完成推送 / 列表 / 拉取 / 鉴权。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final codec = SyncCodec(iterations: 1000);
  // 传输只依赖编解码端口；单测用进程内实现（worker isolate 由专门测试覆盖）。
  final codecPort = InlineSyncCodecPort(codec);

  late FakeWebDavServer server;

  setUp(() async {
    server = FakeWebDavServer();
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

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

  WebDavSyncTransport transport(
    String deviceId, {
    String password = 'secret',
    String? passphraseOverride,
    int? baseSeq,
  }) =>
      WebDavSyncTransport(
        deviceId: deviceId,
        codec: codecPort,
        passphraseProvider: () async => passphraseOverride ?? passphrase,
        configProvider: () => WebDavConfig(
          baseUrl: server.baseUrl,
          username: 'user',
        ),
        passwordProvider: () async => password,
        journalBaseSeqProvider: baseSeq == null ? null : () async => baseSeq,
        requestTimeout: const Duration(seconds: 5),
      );

  /// 全量快照载荷（名字里的覆盖位置 = [coverage]）。
  SyncEnvelope snapshotEnvelope(String deviceId, {required int coverage}) =>
      SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceId,
        producedAt: 1,
        journalHead: coverage,
        records: {
          SyncCategory.settings: [
            SyncRecord(
              key: 'theme_mode',
              version: SyncVersion(physical: coverage, deviceId: deviceId),
              data: const {'v': 'full'},
            ),
          ],
        },
      );

  test('推送 → 拉取：只读取其他设备的文件', () async {
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();

    await a.push(envelope('devA', value: 'light'));
    // 三类文件：回执（固定名）+ 快照（名字自带覆盖位置）。
    expect(server.files.keys, contains('devA.acks.msync'));
    expect(
      server.files.keys.where((name) => name.endsWith('.snapshot.msync')),
      hasLength(1),
    );

    await b.push(envelope('devB', value: 'dark'));
    final pulled = (await b.pull()).envelopes;
    expect(pulled, hasLength(1));
    expect(pulled.single.deviceId, 'devA');

    final pulledByA = (await a.pull()).envelopes;
    expect(pulledByA, hasLength(1));
    expect(pulledByA.single.deviceId, 'devB');
  });

  test('口令不同的快照被跳过', () async {
    final a = transport('devA');
    final c = transport('devC',
        passphraseOverride: 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ');
    addTearDown(() async {
      await a.stop();
      await c.stop();
    });
    await a.start();
    await c.start();
    await a.push(envelope('devA'));

    expect((await c.pull()).envelopes, isEmpty);
  });

  test('未配置 / 未启动时为空操作', () async {
    final unconfigured = WebDavSyncTransport(
      deviceId: 'devX',
      codec: codecPort,
      passphraseProvider: () async => passphrase,
      configProvider: () => const WebDavConfig(),
      passwordProvider: () async => '',
    );
    expect((await unconfigured.pull()).envelopes, isEmpty);
    await unconfigured.start();
    await unconfigured.push(envelope('devX'));
    expect(server.files, isEmpty);
    await unconfigured.stop();
    expect((await unconfigured.pull()).envelopes, isEmpty);
  });

  test('404 目录时 MKCOL 自动创建', () async {
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();
    await a.push(envelope('devA'));
    expect(server.mkcolCount, greaterThan(0));
    expect(server.files, contains('devA.acks.msync'));
  });

  test('目录准备失败：计为失败对端并带原因（不被判成「没发现对端」）', () async {
    server.mkcolStatus = 500;
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();

    final result = await a.pull();
    // 目录都没准备好 = 一个对端都没接触上：必须计数，否则引擎侧
    // failedPeers=0 会把整轮判成 noPeers 并吞掉错误。
    expect(result.failedPeers, 1);
    expect(result.error?.code, SyncIssueCode.webdavDirFailed);
    expect(result.error?.detail, isNotNull);
    expect(result.contacted, isFalse);
  });

  test('目录可读但零快照：接触成功（首台设备 PUT 失败仍是部分失败）', () async {
    server.putStatus = 500;
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();

    // 目录可读、还没有其他设备的快照：远端可达，零快照也算接触。
    final pulled = await a.pull();
    expect(pulled.envelopes, isEmpty);
    expect(pulled.peersSeen, 0);
    expect(pulled.contacted, isTrue);

    // 首台设备的写入失败：推送失败有原因，但接触面是成功的。
    final pushed = await a.push(envelope('devA'));
    expect(pushed.failedPeers, 1);
    expect(pushed.error?.code, SyncIssueCode.webdavUploadFailed);
  });

  test('目录列表失败：计为失败对端并带原因', () async {
    server.propfindStatus = 500;
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();

    final result = await a.pull();
    expect(result.failedPeers, 1);
    expect(result.error?.code, SyncIssueCode.webdavListFailed);
  });

  test('文件 etag 未变：跳过 GET 并计入 skippedUnchanged', () async {
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();
    await a.push(envelope('devA', value: 'light'));

    final first = await b.pull();
    expect(first.envelopes, hasLength(1));
    expect(first.skippedUnchanged, 0);
    final getsAfterFirst = server.getCount;

    // 远端文件未动 + 本机游标已到上次读到的头部：第二轮不 GET、不解密、不合并。
    final decryptionsBefore = codec.decryptions;
    final second = await b.pull(
      const SyncPullRequest(cursors: {'devA': 0}),
    );
    expect(second.envelopes, isEmpty);
    expect(second.skippedUnchanged, 1);
    expect(second.bytesIn, 0);
    expect(server.getCount, getsAfterFirst);
    expect(codec.decryptions, decryptionsBefore, reason: 'etag 未变：没有解密动作');
  });

  test('文件 etag 变化后重新拉取', () async {
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();
    await a.push(envelope('devA', value: 'light'));
    expect((await b.pull()).envelopes, hasLength(1));

    await a.push(envelope('devA', value: 'dark'));
    final changed = await b.pull();
    expect(changed.envelopes, hasLength(1));
    expect(
        changed.envelopes.single.recordsOf(SyncCategory.settings).single.data,
        {'v': 'dark'});
    expect(changed.skippedUnchanged, 0);
  });

  test('增量窗口与全量快照分开文件：日常只重写增量', () async {
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();

    await a.push(SyncEnvelope(
      deviceId: 'devA',
      producedAt: 1,
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
            data: const {'v': 'dark'},
          ),
        ),
      ],
    ));
    expect(server.files.keys, contains('devA.3-3.chunk.msync'));
    expect(
      server.files.keys.where((name) => name.endsWith('.snapshot.msync')),
      isEmpty,
      reason: '增量窗口不写快照文件',
    );

    await a.push(envelope('devA'));
    expect(
      server.files.keys.where((name) => name.endsWith('.snapshot.msync')),
      hasLength(1),
    );
  });

  test('增量日志文件可被对端拉到并解密：游标决定应用范围', () async {
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();

    SyncJournalEntry entry(int seq, String value) => SyncJournalEntry(
          seq: seq,
          category: SyncCategory.settings,
          record: SyncRecord(
            key: 'theme_mode',
            version: SyncVersion(physical: 10 + seq, deviceId: 'devA'),
            data: {'v': value},
          ),
        );
    SyncEnvelope delta(List<SyncJournalEntry> entries) => SyncEnvelope(
          deviceId: 'devA',
          deviceName: '设备A',
          producedAt: 1,
          snapshotId: 'hash-${entries.last.seq}',
          journalHead: entries.last.seq,
          baseSeq: 0,
          windowStart: entries.first.seq,
          windowEnd: entries.last.seq,
          journal: entries,
        );

    // 日常路径：每次变更只写一个新块（名字自带区间，写一次不再改）。
    await a.push(delta([entry(1, 'dark')]));
    expect(server.files.keys, contains('devA.1-1.chunk.msync'));

    // 首次拉取（游标 -1）：拿到窗口里的条目（解密 + 窗口游标正确）。
    final first = await b.pull();
    expect(first.envelopes, hasLength(1));
    final payload = first.envelopes.single;
    expect(payload.isDelta, isTrue);
    expect(payload.journal!.single.seq, 1);
    expect(payload.journal!.single.record.data, {'v': 'dark'});

    // 游标已到窗口末尾 + 文件版本未变：跳过 GET。
    final skipped = await b.pull(const SyncPullRequest(cursors: {'devA': 1}));
    expect(skipped.envelopes, isEmpty);
    expect(skipped.skippedUnchanged, 1);

    // 窗口推进：新块（1-2）只带新条目，旧块不再重写。
    await a.push(delta([entry(1, 'dark'), entry(2, 'light')]));
    expect(server.files.keys, contains('devA.1-2.chunk.msync'));
    final second = await b.pull(const SyncPullRequest(cursors: {'devA': 1}));
    expect(second.envelopes, hasLength(1));
    expect(second.envelopes.single.journal, hasLength(2));
    expect(second.envelopes.single.windowEnd, 2);
  });

  test('游标落后于窗口起点：改读全量快照做 bootstrap', () async {
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();

    // 快照文件（覆盖到 seq 5）+ 窗口起点已推进到 4 的日志文件。
    await a.push(envelope('devA', value: 'full').withSnapshotId('hash-full'));
    await a.push(SyncEnvelope(
      deviceId: 'devA',
      producedAt: 1,
      snapshotId: 'hash-full',
      journalHead: 6,
      baseSeq: 4,
      windowStart: 5,
      windowEnd: 6,
      journal: [
        SyncJournalEntry(
          seq: 5,
          category: SyncCategory.settings,
          record: SyncRecord(
            key: 'theme_mode',
            version: const SyncVersion(physical: 20, deviceId: 'devA'),
            data: const {'v': 'newer'},
          ),
        ),
      ],
    ));

    // 本机游标 1 < 窗口起点（baseSeq 4）：窗口不完整 → 用全量快照兜底。
    final pulled = await b.pull(const SyncPullRequest(cursors: {'devA': 1}));
    expect(pulled.envelopes, hasLength(1));
    expect(pulled.envelopes.single.isDelta, isFalse);
    expect(
      pulled.envelopes.single.recordsOf(SyncCategory.settings).single.data,
      {'v': 'full'},
    );
  });

  test('幽灵文件不参与合并；载荷身份不符的文件跳过', () async {
    // 非本协议命名的残留（幽灵设备遗留）、旧命名（只清理不读）
    // 与身份不符的块文件。
    server.files['ghost.msync'] = codec.encrypt(envelope('ghost'), passphrase);
    server.files['fake.journal.msync'] =
        codec.encrypt(envelope('someone-else'), passphrase);
    server.files['fake.1-1.chunk.msync'] =
        codec.encrypt(envelope('someone-else'), passphrase);
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();
    await a.push(envelope('devA', value: 'light'));

    final pulled = await b.pull();
    expect(pulled.envelopes, hasLength(1));
    expect(pulled.envelopes.single.deviceId, 'devA');
    expect(pulled.peersSeen, 1, reason: '幽灵文件不算对端');
    expect(pulled.failedPeers, 0);
  });

  test('显式清理远端文件：删除该设备的日志 / 快照 / 其它命名残留', () async {
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();
    await a.push(envelope('devA'));
    final snapshotName = server.files.keys
        .firstWhere((name) => name.endsWith('.snapshot.msync'));
    server.files['devA.journal.msync'] = server.files[snapshotName]!;
    server.files['devA.msync'] = server.files[snapshotName]!;

    expect(await a.deleteRemote('devA'), isTrue);
    expect(
      server.files.keys.where((name) => name.startsWith('devA.')),
      isEmpty,
      reason: '回执 / 快照 / 旧命名残留都要清掉',
    );
    expect(server.files.keys, isNot(contains('devA.msync')));
    // 没有文件可删时不算失败。
    expect(await a.deleteRemote('devA'), isFalse);
  });

  test('清理远端文件失败：如实抛错（不显示成「没有可清理的文件」）', () async {
    server.deleteStatus = 500;
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();
    server.files['ghost.snapshot.msync'] =
        codec.encrypt(envelope('ghost'), passphrase);

    await expectLater(
      a.deleteRemote('ghost'),
      throwsA(isA<WebDavHttpException>()),
    );
  });

  test('v3 之前的旧命名文件：只清理不读，也不当成对端', () async {
    server.files['devA.journal.msync'] =
        codec.encrypt(envelope('devA'), passphrase);
    server.files['devA.snapshot.msync'] =
        codec.encrypt(envelope('devA'), passphrase);
    final b = transport('devB');
    addTearDown(() => b.stop());
    await b.start();

    final pulled = await b.pull();
    expect(pulled.envelopes, isEmpty, reason: '旧命名不参与合并');
    expect(pulled.peersSeen, 0);
    expect(pulled.failedPeers, 0);
  });

  test('分块裁剪：baseSeq 之后的旧块被删除，之后的块保留', () async {
    final a = transport('devA', baseSeq: 2);
    addTearDown(() => a.stop());
    await a.start();
    SyncEnvelope delta(int seq) => SyncEnvelope(
          deviceId: 'devA',
          producedAt: 1,
          journalHead: seq,
          windowStart: seq,
          windowEnd: seq,
          journal: [
            SyncJournalEntry(
              seq: seq,
              category: SyncCategory.settings,
              record: SyncRecord(
                key: 'theme_mode',
                version: SyncVersion(physical: seq, deviceId: 'devA'),
                data: {'v': 'v$seq'},
              ),
            ),
          ],
        );
    await a.push(delta(1));
    await a.push(delta(2));
    await a.push(delta(3));
    expect(server.files.keys, contains('devA.1-1.chunk.msync'));

    // 拉取触发裁剪：baseSeq = 2 → 块 1-1 与 2-2 删掉，3-3 保留。
    await a.pull();
    expect(server.files.keys, isNot(contains('devA.1-1.chunk.msync')));
    expect(server.files.keys, isNot(contains('devA.2-2.chunk.msync')));
    expect(server.files.keys, contains('devA.3-3.chunk.msync'));
  });

  test('快照只留最新一份（旧覆盖位置的快照被裁剪）', () async {
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();
    await a.push(snapshotEnvelope('devA', coverage: 3));
    await a.push(snapshotEnvelope('devA', coverage: 5));

    await a.pull();
    expect(server.files.keys, contains('devA.5.snapshot.msync'));
    expect(server.files.keys, isNot(contains('devA.3.snapshot.msync')));
  });

  test('服务端不返回版本：照常拉取（不跳过）', () async {
    server.includeVersion = false;
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();
    await a.push(envelope('devA'));

    expect((await b.pull()).envelopes, hasLength(1));
    final again = await b.pull();
    expect(again.envelopes, hasLength(1));
    expect(again.skippedUnchanged, 0);
  });
}
