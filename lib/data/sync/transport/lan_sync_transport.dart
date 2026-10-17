import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/sync_transport.dart';
import '../../../utils/device_id.dart';
import '../../../utils/peer_address.dart';
import '../sync_crypto.dart';

/// 局域网直连传输：UDP 探测（IPv4 广播 + IPv6 组播 + 单播）发现 +
/// 各设备内置 HTTP 端点。
///
/// 协议（明文层只有设备名 / 端口 / 地址候选 / 内容指纹与日志头部，数据全部加密）：
/// - UDP `molia-sync.probe` JSON：`{m, v, deviceId, name, port, udpPort, addrs,
///   reply, snapshotId, journalHead}`；收到非回复探测时向**来源地址**单播应答
///   （携带自己的 HTTP 端口、探测端口、可路由地址候选、内容指纹与日志头部），
///   并把发送方登记为对端——主动探测方也在线，没必要等它先应答；
/// - HTTP `GET  /molia-sync/v1/journal?since=<游标>`：返回该游标之后的**增量
///   窗口**；游标落后于窗口起点（条目已被裁剪）时返回全量快照（bootstrap）；
/// - HTTP `POST /molia-sync/v1/journal`：接收对端的增量窗口；
/// - HTTP `GET  /molia-sync/v1/snapshot`：返回本机全量快照（anti-entropy
///   兜底；未注入增量提供者时增量端点也回它）；
/// - HTTP `POST /molia-sync/v1/snapshot`：接收对端全量快照。
///
/// 端口可降级（Windows 宿主把大段端口标记为系统保留，errno 10013；见
/// `docs/pitfalls.md`）：UDP 绑定失败改绑系统分配端口（对端按探测包里自报的
/// `udpPort` 单播回来），HTTP 绑定失败改绑随机端口并持久化。**UDP 不可用不算
/// 传输失败**：广播 / 组播发现降级，手动地址簿的 HTTP 直连照常。
///
/// 地址候选（`addrs`）：IPv6 组播的源地址必然是 link-local（不能用于 HTTP），
/// 所以探测与应答都随包交换本机可路由地址（IPv4 + 全局 / ULA IPv6，排除回环
/// 与 link-local）；对端按候选地址优先、观测源地址兜底的顺序尝试连接。
///
/// 跳过拉取的判据：探测应答里的 `snapshotId` 与本机缓存的「上次拉到的对端
/// 指纹」一致，且本机游标已到对端日志头部（没有还没消费的条目）——内容没变
/// 就不传、不解密、不合并。
///
/// 信任模型：数据用同步口令派生密钥加密，能解密者即已授权；HTTP 层不做
/// 额外鉴权（载荷是密文，无法解密者拿不到内容）。
///
/// 发现失败（AP 隔离 / 多网段 / 防火墙 / VPN）时用 [manualPeersProvider]
/// 提供的手动地址簿做单播探测；权限被拒（Android 17 起局域网默认阻断）时
/// 传输不启动并把原因记为 `permission_denied`——**手动地址救不了权限**。
class LanSyncTransport implements SyncTransport {
  LanSyncTransport({
    required this.deviceId,
    required String Function() deviceName,
    required SyncCodec codec,
    required Future<String?> Function() passphraseProvider,
    required Future<SyncEnvelope> Function() snapshotProvider,
    Future<SyncEnvelope> Function(int since)? journalProvider,
    String Function()? snapshotIdProvider,
    int Function()? journalHeadProvider,
    List<({String host, int port})>? probeTargets,
    List<ManualPeer> Function()? manualPeersProvider,
    void Function(ManualPeer learned)? onPeerResolved,
    int Function()? httpPortProvider,
    void Function(int port)? onHttpPortBound,
    Future<bool> Function()? permissionGate,
    bool Function(String deviceId)? ignoredPeersProvider,
    Future<List<String>> Function()? localAddressesProvider,
    Future<RawDatagramSocket> Function(InternetAddress address, int port)?
        udpBinder,
    int udpPort = defaultUdpPort,
    Duration probeWindow = const Duration(milliseconds: 1200),
    Duration requestTimeout = const Duration(seconds: 3),
  })  : _deviceName = deviceName,
        _codec = codec,
        _passphraseProvider = passphraseProvider,
        _snapshotProvider = snapshotProvider,
        _journalProvider = journalProvider,
        _snapshotIdProvider = snapshotIdProvider,
        _journalHeadProvider = journalHeadProvider,
        _probeTargets = probeTargets ?? const [],
        _manualPeersProvider = manualPeersProvider,
        _onPeerResolved = onPeerResolved,
        _httpPortProvider = httpPortProvider,
        _onHttpPortBound = onHttpPortBound,
        _permissionGate = permissionGate,
        _ignoredPeersProvider = ignoredPeersProvider,
        _localAddressesProvider = localAddressesProvider,
        _udpBinder = udpBinder ?? _bindDatagram,
        _udpPort = udpPort,
        _probeWindow = probeWindow,
        _requestTimeout = requestTimeout;

