import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_activity.dart';
import 'package:molia/data/sync/sync_state_codec.dart';
import 'package:molia/data/sync/sync_stamp.dart';
import 'package:molia/domain/models/device_sync.dart';

/// `sync_state_v2` 的持久化形状测试：完整状态往返、空 / 旧载荷默认值、
/// 损坏载荷的丢弃规则。
///
/// 行为口径以 `test/sync_state_store_test.dart` 为准：这里是同一套规则在纯
/// 编解码层的直接断言，不启动存储、不碰 SharedPreferences 与安全存储。
void main() {
  test('完整状态往返：键、条件字段与嵌套值原样保留', () {
    final state = _populatedState();
    final encoded = SyncStateCodec.encode(state);

    expect(encoded['v'], 2, reason: 'v2 是唯一的持久化格式');
    // 非空才写的条件字段：完整状态必须全部出现。
    for (final key in const [
      'manualPeers',
      'notifiedPeers',
      'lanHttpPort',
      'activeScript',
      'sessionStamp',
      'transportLastSuccess',
      'snapshotPush',
      'lanEndpoints',
    ]) {
      expect(encoded, contains(key), reason: '非空字段 $key 必须写入');
    }

    // 走一遍真实 wire format：先编码成 JSON 文本再解析，证明所有值都可序列化。
    final wire = jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
    final restored = SyncStateCodec.decode(wire);
    expect(restored, isNotNull);
    final value = restored!;

    expect(value.deviceId, 'devA');
    expect(value.deviceName, '书房-A');
    expect(value.categories, state.categories);
    expect(value.transports, {'lan', 'webdav'});
    expect(value.webdav.baseUrl, 'https://dav.example.com/dav');
    expect(value.webdav.username, 'molia');
    expect(value.webdav.remoteDir, 'molia-backup');
    expect(value.cellularPolicy, SyncCellularPolicy.pause);

    expect(value.manualPeers, hasLength(2));
    expect(value.manualPeers.first.host, '192.168.1.23');
    expect(value.manualPeers.first.probePort, 47825);
    expect(value.manualPeers.first.httpPort, 40000);
    expect(value.manualPeers.first.deviceId, 'devB');
    expect(value.manualPeers.first.name, '客厅');
    expect(value.manualPeers.last.host, '2409:8a55::9');
    expect(value.manualPeers.last.probePort, 0);
    expect(value.manualPeers.last.name, '');
    expect(value.notifiedPeers, {'devB', 'devC'});
    expect(value.lanHttpPort, 41234);

    expect(
      value.stampBaseline,
      const SyncVersion(physical: 1770000000123, counter: 9),
    );
    expect(value.settingStamps.keys, ['themeMode', 'language']);
    expect(value.settingStamps['themeMode']!.hash, 'h-theme');
    expect(
      value.settingStamps['themeMode']!.version,
      const SyncVersion(physical: 1770000000200, counter: 1),
    );
    expect(value.settingStamps['language']!.hash, '');
    expect(
      value.scriptTombstones['user_script_1']!.version,
      const SyncVersion(physical: 1770000000400, counter: 2, deviceId: 'devB'),
    );
    expect(value.scriptStamps['user_script_1']!.hash, 'h-script');
    expect(value.knownScriptIds, ['user_script_1', 'user_script_2']);
    expect(value.activeScriptStamp!.hash, 'h-active');
    expect(value.activeScriptStamp!.version.counter, 3);
    expect(value.sessionStamp!.version.counter, 4);
    expect(value.lastSyncAt, 1770000000500);
    expect(value.transportLastSuccess, {
      'lan': 1770000000500,
      'webdav': 1770000000400,
    });
    expect(value.snapshotPushSeq, {'lan': 12, 'webdav': 5});

    expect(value.log, hasLength(2));
    final firstLog = value.log.first;
    expect(firstLog.at, 1770000000500);
    expect(firstLog.trigger, SyncTrigger.timer);
    expect(firstLog.outcome, SyncOutcome.partial);
    expect(firstLog.durationMs, 812);
    expect(firstLog.applied, 4);
    expect(firstLog.peersSeen, 2);
    expect(firstLog.failed, 1);
    expect(firstLog.bytesIn, 2048);
    expect(firstLog.bytesOut, 1024);
    expect(firstLog.transports, ['lan']);
    expect(firstLog.error!.code, SyncIssueCode.peerReadFailed);
    expect(firstLog.error!.args['peer'], 'devB');
    expect(firstLog.error!.detail, 'timeout');
    // 可选字段缺失时不写 JSON：读回来是零值而不是 null。
    expect(value.log.last.durationMs, 0);
    expect(value.log.last.error, isNull);

    expect(value.activity, hasLength(2));
    expect(value.activity.first.at, 1770000000500);
    expect(value.activity.first.bytesIn, 1);
    expect(value.activity.first.bytesOut, 2);
    expect(value.activity.first.applied, 3);

    final peer = value.peers.single;
    expect(peer.deviceId, 'devB');
    expect(peer.name, '客厅');
    expect(peer.transport, 'lan');
    expect(peer.lastSeenAt, 1770000000500);
    expect(peer.lastSuccessAt, 1770000000500);
    expect(peer.lastPullAt, 1770000000400);
    expect(peer.lastPushAt, 1770000000300);
    expect(peer.lastError!.code, SyncIssueCode.peerPushFailed);
    expect(peer.lastError!.detail, 'http 500');
    expect(peer.behindBy, 3);
    expect(peer.behindBytes, 2048);
    expect(peer.clockSkewMs, -120);
    expect(peer.cursorSeq, 42);
    expect(peer.ackedSeq, 40);
    expect(peer.snapshotId, 'snap-1');
    expect(peer.categories, ['settings', 'playlists']);
    expect(peer.fullPulledAt, 1770000000100);

    final endpoint = value.lanEndpoints.single;
    expect(endpoint.deviceId, 'devB');
    expect(endpoint.host, '192.168.1.23');
    expect(endpoint.httpPort, 40000);
    expect(endpoint.probePort, 47825);
    expect(endpoint.verifiedAt, 1770000000450);

    expect(
      SyncStateCodec.encode(value),
      encoded,
      reason: '解码后再编码必须与首次编码完全一致（含条件字段与嵌套形状）',
    );
  });

  test('空 / 旧 v2 载荷：缺字段按默认值处理', () {
    final empty = SyncStateCodec.decode(<String, dynamic>{'v': 2})!;

    expect(empty.deviceId, '');
    expect(empty.deviceName, '');
    expect(empty.categories, {
      for (final category in SyncCategory.values) category: true,
    });
    expect(empty.transports, isEmpty);
    expect(empty.webdav.baseUrl, '');
    expect(empty.webdav.username, '');
    expect(empty.webdav.remoteDir, 'molia-sync');
    expect(empty.cellularPolicy, SyncCellularPolicy.auto);
    expect(empty.manualPeers, isEmpty);
    expect(empty.notifiedPeers, isEmpty);
    expect(empty.lanHttpPort, 0);
    expect(empty.stampBaseline, SyncVersion.zero);
    expect(empty.settingStamps, isEmpty);
    expect(empty.scriptTombstones, isEmpty);
    expect(empty.scriptStamps, isEmpty);
    expect(empty.knownScriptIds, isEmpty);
    expect(empty.activeScriptStamp, isNull);
    expect(empty.sessionStamp, isNull);
    expect(empty.lastSyncAt, 0);
    expect(empty.transportLastSuccess, isEmpty);
    expect(empty.snapshotPushSeq, isEmpty);
    expect(empty.log, isEmpty);
    expect(empty.activity, isEmpty);
    expect(empty.peers, isEmpty);
    expect(empty.lanEndpoints, isEmpty);

    // 条件字段：空状态只保留始终存在的键（形状基线，改动需同步评审）。
    expect(SyncStateCodec.encode(empty).keys.toSet(), {
      'v',
      'deviceId',
      'deviceName',
      'categories',
      'transports',
      'webdav',
      'cellularPolicy',
      'stampSeq',
      'settings',
      'scriptTombstones',
      'scriptStamps',
      'knownScripts',
      'lastSyncAt',
      'log',
      'activity',
      'peers',
    });

    // 旧 v2 没有后来新增的字段：缺失按默认值兼容；名册 lastSuccessAt 为 0 时
    // 由 SyncPeerState.effectiveLastSuccessAt 走旧数据兜底。
    final legacy = SyncStateCodec.decode(<String, dynamic>{
      'v': 2,
      'deviceId': 'devA',
      'deviceName': '旧设备',
      'transports': <String>['lan'],
      'settings': {
        'themeMode': {
          'h': 'hash',
          'v': {'physical': 10},
        },
      },
      'peers': [
        {'deviceId': 'devB', 'lastSeenAt': 900, 'lastPullAt': 700},
      ],
    })!;
    expect(legacy.deviceId, 'devA');
    expect(legacy.transports, {'lan'});
    expect(legacy.categories.values.every((enabled) => enabled), isTrue);
    expect(legacy.settingStamps['themeMode']!.hash, 'hash');
    expect(legacy.settingStamps['themeMode']!.version.physical, 10);
    expect(legacy.peers.single.lastSuccessAt, 0);
    expect(legacy.peers.single.effectiveLastSuccessAt, 900);
    expect(legacy.lanHttpPort, 0);
    expect(legacy.activeScriptStamp, isNull);
  });

  test('损坏载荷：非对象返回 null，坏字段 / 坏条目不抛异常', () {
    for (final raw in <Object?>[
      null,
      '{"v":2}',
      42,
      <Object?>[],
      true,
    ]) {
      expect(SyncStateCodec.decode(raw), isNull, reason: '载荷 $raw 不是 JSON 对象');
    }

    // 字段级类型全部不符：整体按默认值，但解码本身不能失败。
    final state = SyncStateCodec.decode(<String, dynamic>{
      'v': 'two',
      'deviceId': 42,
      'deviceName': <String>[],
      'categories': 'all',
      'transports': 'lan',
      'webdav': 7,
      'cellularPolicy': 9,
      'manualPeers': {'host': '192.168.1.23'},
      'notifiedPeers': 3,
      'lanHttpPort': '41234',
      'stampSeq': 'zero',
      'settings': [1, 2],
      'scriptTombstones': 5,
      'scriptStamps': null,
      'knownScripts': 7,
      'activeScript': {
        'v': {'counter': 1},
      },
      'sessionStamp': false,
      'lastSyncAt': 'yesterday',
      'transportLastSuccess': ['lan'],
      'snapshotPush': null,
      'log': 'nope',
      'activity': {},
      'peers': 'nope',
      'lanEndpoints': 0,
    });
    expect(state, isNotNull);
    expect(state!.deviceId, '');
    expect(state.deviceName, '');
    expect(state.transports, isEmpty);
    expect(state.webdav.baseUrl, '');
    expect(state.cellularPolicy, SyncCellularPolicy.auto);
    expect(state.lanHttpPort, 0);
    expect(state.stampBaseline, SyncVersion.zero);
    expect(state.settingStamps, isEmpty);
    expect(state.activeScriptStamp, isNull);
    expect(state.sessionStamp, isNull);
    expect(state.lastSyncAt, 0);
    expect(state.log, isEmpty);
    expect(state.peers, isEmpty);
    expect(state.lanEndpoints, isEmpty);

    // 条目级坏类型：只丢这一条，同一列表里的合法条目保留。
    final mixed = SyncStateCodec.decode(<String, dynamic>{
      'v': 2,
      'peers': [
        {'deviceId': 'devB'},
        {'deviceId': 'badType', 'lastSeenAt': 'yesterday'},
        {'lastSeenAt': 1},
      ],
      'log': [
        {'at': 10, 'trigger': 'timer', 'outcome': 'ok'},
        {'at': 11, 'trigger': 7},
        {'trigger': 'timer'},
      ],
      'activity': [
        {'at': 20},
        {'at': 'later'},
        {'at': 21, 'bytesIn': 'lots'},
      ],
      'manualPeers': [
        {'host': '192.168.1.23'},
        {'host': '192.168.1.24', 'probePort': 'x'},
        {'host': '   '},
      ],
      'lanEndpoints': [
        {
          'deviceId': 'ok',
          'host': '192.168.1.25',
          'httpPort': 40000,
          'verifiedAt': 1,
        },
        {
          'deviceId': 'loopback',
          'host': '127.0.0.1',
          'httpPort': 40000,
          'verifiedAt': 1,
        },
        {
          'deviceId': 'badType',
          'host': '192.168.1.26',
          'httpPort': '40000',
          'verifiedAt': 1,
        },
      ],
    })!;
    expect(mixed.peers.map((peer) => peer.deviceId), ['devB']);
    expect(mixed.log.map((entry) => entry.at), [10]);
    expect(mixed.activity.map((entry) => entry.at), [20]);
    expect(mixed.manualPeers.map((peer) => peer.host), ['192.168.1.23']);
    expect(mixed.lanEndpoints.map((endpoint) => endpoint.deviceId), ['ok']);
  });

  test('读取时按保留上限截断（日志 / 活动 / 名册 / 端点）', () {
    final state = SyncStateCodec.decode(<String, dynamic>{
      'v': 2,
      'log': [
        for (var i = 0; i < 25; i++) {'at': i},
      ],
      'activity': [
        for (var i = 0; i < 245; i++) {'at': i},
      ],
      'peers': [
        for (var i = 0; i < 25; i++) {'deviceId': 'dev$i'},
      ],
      'lanEndpoints': [
        for (var i = 0; i < 40; i++)
          {
            'deviceId': 'dev$i',
            'host': '192.168.1.${i + 1}',
            'httpPort': 40000,
            'verifiedAt': i + 1,
          },
      ],
    })!;

    expect(state.log, hasLength(SyncStateCodec.logLimit));
    expect(state.log.last.at, SyncStateCodec.logLimit - 1);
    expect(state.activity, hasLength(SyncStateCodec.activityLimit));
    expect(state.peers, hasLength(SyncStateCodec.peerLimit));
    expect(state.lanEndpoints, hasLength(SyncStateCodec.lanEndpointLimit));
  });

  test('快照不可变：构造后改源集合不影响已建状态', () {
    final transports = <String>{'lan'};
    final peers = <SyncPeerState>[const SyncPeerState(deviceId: 'devB')];
    final state = SyncPersistedState(transports: transports, peers: peers);

    transports.add('webdav');
    peers.clear();

    expect(state.transports, {'lan'});
    expect(state.peers, hasLength(1));
    expect(() => state.transports.add('webdav'), throwsUnsupportedError);
    expect(() => state.peers.clear(), throwsUnsupportedError);
  });
}

