import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/transport/local_network_permission.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 平台准入：**权限门**与**地址簿持久化**。
///
/// 真实 socket / HTTP 的用例在 `lan_manual_peer_test.dart`（本文件带
/// `TestWidgetsFlutterBinding`，它会把 HttpClient 桩掉，HTTP 一律返回 400）。
///
/// 关键事实（见 ADR-0003 v2 §3）：Android 17 起局域网默认阻断，
/// **权限被拒时手动填地址也无效**；手动地址解决的是「发现失败」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalNetworkPermission', () {
    test('不需要权限的平台：恒为允许且不触发申请', () async {
      var requested = 0;
      final permission = LocalNetworkPermission(
        needsPermission: false,
        request: () async {
          requested++;
          return LocalNetworkPermissionStatus.denied;
        },
      );

      expect(permission.granted, isTrue);
      expect(await permission.ensure(), isTrue);
      expect(requested, 0);
    });

    test('自动路径：同会话内被拒后不重复弹窗；显式重试才再问', () async {
      var requested = 0;
      final permission = LocalNetworkPermission(
        needsPermission: true,
        request: () async {
          requested++;
          return LocalNetworkPermissionStatus.denied;
        },
      );

      expect(await permission.ensure(), isFalse);
      expect(await permission.ensure(), isFalse);
      expect(requested, 1, reason: '自动路径不应重复弹窗');
      expect(await permission.ensure(retry: true), isFalse);
      expect(requested, 2, reason: '用户显式请求要再问一次');
      expect(permission.granted, isFalse);
    });

    test('授予后 granted 为真，refresh 可重新查询', () async {
      var granted = false;
      LocalNetworkPermissionStatus statusOf() => granted
          ? LocalNetworkPermissionStatus.granted
          : LocalNetworkPermissionStatus.denied;
      final permission = LocalNetworkPermission(
        needsPermission: true,
        request: () async => statusOf(),
        check: () async => statusOf(),
      );

      granted = true;
      expect(await permission.ensure(), isTrue);
      expect(permission.granted, isTrue);

      granted = false;
      expect(await permission.refresh(), isFalse);
      expect(permission.granted, isFalse);
    });

    test('跳系统设置走注入实现', () async {
      var opened = 0;
      final permission = LocalNetworkPermission(
        needsPermission: true,
        openSettings: () async => opened++,
      );
      await permission.openSystemSettings();
      expect(opened, 1);
    });

    test('未申请：按「允许」处理，不误报权限问题', () async {
      final permission = LocalNetworkPermission(needsPermission: true);
      expect(permission.status, LocalNetworkPermissionStatus.notRequested);
      expect(permission.granted, isTrue);
      expect(permission.denied, isFalse);
      expect(permission.needsUserAction, isFalse);
      expect(permission.permanentlyDenied, isFalse);
    });

    test('显式申请先复查系统状态：已授权不再请求', () async {
      var requested = 0;
      var checked = 0;
      final permission = LocalNetworkPermission(
        needsPermission: true,
        request: () async {
          requested++;
          return LocalNetworkPermissionStatus.denied;
        },
        check: () async {
          checked++;
          return LocalNetworkPermissionStatus.granted;
        },
      );

      expect(await permission.ensure(retry: true), isTrue);
      expect(checked, 1, reason: '用户可能刚在系统设置里授权');
      expect(requested, 0);
    });

    test('显式申请复查仍被拒：再次请求', () async {
      var requested = 0;
      var checked = 0;
      final permission = LocalNetworkPermission(
        needsPermission: true,
        request: () async {
          requested++;
          return LocalNetworkPermissionStatus.denied;
        },
        check: () async {
          checked++;
          return LocalNetworkPermissionStatus.denied;
        },
      );

      expect(await permission.ensure(retry: true), isFalse);
      expect(checked, 1);
      expect(requested, 1);
      expect(permission.denied, isTrue);
      expect(permission.needsUserAction, isTrue);
    });

    test('refresh 只查询：不触发权限请求', () async {
      var requested = 0;
      final permission = LocalNetworkPermission(
        needsPermission: true,
        request: () async {
          requested++;
          return LocalNetworkPermissionStatus.granted;
        },
        check: () async => LocalNetworkPermissionStatus.denied,
      );

      expect(await permission.refresh(), isFalse);
      expect(requested, 0);
      expect(permission.denied, isTrue);
    });

    test('永久拒绝：ensure 不再请求，UI 动作是去系统设置', () async {
      var requested = 0;
      final permission = LocalNetworkPermission(
        needsPermission: true,
        request: () async {
          requested++;
          return LocalNetworkPermissionStatus.denied;
        },
        check: () async => LocalNetworkPermissionStatus.permanentlyDenied,
      );

      expect(await permission.refresh(), isFalse);
      expect(permission.permanentlyDenied, isTrue);
      // 系统不再弹窗：连用户显式请求也不发（只能去系统设置）。
      expect(await permission.ensure(retry: true), isFalse);
      expect(requested, 0);
      expect(permission.granted, isFalse);
    });

    test('被拒（可再问）与永久拒绝分开', () async {
      final permission = LocalNetworkPermission(
        needsPermission: true,
        request: () async => LocalNetworkPermissionStatus.denied,
      );
      expect(await permission.ensure(), isFalse);
      expect(permission.permanentlyDenied, isFalse);
      expect(permission.status, LocalNetworkPermissionStatus.denied);
    });
  });

  group('地址簿持久化', () {
    late SharedPreferences prefs;
    late SyncStateStore state;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      state = SyncStateStore(
        preferences: prefs,
        secrets: MemorySyncSecretStore(),
      );
      await state.init();
    });

    test('添加 / 学到信息合并 / 删除，跨重启保留', () async {
      await state
          .addManualPeer(const ManualPeer(host: '192.168.1.23', name: '书房'));
      expect(state.manualPeers.single.name, '书房');

      // 首次接触学到 deviceId 与端点端口（同名地址合并，不新增条目）；
      // 对端广播的设备名不覆盖用户命名。
      await state.learnManualPeer(state.manualPeers.single.mergeLearned(
        deviceId: 'devB',
        httpPort: 41000,
        name: '设备B',
      ));
      expect(state.manualPeers, hasLength(1));
      expect(state.manualPeers.single.deviceId, 'devB');
      expect(state.manualPeers.single.httpPort, 41000);
      expect(state.manualPeers.single.name, '书房', reason: '用户命名优先');

      // 用户再次提交同一地址 = 显式改名。
      await state
          .addManualPeer(const ManualPeer(host: '192.168.1.23', name: '新名字'));
      expect(state.manualPeers.single.name, '新名字');
      expect(state.manualPeers.single.deviceId, 'devB');

      // 未命名条目才吸收学到的名称。
      await state.addManualPeer(const ManualPeer(host: '10.0.0.9'));
      await state
          .learnManualPeer(const ManualPeer(host: '10.0.0.9', name: '设备C'));
      expect(
        state.manualPeers.firstWhere((p) => p.host == '10.0.0.9').name,
        '设备C',
      );

      // 本机端点端口持久化（对端要记住本机）。
      await state.setLanHttpPort(42000);

      final reloaded =
          SyncStateStore(preferences: prefs, secrets: MemorySyncSecretStore());
      await reloaded.init();
      expect(reloaded.manualPeers, hasLength(2));
      expect(
        reloaded.manualPeers
            .firstWhere((p) => p.host == '192.168.1.23')
            .deviceId,
        'devB',
      );
      expect(reloaded.lanHttpPort, 42000);

      await reloaded.removeManualPeer('192.168.1.23');
      await reloaded.removeManualPeer('10.0.0.9');
      expect(reloaded.manualPeers, isEmpty);
    });

    test('空地址不入库；ManualPeer JSON 往返', () {
      final peer = ManualPeer.fromJson(const {
        'host': ' 10.0.0.5 ',
        'httpPort': 40000,
        'deviceId': 'devX',
        'name': 'X',
      });
      expect(peer!.host, '10.0.0.5');
      expect(ManualPeer.fromJson(const {'host': ' '}), isNull);
      expect(ManualPeer.fromJson(null), isNull);
      final round = ManualPeer.fromJson(peer.toJson());
      expect(round!.deviceId, 'devX');
      expect(round.httpPort, 40000);
    });
  });
}