  static const int defaultUdpPort = ManualPeer.defaultProbePort;
  static const String snapshotPath = '/molia-sync/v1/snapshot';
  static const String journalPath = '/molia-sync/v1/journal';

  /// IPv6 组播探测地址（IPv4 `255.255.255.255` 广播的对应物；ff02::/16 是
  /// 链路本地范围，接口 zone 由内核按发送接口补全）。
  static const String probeMulticastHost = 'ff02::4d4f:4c49';

  /// 单个探测 / 应答携带的候选地址上限（无界列表只会撑大包与尝试次数）。
  static const int maxAdvertisedAddresses = 8;

  /// 单个对端记住的探测端点上限（候选地址可能有多个，全试一遍没必要）。
  static const int maxProbeEndpointsPerPeer = 4;

  /// 登记的对端 / 探测端点上限（防伪造探测灌爆内存）。
  static const int maxRememberedPeers = 32;

  /// 快照体积上限（含大量统计事件时留足余量；超出视为异常数据丢弃）。
  static const int maxSnapshotBytes = 32 * 1024 * 1024;

  final String deviceId;
  final String Function() _deviceName;
  final SyncCodec _codec;
  final Future<String?> Function() _passphraseProvider;
  final Future<SyncEnvelope> Function() _snapshotProvider;

  /// 增量窗口提供者：`since` = 请求方游标；返回该游标之后的窗口，或游标
  /// 落后于窗口起点时的全量快照。未注入时只服务全量快照。
  final Future<SyncEnvelope> Function(int since)? _journalProvider;

  /// 本机最近一轮快照的内容指纹（探测应答携带；空 = 尚未产出快照）。
  final String Function()? _snapshotIdProvider;

  /// 本机 journal 头部（探测应答携带；对端据此判断「有没有还没消费的条目」）。
  final int Function()? _journalHeadProvider;

  /// 测试注入：向指定地址单播探测（空 = 仅广播 / 组播，生产路径）。
  final List<({String host, int port})> _probeTargets;

  /// 手动对端地址簿（发现失败时的兜底）。
  final List<ManualPeer> Function()? _manualPeersProvider;

  /// 首次接触学到 deviceId / httpPort / 名称后回写地址簿。
  final void Function(ManualPeer learned)? _onPeerResolved;

  /// 本机 HTTP 端口持久化：端口每次随机会让对端记不住本机。
  final int Function()? _httpPortProvider;
  final void Function(int port)? _onHttpPortBound;

  /// 局域网权限门：返回 false 时传输不启动（原因 = permission_denied）。
  final Future<bool> Function()? _permissionGate;

  /// 本地忽略的设备（不拉取 / 不推送它们的载荷）。
  final bool Function(String deviceId)? _ignoredPeersProvider;

  /// 本机可路由候选地址提供者（组合根注入 `LocalEndpointsService`；
  /// 未注入时按 [NetworkInterface.list] 现算）。
  final Future<List<String>> Function()? _localAddressesProvider;

  /// 测试注入：UDP 绑定实现（模拟系统保留端口 / 网络栈完全不可用）。
  final Future<RawDatagramSocket> Function(InternetAddress address, int port)
      _udpBinder;

  final int _udpPort;
  final Duration _probeWindow;
  final Duration _requestTimeout;

  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();
  final List<_Peer> _peers = [];

  /// 上一轮接触过的对端探测端点（去重键 → 该对端的候选探测地址）：
  /// 端口降级的对端不在标准端口上，广播 / 组播到不了它，只能单播；候选
  /// 地址（对端自报的可路由地址）在前、观测源地址兜底（v6 组播源是
  /// link-local，要带 zone 才能用）。
  final Map<String, List<({String host, int port})>> _probeEndpoints = {};

  /// 上次成功拉到的各对端内容指纹（`deviceId` / 主机 → `snapshotId`）：
  /// 探测应答一致时跳过 GET。进程内缓存，重启后首轮重新拉一次。
  final Map<String, String> _peerSnapshotIds = {};
  final Logger _logger = Logger('molia.sync.lan');

  int _broadcastCount = 0;
  int _snapshotGetCount = 0;

  /// 广播探测发送次数（测试断言「空闲轮不广播」用；广播只在 `pull` 内发出）。
  int get broadcastCount => _broadcastCount;

  /// 快照 GET 次数（测试断言「未变跳过」用）。
  int get snapshotGetCount => _snapshotGetCount;

  RawDatagramSocket? _udp4;
  RawDatagramSocket? _udp6;
  HttpServer? _http;
  bool _running = false;

  /// 本机可路由地址缓存（探测包与应答包共用；`_discoverPeers` 每轮刷新）。
  List<String> _ownAddresses = const [];

  /// 启动失败的技术细节（HTTP 端点起不来、权限不足等）；null = 未失败。
  String? _startError;
  String? _unavailableReason;

  /// 广播 / 组播发送失败（网络策略 / 缺少广播 entitlement）。
  bool _broadcastUnavailable = false;

  /// 本进程内发现过对端：用于区分「一直没对端」与「零应答」——
  /// 后者更可能是网络隔离（AP 隔离 / VPN / 防火墙）而不是没人在线。
  bool _everDiscoveredPeer = false;

