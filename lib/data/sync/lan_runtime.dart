/// 本机局域网运行时：传输 / 发现 / 配对共享的「这台机器」事实。
///
/// 三个模块原本各自重列同一批闭包（设备身份、口令、发现密钥、本机端口、
/// 地址、权限与蜂窝判定、已知 / 手动对端、端点回写、换网事件）。这些事实
/// 只在这里声明一次，组合根构造一个实例交给三者，避免同一个闭包传两遍。
///
/// 可注入的测试替身（`RawDatagramSocket` binder、时钟、报文流与发送器、
/// HTTP 客户端）仍留在各模块构造函数：它们替换的是「怎么收发」，不是
/// 「这台机器是谁」。与 `SyncTransportRuntime` 分工：后者拥有 ensure /
/// start / stop 的生命周期，本类只描述机器，不驱动生命周期。
library;

import 'dart:async';
import 'dart:typed_data';

import '../../domain/models/device_sync.dart';
import '../../utils/peer_address.dart';

/// 局域网三件套（`LanSyncTransport` / `LanDiscovery` / `LanPairingService`）
/// 共用的本机事实与回写出口。
///
/// 本机端口是运行期事实而不是配置：HTTP 端点由传输绑定、UDP 探测端口由
/// 发现层绑定，绑定后经 [bindHttpPort] / [bindProbePort] 回填；配对与公告
/// 都从这里读同一份，不再各自向绑定者借闭包。
class LanRuntime {
  LanRuntime({
    required this.deviceId,
    required this.deviceName,
    required this.readPassphrase,
    required this.writePassphrase,
    this.ensurePassphrase,
    required this.hasGroup,
    this.discoveryKey,
    this.permissionGate,
    this.isCellular,
    this.localAddresses,
    this.knownPeers,
    this.manualPeers,
    this.rememberPeerEndpoint,
    this.onPeerResolved,
    this.networkChanges,
    this.preferredHttpPort,
    this.onHttpPortBound,
    this.udpPort = ManualPeer.defaultProbePort,
    this._httpPort = 0,
    this._probePort,
  });

  /// 设备身份（`sync_device_id_v2` 的稳定 id）。
  final String deviceId;

  final String Function() deviceName;
  final Future<String?> Function() readPassphrase;
  final Future<void> Function(String passphrase) writePassphrase;

  /// 「没有口令就生成一个」的入口；未接线时配对服务自行生成并写入。
  final Future<String> Function()? ensurePassphrase;

  /// 是否已有同步组（名册非空或任一路传输真正接触成功过）。
  final bool Function() hasGroup;

  /// 口令 → 发现密钥（HKDF）。null = 没有发现层接线。
  final Future<Uint8List> Function(String passphrase)? discoveryKey;

  /// 局域网权限门：传输启动前过门，拒绝时状态为 `permission_denied`。
  final Future<bool> Function()? permissionGate;

  /// 当前是否蜂窝网络（蜂窝下 0 广播 / 组播）。
  final bool Function()? isCellular;

  /// 本机可路由地址（公告 `addrs` 与配对探测包共用）。
  final Future<List<String>> Function()? localAddresses;

  /// 已通过验证的持久化端点。
  final List<LanPeerEndpoint> Function()? knownPeers;

  /// 手动对端地址簿（发现失败时的兜底）。
  final List<ManualPeer> Function()? manualPeers;

  /// 验证成功后回写端点（发现回写与配对补端点共用同一出口）。
  final Future<void> Function(LanPeerEndpoint endpoint)? rememberPeerEndpoint;

  /// 手动条目首次接触后回写学到的身份 / 端口。
  final void Function(ManualPeer learned)? onPeerResolved;

  /// `connectivity_plus` 原始事件：换网重绑 UDP。
  final Stream<void>? networkChanges;

  /// 上次绑定过的 HTTP 端口（持久化值；对端靠它记住本机）。
  final int Function()? preferredHttpPort;

  /// HTTP 端口降级后回写持久化值。
  final void Function(int port)? onHttpPortBound;

  /// UDP 探测端口偏好（绑定失败时降级到系统分配端口）。
  final int udpPort;

  int _httpPort;

  /// null = 没有发现层接线；0 = 发现层已接线但两族都不可用。
  int? _probePort;

  /// 本机 HTTP 端点端口（0 = 尚未绑定）。
  int get httpPort => _httpPort;

  /// 本机公告 / MSP 探测端口；null = 没有发现层接线。
  int? get probePort => _probePort;

  /// 已知端点：持久化端点 + 手动地址簿里已学到 HTTP 端口的条目。
  ///
  /// 发现层与传输读同一份合并结果：手动地址既是候选，也是公告的单播目标。
  List<LanPeerEndpoint> get knownEndpoints {
    final endpoints = <LanPeerEndpoint>[];
    for (final endpoint in knownPeers?.call() ?? const <LanPeerEndpoint>[]) {
      if (endpoint.deviceId == deviceId) continue;
      endpoints.add(endpoint);
    }
    for (final manual in manualPeers?.call() ?? const <ManualPeer>[]) {
      if (manual.httpPort <= 0 || manual.deviceId == deviceId) continue;
      endpoints.add(
        LanPeerEndpoint(
          deviceId: manual.deviceId,
          host: normalizePeerHost(manual.host),
          httpPort: manual.httpPort,
          probePort: manual.probePort,
          verifiedAt: 0,
        ),
      );
    }
    return endpoints;
  }

  void bindHttpPort(int port) {
    _httpPort = port;
  }

  void bindProbePort(int port) {
    _probePort = port;
  }
}
