import 'dart:async';
import 'dart:typed_data';

import 'package:molia/data/sync/lan_runtime.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 单测的 LAN runtime：机器事实一次建好，每个用例只覆盖自己关心的那一项。
///
/// 这些默认值对应「一台刚启动、还没接发现层」的设备；用例通过参数或
/// `..bindHttpPort(...)` / `..bindProbePort(...)` 补上端口。
LanRuntime lanRuntime({
  required String deviceId,
  String? deviceName,
  String? passphrase,
  Future<String?> Function()? readPassphrase,
  Future<void> Function(String passphrase)? writePassphrase,
  Future<String> Function()? ensurePassphrase,
  bool Function()? hasGroup,
  bool Function()? isCellular,
  Future<List<String>> Function()? localAddresses,
  List<LanPeerEndpoint> Function()? knownPeers,
  List<ManualPeer> Function()? manualPeers,
  Future<void> Function(LanPeerEndpoint endpoint)? rememberPeerEndpoint,
  void Function(ManualPeer learned)? onPeerResolved,
  Future<bool> Function()? permissionGate,
  Stream<void>? networkChanges,
  SyncCodec? codec,
  Future<Uint8List> Function(String passphrase)? discoveryKey,
  int Function()? preferredHttpPort,
  void Function(int port)? onHttpPortBound,
  int udpPort = 47825,
  int httpPort = 0,
  int? probePort,
}) {
  final keyCodec = codec ?? SyncCodec(iterations: 1000);
  return LanRuntime(
    deviceId: deviceId,
    deviceName: () => deviceName ?? deviceId,
    readPassphrase: readPassphrase ?? () async => passphrase,
    writePassphrase: writePassphrase ?? (value) async {},
    ensurePassphrase: ensurePassphrase,
    hasGroup: hasGroup ?? () => false,
    discoveryKey: discoveryKey ?? (value) async => keyCodec.discoveryKey(value),
    permissionGate: permissionGate,
    isCellular: isCellular,
    localAddresses: localAddresses,
    knownPeers: knownPeers,
    manualPeers: manualPeers,
    rememberPeerEndpoint: rememberPeerEndpoint,
    onPeerResolved: onPeerResolved,
    networkChanges: networkChanges,
    preferredHttpPort: preferredHttpPort,
    onHttpPortBound: onHttpPortBound,
    udpPort: udpPort,
    httpPort: httpPort,
    probePort: probePort,
  );
}