  @override
  String get kind => SyncTransportKind.lan;

  @override
  bool get isRunning => _running;

  /// 局域网端点按需给出实时快照（[snapshotProvider]），没有发布延迟。
  @override
  bool get servesLiveSnapshot => true;

  /// 本机实际绑定的 UDP 探测端口（0 = UDP 不可用）：端口降级后广播 / 组播
  /// 到不了本机，对端要按这个端口单播（随探测包自报）。
  @override
  int get discoveryPort =>
      _running ? (_udp4?.port ?? _udp6?.port ?? 0) : 0;

  @override
  String? get unavailableReason => _running ? null : _unavailableReason;

  @override
  String? get unavailableDetail => _running ? null : _startError;

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;

  int get _httpPort => _http?.port ?? 0;

  @override
  Future<void> start() async {
    if (_running) return;

    // 权限在前：Android 17 起局域网默认阻断，没有权限时绑定 / 收发包都会失败，
    // 直接给用户可行动的状态（授权 或 转 WebDAV），不做无意义的尝试。
    final gate = _permissionGate;
    if (gate != null && !await gate()) {
      _unavailableReason = SyncUnavailableReason.permissionDenied;
      _startError = '局域网访问权限未授予';
      _logger.warning('局域网权限未授予，传输不启动');
      return;
    }

    // HTTP 是载荷通道（拉取 / 推送 / 手动直连全靠它）：它起不来才是真的
    // 传输失败，原因留在 [unavailableReason] 供 UI 呈现。
    final rememberedPort = _httpPortProvider?.call() ?? 0;
    try {
      final http = await _bindHttp(rememberedPort);
      _http = http;
      http.listen(_onHttpRequest);
    } catch (e) {
      _startError = '$e';
      _unavailableReason = SyncUnavailableReason.startFailed;
      _logger.warning('局域网传输启动失败（HTTP 端点）', e);
      await _http?.close(force: true);
      _http = null;
      return;
    }

    // UDP 是可降级的发现能力：端口被系统保留（Windows 镜像模式 WSL 的
    // 保留块，errno 10013）或占用时改绑系统分配端口；两族都不可用只让发现
    // 降级（手动地址 / WebDAV 仍可用），传输照常运行。
    final udp = await _bindUdp(_udpPort);
    _udp4 = udp.v4;
    _udp6 = udp.v6;
    final v4 = _udp4;
    final v6 = _udp6;
    if (v4 != null) v4.listen((event) => _onDatagram(v4, event));
    if (v6 != null) v6.listen((event) => _onDatagram(v6, event));
    if (v4 == null && v6 == null) {
      _logger.warning('UDP 探测不可用（IPv4 / IPv6 绑定均失败）：发现只剩手动地址与直连');
    }

    _running = true;
    _startError = null;
    _unavailableReason = null;
    if (_http!.port != rememberedPort) _onHttpPortBound?.call(_http!.port);
    // 首轮探测应答要带地址候选：启动时先刷一次（枚举失败只降级为不带候选）。
    await _refreshOwnAddresses();
  }