SyncPersistedState _populatedState() => SyncPersistedState(
      deviceId: 'devA',
      deviceName: '书房-A',
      categories: {
        for (final category in SyncCategory.values)
          category: category != SyncCategory.statistics,
      },
      transports: {'lan', 'webdav'},
      webdav: const WebDavConfig(
        baseUrl: 'https://dav.example.com/dav',
        username: 'molia',
        remoteDir: 'molia-backup',
      ),
      cellularPolicy: SyncCellularPolicy.pause,
      manualPeers: const [
        ManualPeer(
          host: '192.168.1.23',
          probePort: 47825,
          httpPort: 40000,
          deviceId: 'devB',
          name: '客厅',
        ),
        ManualPeer(host: '2409:8a55::9'),
      ],
      notifiedPeers: {'devB', 'devC'},
      lanHttpPort: 41234,
      stampBaseline: const SyncVersion(physical: 1770000000123, counter: 9),
      settingStamps: {
        'themeMode': const SyncStamp(
          hash: 'h-theme',
          version: SyncVersion(physical: 1770000000200, counter: 1),
        ),
        'language': const SyncStamp(
          version: SyncVersion(physical: 1770000000300),
        ),
      },
      scriptTombstones: {
        'user_script_1': const SyncStamp(
          version: SyncVersion(
            physical: 1770000000400,
            counter: 2,
            deviceId: 'devB',
          ),
        ),
      },
      scriptStamps: {
        'user_script_1': const SyncStamp(
          hash: 'h-script',
          version: SyncVersion(physical: 1770000000350, counter: 1),
        ),
      },
      knownScriptIds: ['user_script_1', 'user_script_2'],
      activeScriptStamp: const SyncStamp(
        hash: 'h-active',
        version: SyncVersion(physical: 1770000000300, counter: 3),
      ),
      sessionStamp: const SyncStamp(
        version: SyncVersion(physical: 1770000000250, counter: 4),
      ),
      lastSyncAt: 1770000000500,
      transportLastSuccess: {
        'lan': 1770000000500,
        'webdav': 1770000000400,
      },
      snapshotPushSeq: {'lan': 12, 'webdav': 5},
      log: const [
        SyncLogEntry(
          at: 1770000000500,
          trigger: SyncTrigger.timer,
          outcome: SyncOutcome.partial,
          durationMs: 812,
          applied: 4,
          peersSeen: 2,
          failed: 1,
          bytesIn: 2048,
          bytesOut: 1024,
          transports: ['lan'],
          error: SyncIssue(
            code: SyncIssueCode.peerReadFailed,
            args: {'peer': 'devB'},
            detail: 'timeout',
          ),
        ),
        SyncLogEntry(
          at: 1770000000400,
          trigger: SyncTrigger.startup,
          outcome: SyncOutcome.noPeers,
        ),
      ],
      activity: const [
        SyncActivityEntry(
          at: 1770000000500,
          bytesIn: 1,
          bytesOut: 2,
          applied: 3,
        ),
        SyncActivityEntry(at: 1770000000400),
      ],
      peers: const [
        SyncPeerState(
          deviceId: 'devB',
          name: '客厅',
          transport: 'lan',
          lastSeenAt: 1770000000500,
          lastSuccessAt: 1770000000500,
          lastPullAt: 1770000000400,
          lastPushAt: 1770000000300,
          lastError: SyncIssue(
            code: SyncIssueCode.peerPushFailed,
            detail: 'http 500',
          ),
          behindBy: 3,
          behindBytes: 2048,
          clockSkewMs: -120,
          cursorSeq: 42,
          ackedSeq: 40,
          snapshotId: 'snap-1',
          categories: ['settings', 'playlists'],
          fullPulledAt: 1770000000100,
        ),
      ],
      lanEndpoints: const [
        LanPeerEndpoint(
          deviceId: 'devB',
          host: '192.168.1.23',
          httpPort: 40000,
          probePort: 47825,
          verifiedAt: 1770000000450,
        ),
      ],
    );