  /// 双栈 HTTP 绑定：IPv6（`v6Only: false` 一行同时服务 v4/v6）→ IPv4 →
  /// 端口 0 的同两级。首选端口被占用 / 落在系统保留块时退回随机端口并
  /// 持久化（对端记不住随机端口，所以端口持久化语义不变）。
  Future<HttpServer> _bindHttp(int preferredPort) async {
    final attempts = <(InternetAddress, int)>[
      if (preferredPort > 0) ...[
        (InternetAddress.anyIPv6, preferredPort),
        (InternetAddress.anyIPv4, preferredPort),
      ],
      (InternetAddress.anyIPv6, 0),
      (InternetAddress.anyIPv4, 0),
    ];
    Object? lastError;
    for (final (address, port) in attempts) {
      try {
        return await HttpServer.bind(address, port, v6Only: false);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('HTTP 端点绑定失败');
  }

  /// 双栈 UDP 绑定；每族独立降级（见 [_bindUdpFamily]），全部失败返回空对。
  Future<({RawDatagramSocket? v4, RawDatagramSocket? v6})> _bindUdp(
    int preferredPort,
  ) async {
    final v4 = await _bindUdpFamily(InternetAddress.anyIPv4, preferredPort);
    final v6 = await _bindUdpFamily(InternetAddress.anyIPv6, preferredPort);
    return (v4: v4, v6: v6);
  }

  /// 单族 UDP 绑定：先试首选端口（`reuseAddress: true`），失败记警告（含
  /// 端口与 `SocketException.osError?.errorCode`）后改绑 0；再补上该族的
  /// 广播 / 组播能力（能力失败只降级能力，不丢单播）。
  Future<RawDatagramSocket?> _bindUdpFamily(
    InternetAddress address,
    int preferredPort,
  ) async {
    final ports = preferredPort > 0 ? [preferredPort, 0] : [0];
    for (final port in ports) {
      try {
        final socket = await _udpBinder(address, port);
        try {
          if (address.type == InternetAddressType.IPv4) {
            socket.broadcastEnabled = true;
          } else {
            socket.joinMulticast(InternetAddress(probeMulticastHost));
            socket.multicastHops = 1;
          }
        } catch (e) {
          // iOS 缺 multicast entitlement / 系统策略拦截时的正常降级：
          // 该能力不可用（发送会失败），单播与 HTTP 照常。
          _logger.warning('UDP ${address.address}:$port 探测能力启用失败（继续用单播）', e);
        }
        return socket;
      } on SocketException catch (e) {
        final fallback = port == preferredPort && preferredPort > 0;
        _logger.warning(
          'UDP 绑定 ${address.address}:$port 失败'
          '（errno=${e.osError?.errorCode}）'
          '${fallback ? '，改绑系统分配端口' : '，该族探测不可用'}',
        );
      } catch (e) {
        _logger.warning('UDP 绑定 ${address.address}:$port 失败', e);
      }
    }
    return null;
  }

  @override
  Future<void> stop() async {
    _running = false;
    // 关闭后不残留上次的失败原因：状态面只表达「已关闭」，重新启用时由
    // start 重新判定可用性。
    _unavailableReason = null;
    _startError = null;
    _peers.clear();
    _ownAddresses = const [];
    _udp4?.close();
    _udp4 = null;
    _udp6?.close();
    _udp6 = null;
    await _http?.close(force: true);
    _http = null;
  }

  @override
  Future<SyncPullResult> pull([SyncPullRequest request = SyncPullRequest.none]) async {
    if (!_running) {
      return SyncPullResult(
        error: SyncIssue(
          code: _unavailableReason ?? SyncIssueCode.startFailed,
          detail: _startError,
        ),
      );
    }
    final passphrase = await _passphraseProvider();
    if (passphrase == null || passphrase.trim().isEmpty) {
      return const SyncPullResult(
        error: SyncIssue(code: SyncIssueCode.noPassphrase),
      );
    }

    // 本地忽略的设备不参与本轮（幽灵 / 已失联设备的处置）。
    final peers = (await _discoverPeers())
        .where((peer) => !(_ignoredPeersProvider?.call(peer.deviceId) ?? false))
        .toList();
    final envelopes = <SyncEnvelope>[];
    var failed = 0;
    var skipped = 0;
    var bytesIn = 0;
    SyncIssue? firstError;
    for (final peer in peers) {
      final cursor = request.cursorFor(peer.deviceId);
      final needsFull = request.fullPeers.contains(peer.deviceId);
      // 内容指纹与本机上次拉到的一致、且本机游标已到对端日志头部：
      // 没有还没消费的条目，跳过 GET + 解密 + 合并（对端清单为空时不可能命中）。
      final cached = _peerSnapshotIds[peer.key];
      final upToDate = peer.journalHead == null || cursor >= peer.journalHead!;
      if (!needsFull &&
          peer.snapshotId.isNotEmpty &&
          cached == peer.snapshotId &&
          upToDate) {
        skipped++;
        continue;
      }
      final bytes = needsFull
          ? await _fetchSnapshot(peer)
          : await _fetchJournal(peer, cursor);
      if (bytes == null) {
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.peerReadFailed,
          args: {'peer': peer.label},
        );
        continue;
      }
      bytesIn += bytes.length;
      try {
        final envelope = _codec.decrypt(bytes, passphrase);
        envelopes.add(envelope);
        final fingerprint = envelope.snapshotId.isNotEmpty
            ? envelope.snapshotId
            : peer.snapshotId;
        if (fingerprint.isNotEmpty) {
          _peerSnapshotIds[peer.key] = fingerprint;
        }
      } on SyncCryptoException {
        // 对端口令不同 / 数据损坏：跳过该对端，不影响其他设备。
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.peerDecryptFailed,
          args: {'peer': peer.label},
        );
      }
    }
    return SyncPullResult(
      envelopes: envelopes,
      peersSeen: peers.length,
      skippedUnchanged: skipped,
      failedPeers: failed,
      bytesIn: bytesIn,
      seenIds: [
        for (final peer in peers)
          if (peer.deviceId.isNotEmpty) peer.deviceId,
      ],
      // 至少一个对端可达（拉到或未变跳过）才算接触成功；探测到但全部
      // 读取 / 解密失败仍是「所有对端都不可达」。
      contacted: peers.length > failed,
      error: firstError ?? _discoveryIssue(peers),
    );
  }

  /// 未发现任何对端时的原因（有对端则为 null）。
  ///
  /// UDP 探测完全不可用（两族都绑不上）优先：此时广播 / 组播 / 单播探测都
  /// 发不出去，出路是手动地址直连与 WebDAV。其次是广播发送失败；最后是
  /// 「发现过对端、本轮零应答」——后者通常是网络隔离，提示手动地址与 WebDAV。
  SyncIssue? _discoveryIssue(List<_Peer> peers) {
    if (peers.isNotEmpty) return null;
    if (_udp4 == null && _udp6 == null) {
      return const SyncIssue(code: SyncIssueCode.probePortUnavailable);
    }
    if (_broadcastUnavailable) {
      return const SyncIssue(code: SyncIssueCode.broadcastUnavailable);
    }
    final manual = _manualPeersProvider?.call() ?? const <ManualPeer>[];
    if (_everDiscoveredPeer && manual.isEmpty) {
      return const SyncIssue(code: SyncIssueCode.discoverySilent);
    }
    return null;
  }

  @override
  Future<SyncPushResult> push(SyncEnvelope envelope) async {
    if (!_running) return SyncPushResult.none;
    final passphrase = await _passphraseProvider();
    if (passphrase == null || passphrase.trim().isEmpty) {
      return const SyncPushResult(
        error: SyncIssue(code: SyncIssueCode.noPassphrase),
      );
    }
    final payload = _codec.encrypt(envelope, passphrase);
    final path = envelope.isDelta ? journalPath : snapshotPath;
    final succeededIds = <String>[];
    final failedIds = <String>[];
    SyncIssue? firstError;
    for (final peer in List.of(_peers)) {
      if (await _postSnapshot(peer, payload, path)) {
        succeededIds.add(peer.deviceId);
      } else {
        failedIds.add(peer.deviceId);
        firstError ??= SyncIssue(
          code: SyncIssueCode.peerPushFailed,
          args: {'peer': peer.label},
        );
      }
    }
    return SyncPushResult(
      succeededPeers: succeededIds.length,
      failedPeers: failedIds.length,
      succeededIds: succeededIds,
      failedIds: failedIds,
      bytesOut: payload.length * succeededIds.length,
      error: firstError,
    );
  }

  /// 局域网直连没有远端存储：显式清理远端文件对它不适用。
  @override
  Future<bool> deleteRemote(String deviceId) async => false;

  /// 广播 / 组播探测 + 单播探测（测试注入目标、手动地址簿、上轮学到的
  /// 对端探测端点），收集应答（清空过期对端；仅保留本轮应答者）。
  Future<List<_Peer>> _discoverPeers() async {
    _peers.clear();
    final manualPeers = _manualPeersProvider?.call() ?? const <ManualPeer>[];

    // 地址簿里已学到端口的对端先入队：即使探测应答被网络策略吞掉也能直连
    // （端口是学到的、不是猜的；连不上会被如实计为失败）。
    for (final manual in manualPeers) {
      if (manual.httpPort <= 0) continue;
      _rememberPeer(_Peer(
        deviceId: manual.deviceId,
        host: normalizePeerHost(manual.host),
        port: manual.httpPort,
        name: manual.name,
        probePort: manual.probePort,
      ));
    }

    final v4 = _udp4;
    final v6 = _udp6;
    // UDP 不可用不是死路：地址簿里学到过 HTTP 端口的对端照常直连拉取
    // （降级机器上纯 HTTP 直连必须可用）。
    if (v4 == null && v6 == null) return List.of(_peers);

    await _refreshOwnAddresses();
    final probe = utf8.encode(jsonEncode({
      'm': 'molia-sync.probe',
      'v': 1,
      'deviceId': deviceId,
      'name': _deviceName(),
      'port': _httpPort,
      'udpPort': discoveryPort,
      'reply': false,
      if (_ownAddresses.isNotEmpty) 'addrs': _ownAddresses,
      if (_snapshotIdProvider?.call().isNotEmpty ?? false)
        'snapshotId': _snapshotIdProvider!.call(),
      if (_journalHeadProvider != null)
        'journalHead': _journalHeadProvider.call(),
    }));
    if (_probeTargets.isEmpty) {
      _sendBroadcastProbe(probe, v4, v6);
    }
    // 单播目标：测试注入 + 手动地址簿（探测端口缺省用本传输的 UDP 端口，
    // 生产里所有设备同端口；测试 / 多实例场景可显式指定）+ 上一轮学到的
    // 对端探测端点（降级端口只有对端自己知道，广播 / 组播到不了它）。
    final targets = <({String host, int port})>[];
    void addTarget(String host, int port) {
      final normalized = normalizePeerHost(host);
      if (normalized.isEmpty || port <= 0) return;
      if (targets.any((t) => t.host == normalized && t.port == port)) return;
      targets.add((host: normalized, port: port));
    }

    for (final target in _probeTargets) {
      addTarget(target.host, target.port);
    }
    for (final manual in manualPeers) {
      addTarget(manual.host, manual.probePort > 0 ? manual.probePort : _udpPort);
    }
    for (final endpoints in _probeEndpoints.values) {
      for (final endpoint in endpoints) {
        addTarget(endpoint.host, endpoint.port);
      }
    }
    for (final target in targets) {
      _sendProbeTo(probe, v4, v6, target.host, target.port);
    }
    await Future<void>.delayed(_probeWindow);
    return List.of(_peers);
  }

  /// 广播 + 组播探测：v4 走 255.255.255.255，v6 走 [probeMulticastHost]；
  /// 与单播目标一样，发送失败只降级（记为「广播不可用」供未发现对端时提示）。
  void _sendBroadcastProbe(
    List<int> probe,
    RawDatagramSocket? v4,
    RawDatagramSocket? v6,
  ) {
    var sent = false;
    if (v4 != null) {
      try {
        v4.send(probe, InternetAddress('255.255.255.255'), _udpPort);
        sent = true;
      } catch (_) {
        // 广播被系统策略拒绝（iOS entitlement / 网络策略）。
      }
    }
    if (v6 != null) {
      try {
        final bytes = v6.send(
          probe,
          InternetAddress(probeMulticastHost),
          _udpPort,
        );
        if (bytes > 0) sent = true;
      } catch (_) {
        // 组播发送失败（无组播路由 / 策略拦截）。
      }
    }
    _broadcastCount++;
    _broadcastUnavailable = !sent;
  }

  /// 单播探测：按目标地址的族选 socket（跨族 `send` 会静默返回 0，不是抛错）。
  void _sendProbeTo(
    List<int> probe,
    RawDatagramSocket? v4,
    RawDatagramSocket? v6,
    String host,
    int port,
  ) {
    final address = InternetAddress.tryParse(normalizePeerHost(host));
    if (address == null || port <= 0) return;
    final sockets = address.type == InternetAddressType.IPv6
        ? [v6, v4]
        : [v4, v6];
    for (final socket in sockets) {
      if (socket == null) continue;
      try {
        if (socket.send(probe, address, port) > 0) return;
      } catch (_) {
        // 换另一族再试（地址族不匹配时换过去也只会失败）。
      }
    }
  }

  /// 收到 datagram：解析探测（应答登记对端、非应答登记对端并单播回包）。
  ///
  /// 回包用**收到它的那个 socket**：族一致（v6 的 link-local 源需要 v6
  /// socket），link-local 的 zone 信息保留在 `datagram.address` 对象里。
  void _onDatagram(RawDatagramSocket socket, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) return;
      message = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    if (message['m'] != 'molia-sync.probe') return;
    final peerId = message['deviceId'];
    if (peerId is! String || peerId.isEmpty || peerId == deviceId) return;
    final port = message['port'];
    if (port is! num) return;
    if (_ignoredPeersProvider?.call(peerId) ?? false) return;

    final peer = _Peer(
      deviceId: peerId,
      host: _observedHost(datagram.address),
      port: port.toInt(),
      name: message['name'] is String ? message['name'] as String : '',
      snapshotId:
          message['snapshotId'] is String ? message['snapshotId'] as String : '',
      journalHead: message['journalHead'] is num
          ? (message['journalHead'] as num).toInt()
          : null,
      addresses: _parseCandidateAddresses(message['addrs']),
      // 优先用观测到的来源端口：v4 / v6 各自独立降级时两族的端口不同，
      // 包内自报的是「首选族」的端口，回不到另一族的 socket 上。
      probePort: datagram.port > 0
          ? datagram.port
          : ((message['udpPort'] as num?)?.toInt() ?? 0),
    );

    if (message['reply'] == true) {
      _everDiscoveredPeer = true;
      _rememberPeer(peer);
      _resolveManualPeer(peer);
      return;
    }
    // 非回复探测：发送方也在线，先登记为对端（HTTP 直连不必等它应答），
    // 再向来源地址单播应答（携带本机端口 / 探测端口 / 地址候选）。
    _rememberPeer(peer);
    _resolveManualPeer(peer);
    final ownSnapshotId = _snapshotIdProvider?.call() ?? '';
    final reply = utf8.encode(jsonEncode({
      'm': 'molia-sync.probe',
      'v': 1,
      'deviceId': deviceId,
      'name': _deviceName(),
      'port': _httpPort,
      'udpPort': discoveryPort,
      'reply': true,
      if (_ownAddresses.isNotEmpty) 'addrs': _ownAddresses,
      if (ownSnapshotId.isNotEmpty) 'snapshotId': ownSnapshotId,
      if (_journalHeadProvider != null)
        'journalHead': _journalHeadProvider.call(),
    }));
    try {
      socket.send(reply, datagram.address, datagram.port);
    } catch (_) {
      // 应答失败仅让该对端本轮发现不到本机。
    }
  }

  /// 观测到的源地址（v6 组播源的 link-local 带 `%zone`；HTTP 兜底时保留）。
  String _observedHost(InternetAddress address) => address.address.trim();

  /// 解析对端自报的候选地址：只要 IP 字面量（非回环 / 非 link-local）、
  /// 去重、上限 [maxAdvertisedAddresses]。
  List<String> _parseCandidateAddresses(Object? raw) {
    if (raw is! List) return const [];
    final hosts = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      final host = normalizePeerHost(item);
      if (!_isHttpCandidate(host)) continue;
      if (hosts.contains(host)) continue;
      hosts.add(host);
      if (hosts.length >= maxAdvertisedAddresses) break;
    }
    return hosts;
  }

  bool _isHttpCandidate(String host) {
    if (host.isEmpty || host.contains('%')) return false;
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    return !address.isLoopback && !address.isLinkLocal;
  }

  /// 本机可路由地址（IP 字面量、非回环、非 link-local、去重、上限
  /// [maxAdvertisedAddresses]）：组合根注入的 [LocalEndpointsService]，
  /// 未注入时按 [NetworkInterface.list] 现算。
  Future<void> _refreshOwnAddresses() async {
    try {
      final provider = _localAddressesProvider;
      final addresses =
          provider != null ? await provider() : await _listLocalAddresses();
      _ownAddresses = _limitAddresses(addresses);
    } catch (e) {
      _logger.fine('枚举本机可路由地址失败（探测包将不带地址候选）', e);
    }
  }

  static Future<List<String>> _listLocalAddresses() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.any,
    );
    final hosts = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final host = address.address.trim();
        if (host.isEmpty || address.isLoopback || address.isLinkLocal) continue;
        if (address.type == InternetAddressType.IPv6 && host.contains('%')) {
          continue;
        }
        if (!hosts.contains(host)) hosts.add(host);
      }
    }
    return hosts;
  }

  static List<String> _limitAddresses(Iterable<String> addresses) => [
        for (final host in addresses)
          if (host.isNotEmpty) host,
      ].take(maxAdvertisedAddresses).toList();

  /// 登记本轮发现的对端（同一 key 覆盖；上限防伪造探测灌爆）。
  ///
  /// 认领到设备身份时顺手清掉同端点的未认领条目（地址簿手工条目先入队、
  /// 探测应答后到达时会各占一条，不清会重复 GET 同一个端点）。
  void _rememberPeer(_Peer peer) {
    if (peer.probePort > 0) {
      final endpoints = <({String host, int port})>[];
      void add(String host) {
        final normalized = normalizePeerHost(host);
        if (normalized.isEmpty) return;
        if (endpoints.any((existing) => existing.host == normalized)) return;
        if (endpoints.length >= maxProbeEndpointsPerPeer) return;
        endpoints.add((host: normalized, port: peer.probePort));
      }

      for (final address in peer.addresses) {
        add(address);
      }
      add(peer.host);
      if (endpoints.isNotEmpty) {
        _probeEndpoints.remove(peer.key);
        _probeEndpoints[peer.key] = endpoints;
        while (_probeEndpoints.length > maxRememberedPeers) {
          _probeEndpoints.remove(_probeEndpoints.keys.first);
        }
      }
    }
    _peers.removeWhere((existing) =>
        existing.key == peer.key ||
        (peer.deviceId.isNotEmpty &&
            existing.deviceId.isEmpty &&
            existing.host == peer.host &&
            existing.port == peer.port));
    _peers.add(peer);
    while (_peers.length > maxRememberedPeers) {
      _peers.removeAt(0);
    }
  }

  /// 手动条目首次接触（或地址 / 端口变化）后回写学到的信息。
  ///
  /// host 比较用归一形式（`[2409::1]` 与 `2409::1` / 大小写差异不该让
  /// 「已存在的手动条目」学不到设备身份）。
  void _resolveManualPeer(_Peer peer) {
    final manualPeers = _manualPeersProvider?.call() ?? const <ManualPeer>[];
    final peerHost = _normalizeHost(peer.host);
    for (final entry in manualPeers) {
      if (_normalizeHost(entry.host) != peerHost) continue;
      final probePort =
          peer.probePort > 0 && peer.probePort != entry.probePort
              ? peer.probePort
              : null;
      if (entry.deviceId == peer.deviceId &&
          entry.httpPort == peer.port &&
          probePort == null) {
        return;
      }
      _onPeerResolved?.call(entry.mergeLearned(
        probePort: probePort,
        httpPort: peer.port,
        deviceId: peer.deviceId,
        name: peer.name,
      ));
      return;
    }
  }

  static String _normalizeHost(String host) =>
      InternetAddress.tryParse(host.trim())?.address ?? host.trim();

  Future<Uint8List?> _fetchSnapshot(_Peer peer) => _getPayload(peer, snapshotPath);

  /// 拉取增量窗口（带本机游标；对端在游标落后于窗口起点时回全量快照）。
  ///
  /// 协议固定走增量端点：对端未注入增量提供者时它自己回全量快照
  /// （[journalProvider] 是**服务端**能力，不影响请求路径）。
  Future<Uint8List?> _fetchJournal(_Peer peer, int since) =>
      _getPayload(peer, journalPath, query: {'since': '$since'});

  /// GET 对端端点：按候选地址 → 观测源地址依次尝试（可路由地址优先；
  /// IPv6 组播源的 link-local 只在候选都失败后兜底）。
  Future<Uint8List?> _getPayload(
    _Peer peer,
    String path, {
    Map<String, String>? query,
  }) async {
    _snapshotGetCount++;
    for (final host in peer.hosts) {
      final client = HttpClient()..connectionTimeout = _requestTimeout;
      try {
        final request = await client
            .getUrl(_peerUri(host, peer.port, path, query))
            .timeout(_requestTimeout);
        final response = await request.close().timeout(_requestTimeout);
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          continue;
        }
        return await _readBody(response);
      } catch (_) {
        // 该地址不可达 / 超时：换下一个候选地址。
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  Future<bool> _postSnapshot(_Peer peer, Uint8List payload, String path) async {
    for (final host in peer.hosts) {
      final client = HttpClient()..connectionTimeout = _requestTimeout;
      try {
        final request = await client
            .postUrl(_peerUri(host, peer.port, path, null))
            .timeout(_requestTimeout);
        request.headers.contentType = ContentType.binary;
        request.add(payload);
        final response = await request.close().timeout(_requestTimeout);
        await response.drain<void>();
        if (response.statusCode == HttpStatus.ok) return true;
      } catch (_) {
        // 该地址推送失败：换下一个候选地址。
      } finally {
        client.close(force: true);
      }
    }
    // 推送失败交由对端下一轮拉取兜底（失败计数上抛给报告）。
    return false;
  }

  /// 对端端点 URI：`Uri` 构造自动给 IPv6 主机加方括号、编码 zone
  /// （`fe80::1%eth0` → `[fe80::1%25eth0]`），字符串拼接做不到。
  Uri _peerUri(
    String host,
    int port,
    String path,
    Map<String, String>? query,
  ) =>
      Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: path,
        queryParameters: query == null || query.isEmpty ? null : query,
      );

  Future<void> _onHttpRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path != snapshotPath && path != journalPath) {
        request.response.statusCode = HttpStatus.notFound;
      } else if (request.method == 'GET') {
        final passphrase = await _passphraseProvider();
        if (passphrase == null || passphrase.trim().isEmpty) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          final envelope = path == journalPath
              ? await _journalFor(request.uri.queryParameters['since'])
              : await _snapshotProvider();
          final payload = _codec.encrypt(envelope, passphrase);
          request.response.headers.contentType = ContentType.binary;
          request.response.add(payload);
        }
      } else if (request.method == 'POST') {
        final bytes = await _readBody(request);
        if (bytes == null) {
          request.response.statusCode = HttpStatus.badRequest;
        } else {
          final passphrase = await _passphraseProvider();
          if (passphrase == null || passphrase.trim().isEmpty) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
          } else {
            try {
              final envelope = _codec.decrypt(bytes, passphrase);
              if (!_incoming.isClosed) _incoming.add(envelope);
            } on SyncCryptoException {
              request.response.statusCode = HttpStatus.badRequest;
            }
          }
        }
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      }
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        // 连接可能已断开。
      }
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        // 同上。
      }
    }
  }

  /// 增量端点的服务端语义：请求游标之后的窗口；未注入提供者时回全量快照。
  Future<SyncEnvelope> _journalFor(String? sinceParam) async {
    final provider = _journalProvider;
    if (provider == null) return _snapshotProvider();
    final since = int.tryParse(sinceParam ?? '') ?? SyncPullRequest.noCursor;
    return provider(since);
  }

  Future<Uint8List?> _readBody(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > maxSnapshotBytes) return null;
    }
    return builder.toBytes();
  }

  static Future<RawDatagramSocket> _bindDatagram(
    InternetAddress address,
    int port,
  ) =>
      RawDatagramSocket.bind(address, port, reuseAddress: true);
}

class _Peer {
  final String deviceId;

  /// 观测到的源地址（UDP 包来源；IPv6 组播源为 link-local，带 zone）。
  final String host;
  final int port;
  final String name;

  /// 对端探测应答携带的内容指纹（空 = 对端未提供 / 尚未产出快照）。
  final String snapshotId;

  /// 对端探测应答携带的 journal 头部（null = 对端未提供：按指纹判「未变」）。
  final int? journalHead;

  /// 对端自报的可路由候选地址（`addrs`）。
  final List<String> addresses;

  /// 对端自报的 UDP 探测端口（0 = 未提供；供下一次单播探测）。
  final int probePort;

  const _Peer({
    required this.deviceId,
    required this.host,
    required this.port,
    required this.name,
    this.snapshotId = '',
    this.journalHead,
    this.addresses = const [],
    this.probePort = 0,
  });

  /// HTTP 主机尝试顺序：候选地址（IPv4 → 全局 / ULA IPv6，可路由者优先）
  /// → 观测到的源地址（组播源的 link-local 兜底）。
  List<String> get hosts {
    final ordered = <String>[
      for (final rank in const [0, 1, 3])
        for (final host in addresses)
          if (_hostRank(host) == rank) host,
    ];
    if (host.isNotEmpty && !ordered.contains(host)) ordered.add(host);
    return ordered;
  }

  /// 地址可达性排序：IPv4 = 0，全局 / ULA IPv6 = 1，其它地址（link-local /
  /// 带 zone / 非 IP 字面量）最后。
  static int _hostRank(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null) return 3;
    if (address.type == InternetAddressType.IPv4) return 0;
    if (address.isLinkLocal || address.isLoopback || host.contains('%')) {
      return 3;
    }
    return 1;
  }

  /// 去重键：认领到设备 id 后按 id，未认领（手动地址首轮）按主机。
  String get key => deviceId.isNotEmpty ? deviceId : 'host:$host';

  /// 日志 / 错误文案用的人类可读标识（设备名 > 设备 id 短号 > 主机）。
  String get label {
    if (name.isNotEmpty) return name;
    if (deviceId.isNotEmpty) return shortDeviceId(deviceId);
    return host;
  }
}
