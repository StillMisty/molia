import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/sync_transport.dart';
import '../../../utils/peer_address.dart';
import '../pairing/pairing_http.dart';
import '../sync_codec_port.dart';
import '../sync_crypto.dart';
import '../sync_peer_candidate.dart';
import '../sync_pull_plan.dart';
import 'lan_discovery.dart';
import 'lan_pairing_packet.dart';

/// 局域网直连传输：`MSD/1` 发现 + 各设备内置 HTTP 端点。
///
/// 职责划分是硬约束：**UDP 只负责发现，HTTP 是数据与存活通道**。
/// - 发现层（[LanDiscovery]）用二进制 `MSD/1` 公告 + HMAC 认证交换设备 id /
///   名称 / 端点端口 / 内容指纹；旧 JSON 探测包是未知字节，静默丢弃；
/// - HTTP `GET  /molia-sync/v2/journal?since=<游标>`：返回该游标之后的**增量
///   窗口**；游标落后于窗口起点（条目已被裁剪）时返回全量快照（bootstrap）；
/// - HTTP `POST /molia-sync/v2/journal`：接收对端的增量窗口；
/// - HTTP `GET  /molia-sync/v2/snapshot`：返回本机全量快照（anti-entropy
///   兜底；未注入增量提供者时增量端点也回它）；
/// - HTTP `POST /molia-sync/v2/snapshot`：接收对端全量快照。
///
/// 路径是硬断代的一部分：旧版 `/molia-sync/v1/*` 一律 404。
///
/// 端口可降级（Windows 宿主把大段端口标记为系统保留，errno 10013；见
/// `docs/pitfalls.md`）：UDP 绑定失败改绑系统分配端口；HTTP 绑定失败改绑
/// 随机端口并持久化。**UDP 不可用不算传输失败**：广播 / 组播发现降级，
/// 手动地址与已知端点的 HTTP 直连照常。
///
/// 跳过拉取的判据：公告里的 `snap` 与本机缓存的「上次拉到的对端指纹」一致，
/// 且本机游标已到对端日志头部（没有还没消费的条目）——内容没变就不传、
/// 不解密、不合并。
///
/// 信任模型：发现报文用同步口令派生的独立 discovery key 认证；数据用同步
/// 口令派生密钥加密。HTTP 层不做额外鉴权（载荷是密文，无法解密者拿不到
/// 内容）。能通过 MAC + 解密者即已授权。
///
/// 耗电预算：正常有候选轮 ≤8 个单播探测 + HTTP、等 400ms、0 广播；蜂窝网
/// 0 广播 / 组播；后台取消公告与重连计时器，不主动探测。
class LanSyncTransport
    implements SyncTransport, SyncSightingSource, SyncLanLifecycle {
  LanSyncTransport({
    required this.deviceId,
    required String Function() deviceName,
    required SyncCodecPort codec,
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
    Future<bool> Function(int port)? httpProbe,
    Future<bool> Function()? permissionGate,
    Future<List<String>> Function()? localAddressesProvider,
    Future<RawDatagramSocket> Function(InternetAddress address, int port)?
        udpBinder,
    List<LanPeerEndpoint> Function()? knownPeersProvider,
    void Function(LanPeerEndpoint verified)? onPeerVerified,
    bool Function()? isCellular,
    int Function()? nowMs,
    Stream<void>? networkChanges,
    int udpPort = defaultUdpPort,
    Duration probeWindow = const Duration(milliseconds: 1200),
    Duration requestTimeout = const Duration(seconds: 3),
  })  : _codec = codec,
        _passphraseProvider = passphraseProvider,
        _snapshotProvider = snapshotProvider,
        _journalProvider = journalProvider,
        _probeTargets = probeTargets ?? const [],
        _manualPeersProvider = manualPeersProvider,
        _onPeerResolved = onPeerResolved,
        _httpPortProvider = httpPortProvider,
        _onHttpPortBound = onHttpPortBound,
        _httpProbe = httpProbe,
        _permissionGate = permissionGate,
        _knownPeersProvider = knownPeersProvider,
        _onPeerVerified = onPeerVerified,
        _isCellular = isCellular,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _networkChanges = networkChanges,
        _udpPort = udpPort,
        _requestTimeout = requestTimeout {
    _discovery = LanDiscovery(
      deviceId: deviceId,
      deviceName: deviceName,
      discoveryKeyProvider: _ensureDiscoveryKey,
      httpPortProvider: () => _http?.port ?? 0,
      probePortProvider: () => _discovery.advertisedProbePort,
      snapshotIdProvider: snapshotIdProvider,
      journalHeadProvider: journalHeadProvider,
      knownPeersProvider: _knownEndpoints,
      probeTargetsProvider: _probeTargetList,
      localAddressesProvider: localAddressesProvider,
      udpBinder: udpBinder,
      udpPort: udpPort,
      candidateWindow: probeWindow < const Duration(milliseconds: 400)
          ? probeWindow
          : const Duration(milliseconds: 400),
      fullWindow: probeWindow,
      nowMs: _nowMs,
      isCellular: isCellular,
    );
  }

  static const int defaultUdpPort = ManualPeer.defaultProbePort;
  static const String snapshotPath = '/molia-sync/v2/snapshot';
  static const String journalPath = '/molia-sync/v2/journal';

  /// IPv6 组播发现地址（与发现层常量同源，保留给旧调用方）。
  static const String probeMulticastHost = Msd1.ipv6MulticastHost;

  /// 单个公告携带的候选地址上限（与 `MSD/1` 协议常量一致）。
  static const int maxAdvertisedAddresses = Msd1.maxAddresses;

  /// 单对端记住的探测端点上限（兼容旧调用方；发现层按 presence 合并）。
  static const int maxProbeEndpointsPerPeer = 4;

  /// 登记的 presence 上限（与发现层一致）。
  static const int maxRememberedPeers = LanDiscovery.maxPeers;

  /// 单个对端最多尝试的 HTTP 地址数（候选地址可能有多个，全试没必要）。
  static const int maxHttpAddressesPerPeer = SyncPeerCandidate.maxHosts;

  /// 单个对端每轮的总请求预算（3 个地址 × 3s 超时会拖住整轮）。
  static const Duration peerRequestBudget = Duration(seconds: 4);

  /// 后台超过该时长再回前台才重绑 UDP（短切换不值得付重绑成本）。
  static const Duration resumeRebindThreshold = Duration(seconds: 15);

  /// HTTP 端点 loopback 探活预算。
  static const Duration loopbackProbeTimeout = Duration(milliseconds: 500);

  /// 快照体积上限（含大量统计事件时留足余量；超出视为异常数据丢弃）。
  static const int maxSnapshotBytes = 32 * 1024 * 1024;

  final String deviceId;
  final SyncCodecPort _codec;
  final Future<String?> Function() _passphraseProvider;
  final Future<SyncEnvelope> Function() _snapshotProvider;

  /// 增量窗口提供者：`since` = 请求方游标；返回该游标之后的窗口，或游标
  /// 落后于窗口起点时的全量快照。未注入时只服务全量快照。
  final Future<SyncEnvelope> Function(int since)? _journalProvider;

  /// 测试注入：向指定地址单播探测（空 = 仅广播 / 组播，生产路径）。
  final List<({String host, int port})> _probeTargets;

  /// 手动对端地址簿（发现失败时的兜底）。
  final List<ManualPeer> Function()? _manualPeersProvider;

  /// 首次接触学到 deviceId / httpPort / 名称后回写地址簿。
  final void Function(ManualPeer learned)? _onPeerResolved;

  /// 本机 HTTP 端口持久化：端口每次随机会让对端记不住本机。
  final int Function()? _httpPortProvider;
  final void Function(int port)? _onHttpPortBound;

  /// 测试注入：HTTP 端点存活探测（默认走 loopback TCP connect）。
  final Future<bool> Function(int port)? _httpProbe;

  /// 局域网权限门：返回 false 时传输不启动（原因 = permission_denied）。
  final Future<bool> Function()? _permissionGate;

  /// 已通过验证的持久化端点（#42 注入；本 issue 先支持）。
  final List<LanPeerEndpoint> Function()? _knownPeersProvider;

  /// 验证成功后回写端点（#42 注入；本 issue 先支持）。
  final void Function(LanPeerEndpoint verified)? _onPeerVerified;

  /// 当前是否蜂窝网络（蜂窝下 0 广播 / 组播，只直连已知端点）。
  final bool Function()? _isCellular;

  /// 可注入时钟（测试 nonce 去重 / 限流窗口）。
  final int Function() _nowMs;

  /// `connectivity_plus` 原始事件（#42 接线；本 issue 支持注入测试）。
  final Stream<void>? _networkChanges;

  final int _udpPort;
  final Duration _requestTimeout;

  late final LanDiscovery _discovery;
  StreamSubscription<LanPeerSighting>? _sightingSub;
  StreamSubscription<void>? _networkSub;

  /// 配对 HTTP 处理器（组合根在 start 之前注入；null = 本传输不提供配对）。
  PairingHttpHandler? _pairing;

  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();

  /// 上次成功拉到的各对端内容指纹（`deviceId` / 主机 → `snapshotId`）：
  /// 公告一致时跳过 GET。进程内缓存，重启后首轮重新拉一次。
  final Map<String, String> _peerSnapshotIds = {};

  final Logger _logger = Logger('molia.sync.lan');

  HttpServer? _http;
  bool _running = false;
  int? _hiddenAt;
  int _snapshotGetCount = 0;

  /// 本进程内发现过对端：用于区分「一直没对端」与「零应答」——
  /// 后者更可能是网络隔离（AP 隔离 / VPN / 防火墙）而不是没人在线。
  bool _everDiscoveredPeer = false;

  String? _keyPassphrase;
  Uint8List? _cachedDiscoveryKey;

  /// 启动失败的技术细节（HTTP 端点起不来、权限不足等）；null = 未失败。
  String? _startError;
  String? _unavailableReason;

  @override
  String get kind => SyncTransportKind.lan;

  @override
  bool get isRunning => _running;

  /// 局域网端点按需给出实时快照（[snapshotProvider]），没有发布延迟。
  @override
  bool get servesLiveSnapshot => true;

  /// 本机实际绑定的 UDP 探测端口（分族；0 = 该族不可用）。
  @override
  ({int v4, int v6}) get discoveryPorts => _discovery.discoveryPorts;

  /// 本机 HTTP 端点端口（配对请求携带；0 = 尚未启动）。
  int get httpPort => _http?.port ?? 0;

  /// 本机公告用的探测端口（单播目标）。
  int get advertisedProbePort => _discovery.advertisedProbePort;

  /// MSP 配对发现事件（不经过 MSD 的 presence / sightings）。
  Stream<LanPairingDatagram> get pairingDatagrams =>
      _discovery.pairingDatagrams;

  /// 发送 MSP 包（host 为空 = 广播 / 组播）。
  Future<bool> sendPairingDatagram(
    Uint8List packet, {
    String? host,
    int? port,
  }) =>
      _discovery.sendPairingPacket(packet, host: host, port: port);

  /// 在启动前注入配对服务；运行中替换会让 HTTP 路由与生命周期脱节。
  void attachPairing(PairingHttpHandler handler) {
    if (_running) {
      throw StateError('局域网传输运行中不能替换配对处理器');
    }
    _pairing = handler;
  }

  /// 认证通过的公告 / 应答事件（引擎据此唤醒同步轮）。
  @override
  Stream<LanPeerSighting> get sightings => _discovery.sightings;

  /// 拉取轮主动广播次数（测试断言「空闲轮 0 广播」用；公告 burst 不计）。
  int get broadcastCount => _discovery.broadcastCount;

  /// 快照 GET 次数（测试断言「未变跳过」用）。
  int get snapshotGetCount => _snapshotGetCount;

  /// presence 条数（诊断 / 测试用）。
  int get presenceCount => _discovery.presence.length;

  /// 网络代次（换网重绑后增加；测试 / 诊断用）。
  int get networkEpoch => _discovery.networkEpoch;

  @override
  String? get unavailableReason => _running ? null : _unavailableReason;

  @override
  String? get unavailableDetail => _running ? null : _startError;

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;

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
    final opened = await _openHttpWithLiveness(rememberedPort);
    if (opened == null) {
      _startError = '局域网 HTTP 端点绑定失败';
      _unavailableReason = SyncUnavailableReason.startFailed;
      _logger.warning('局域网传输启动失败（HTTP 端点）');
      return;
    }
    _http = opened;
    _running = true;
    _hiddenAt = null;
    _startError = null;
    _unavailableReason = null;
    if (opened.port != rememberedPort) _onHttpPortBound?.call(opened.port);

    _sightingSub = _discovery.sightings.listen((sighting) {
      _everDiscoveredPeer = true;
      _resolveManualPeer(sighting);
    });
    _networkSub = _networkChanges?.listen(
      (_) {
        unawaited(onNetworkChanged());
      },
      onError: (Object _) {},
    );

    // 配对服务与传输同生命周期：先订阅 MSP 事件，再绑 UDP，避免启动窗口
    // 内收到探测却没人处理。配对失败只降级配对能力，不阻断同步本体。
    try {
      await _pairing?.start();
    } catch (e) {
      _logger.warning('配对服务启动失败（同步照常）', e);
    }
    // UDP 是可降级的发现能力：两族都不可用只让发现降级（手动地址 / WebDAV
    // 仍可用），传输照常运行。启动公告 burst 由发现层调度。
    await _discovery.start();
  }

  /// 打开 HTTP 端点并做一次 loopback 探活；失败重绑同一端口，再失败退随机
  /// 端口（并持久化）。返回的 server 已开始 listen。
  Future<HttpServer?> _openHttpWithLiveness(int preferredPort) async {
    var http = await _tryBindHttp(preferredPort);
    if (http == null) return null;
    if (await _probeHttp(http.port)) {
      http.listen(_onHttpRequest);
      return http;
    }
    // 绑上了但 loopback 连不上：常见于挂起恢复后 socket 处于半死状态。
    // 先重绑同一端口（保持对端记忆），仍不行再退随机端口。
    await http.close(force: true);
    http = await _tryBindHttp(preferredPort);
    if (http != null && await _probeHttp(http.port)) {
      http.listen(_onHttpRequest);
      return http;
    }
    await http?.close(force: true);
    http = await _tryBindHttp(0);
    if (http != null && await _probeHttp(http.port)) {
      http.listen(_onHttpRequest);
      return http;
    }
    await http?.close(force: true);
    return null;
  }

  /// HTTP 端点存活探测：默认 loopback TCP connect（500ms），测试可注入。
  Future<bool> _probeHttp(int port) =>
      _httpProbe?.call(port) ?? _loopbackAlive(port);

  Future<HttpServer?> _tryBindHttp(int preferredPort) async {
    try {
      return await _bindHttp(preferredPort);
    } catch (e) {
      _logger.warning('HTTP 端点绑定失败（preferred=$preferredPort）', e);
      return null;
    }
  }

  /// 双栈 HTTP 绑定：IPv6（`v6Only: false` 一行同时服务 v4/v6）→ IPv4 →
  /// 端口 0 的同两级。首选端口被占用 / 落在系统保留块时退回随机端口并
  /// 持久化。
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

  /// loopback TCP 探活（500ms）：能连上说明监听仍在，不必做 HTTP 请求。
  Future<bool> _loopbackAlive(int port) async {
    if (port <= 0) return false;
    for (final address in [
      InternetAddress.loopbackIPv4,
      InternetAddress.loopbackIPv6,
    ]) {
      try {
        final socket = await Socket.connect(
          address,
          port,
          timeout: loopbackProbeTimeout,
        );
        socket.destroy();
        return true;
      } catch (_) {
        // 换另一族再试。
      }
    }
    return false;
  }

  @override
  Future<void> stop() async {
    _running = false;
    // 关闭后不残留上次的失败原因：状态面只表达「已关闭」，重新启用时由
    // start 重新判定可用性。
    _unavailableReason = null;
    _startError = null;
    _hiddenAt = null;
    await _sightingSub?.cancel();
    _sightingSub = null;
    await _networkSub?.cancel();
    _networkSub = null;
    // 先停配对再停 UDP：配对服务停止时清 pending 密钥，不再依赖发现层。
    try {
      await _pairing?.stop();
    } catch (e) {
      _logger.warning('配对服务停止失败', e);
    }
    await _discovery.stop();
    _peerSnapshotIds.clear();
    _everDiscoveredPeer = false;
    await _http?.close(force: true);
    _http = null;
  }

  /// 回前台：隐藏超过 15s 才重绑 UDP + 探活 HTTP；随后公告 burst。
  @override
  Future<void> onAppResumed() async {
    if (!_running) return;
    final hiddenAt = _hiddenAt;
    _hiddenAt = null;
    final longHidden = hiddenAt != null &&
        _nowMs() - hiddenAt >= resumeRebindThreshold.inMilliseconds;
    if (longHidden) {
      await _ensureHttpAlive();
      // 重绑失败已把传输置为未运行：本轮回前台到此为止，等下一轮
      // `SyncTransportRuntime.ensureRunning` 重新 start。
      if (!_running) return;
    }
    await _discovery.onAppResumed(rebind: longHidden);
    _pairing?.onAppResumed();
  }

  /// 退后台：取消公告 / 重连计时器；不主动探测。
  @override
  void onAppHidden() {
    _hiddenAt = _nowMs();
    _discovery.onAppHidden();
    _pairing?.onAppHidden();
  }

  /// 换网（connectivity 事件）：重扫接口，指纹变化时重绑 UDP 并公告。
  @override
  Future<void> onNetworkChanged() async {
    if (!_running) return;
    await _discovery.onNetworkChanged();
  }

  /// 本地变更但本轮推送零对端：单次定向公告（只单播）。
  @override
  Future<void> announceLocalChange() async {
    if (!_running) return;
    final key = await _ensureDiscoveryKey();
    _discovery.updateKey(key);
    await _discovery.announceLocalChange();
  }

  Future<void> _ensureHttpAlive() async {
    final http = _http;
    if (http == null) return;
    if (await _probeHttp(http.port)) return;
    // 挂起恢复后监听可能半死：先重绑同一端口，失败再退随机端口。
    final port = http.port;
    await http.close(force: true);
    _http = null;
    var rebound = await _tryBindHttp(port);
    var alive = rebound != null && await _probeHttp(rebound.port);
    if (!alive) {
      await rebound?.close(force: true);
      rebound = await _tryBindHttp(0);
      alive = rebound != null && await _probeHttp(rebound.port);
    }
    if (!alive || rebound == null) {
      await rebound?.close(force: true);
      _logger.warning('回前台后 HTTP 端点重绑失败');
      // 置为未运行：否则 isRunning 仍是 true，unavailableReason 的 getter
      // 会返回 null，UI / 引擎看不到失败；下一轮 start 可重新绑定。
      _running = false;
      _startError = '回前台后局域网 HTTP 端点重绑失败';
      _unavailableReason = SyncUnavailableReason.startFailed;
      await _sightingSub?.cancel();
      _sightingSub = null;
      await _networkSub?.cancel();
      _networkSub = null;
      await _discovery.stop();
      return;
    }
    rebound.listen(_onHttpRequest);
    _http = rebound;
    if (rebound.port != port) _onHttpPortBound?.call(rebound.port);
  }

  @override
  Future<SyncPullResult> pull(
      [SyncPullRequest request = SyncPullRequest.none]) async {
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
    final key = await _ensureDiscoveryKey();
    _discovery.updateKey(key);

    final window = request.window ?? SyncRoundWindow(startedAt: _nowMs());
    final plan = request.plan;
    await _discovery.discover(force: plan.forceDiscovery);
    final attempted = <String>{};
    final stats = _PullStats();
    await _pullCandidates(request, window, passphrase, attempted, stats);

    // 全部 HTTP 失败且非蜂窝：最多补一次广播探测，不无限重试。
    if (stats.httpFailedAny > 0 && !stats.contacted && !_isCellularNow) {
      await _discovery.rediscover();
      await _pullCandidates(request, window, passphrase, attempted, stats);
    }

    return SyncPullResult(
      envelopes: stats.envelopes,
      peersSeen: stats.expectedSeen + stats.tentativeContacted,
      skippedUnchanged: stats.skipped,
      failedPeers: stats.failed,
      bytesIn: stats.bytesIn,
      seenIds: stats.seenIds,
      // 成功读取过（含另一地址 / 另一轮重试）的设备不记失败：先按 id 收齐
      // 原因，结果里再剔除成功者，避免同一设备既算成功又算失败。
      failedIssues: {
        for (final entry in stats.failedIssues.entries)
          if (!stats.seenIds.contains(entry.key)) entry.key: entry.value,
      },
      // 至少一个对端可达（拉到或未变跳过）才算接触成功。
      contacted: stats.contacted,
      error: stats.expectedSeen > 0
          ? stats.firstError
          : (_discoveryIssue() ?? stats.firstError),
    );
  }

  Future<void> _pullCandidates(
    SyncPullRequest request,
    SyncRoundWindow window,
    String passphrase,
    Set<String> attempted,
    _PullStats stats,
  ) async {
    final plan = request.plan;
    for (final peer in _candidates(window.startedAt)) {
      if (!attempted.add(peer.key)) continue;
      if (peer.expected) stats.expectedSeen++;
      final intent = plan.intentFor(peer.deviceId);
      final cached = _peerSnapshotIds[peer.key];
      // 判定只经统一计划：局域网把「本轮听到的 presence」标成可信证据，
      // 上一轮 presence 的旧头部不会被当成跳过依据。
      final decision = decideSyncPull(
        intent: intent,
        evidence: SyncPeerPullEvidence(
          token: peer.snapshotId,
          cachedToken: cached,
          fresh: peer.snapshotFresh,
          journalHead: peer.journalHead,
          headTrusted: peer.snapshotFresh && peer.snapshotId.isNotEmpty,
        ),
      );
      if (decision.action == SyncPullAction.skip) {
        stats.skipped++;
        stats.contacted = true;
        if (!peer.expected) stats.tentativeContacted++;
        _rememberSeen(stats, peer);
        continue;
      }

      final fetched = decision.action == SyncPullAction.full
          ? await _fetchSnapshot(peer)
          : await _fetchJournal(peer, decision.cursor);
      if (fetched == null) {
        stats.httpFailedAny++;
        // 失败归属到具体设备（含试探性对端：UI 仍要能看出是哪台没连上），
        // 但不进 seenIds——读取失败不是成功接触。
        _rememberFailure(stats, peer, SyncIssueCode.peerReadFailed);
        // 试探性对端（只有持久化端点）失败不计数，也不把整轮打成 partial。
        if (peer.expected) {
          stats.failed++;
          stats.firstError ??= SyncIssue(
            code: SyncIssueCode.peerReadFailed,
            args: {'peer': peer.label},
          );
        }
        continue;
      }
      stats.bytesIn += fetched.bytes.length;
      try {
        final envelope = await _codec.decrypt(fetched.bytes, passphrase);
        stats.envelopes.add(envelope);
        stats.contacted = true;
        _everDiscoveredPeer = true;
        if (!peer.expected) stats.tentativeContacted++;
        // 端点可能被同组的另一台设备复用（旧持久化记录 / DHCP 复用）：
        // 解密后的 deviceId 才是数据的主人。不能把端点写回候选的旧 id，
        // 也不能把这次接触记到旧 id 的 seenIds 上。
        final identityMismatch = peer.deviceId.isNotEmpty &&
            envelope.deviceId.isNotEmpty &&
            peer.deviceId != envelope.deviceId;
        final fingerprint = envelope.snapshotId.isNotEmpty
            ? envelope.snapshotId
            : (identityMismatch || !peer.snapshotFresh ? '' : peer.snapshotId);
        if (fingerprint.isNotEmpty) {
          _peerSnapshotIds[identityMismatch ? envelope.deviceId : peer.key] =
              fingerprint;
        }
        if (identityMismatch) {
          _peerSnapshotIds.remove(peer.key);
          if (!stats.seenIds.contains(envelope.deviceId)) {
            stats.seenIds.add(envelope.deviceId);
          }
        } else {
          _rememberSeen(stats, peer);
          _verifyPeer(peer, fetched.host);
        }
      } on SyncCryptoException {
        // 对端口令不同 / 数据损坏：跳过该对端，不影响其他设备。
        _rememberFailure(stats, peer, SyncIssueCode.peerDecryptFailed);
        if (peer.expected) {
          stats.failed++;
          stats.firstError ??= SyncIssue(
            code: SyncIssueCode.peerDecryptFailed,
            args: {'peer': peer.label},
          );
        }
      }
    }
  }

  /// 接触成功的对端 id 进 seenIds（名册的「最近接触」据此更新）。
  void _rememberSeen(_PullStats stats, SyncPeerCandidate peer) {
    if (peer.deviceId.isEmpty) return;
    if (!stats.seenIds.contains(peer.deviceId)) {
      stats.seenIds.add(peer.deviceId);
    }
  }

  /// 读取 / 解密失败落到具体设备（结果里再剔除同一设备已成功的记录）。
  ///
  /// 同一设备多条候选地址都失败时保留第一次的原因：先读失败 / 先解密失败
  /// 哪个先发生，就说明卡在哪一步。
  void _rememberFailure(
    _PullStats stats,
    SyncPeerCandidate peer,
    String code,
  ) {
    if (peer.deviceId.isEmpty) return;
    stats.failedIssues.putIfAbsent(
      peer.deviceId,
      () => SyncIssue(code: code, args: {'peer': peer.label}),
    );
  }

  /// 未发现任何对端时的原因（有对端接触成功则为 null）。
  ///
  /// UDP 发现完全不可用优先：此时广播 / 组播 / 单播公告都发不出去，出路是
  /// 手动地址直连与 WebDAV。其次是广播发送失败；最后是「发现过对端、本轮
  /// 零应答」——后者通常是网络隔离，提示手动地址与 WebDAV。
  SyncIssue? _discoveryIssue() {
    // 后台 / 蜂窝下发现层被策略跳过：没有候选不代表网络隔离，不能复用
    // discoverySilent / broadcastUnavailable 误导用户。
    if (_discovery.isHidden || _isCellularNow) return null;
    final ports = _discovery.discoveryPorts;
    if (ports.v4 == 0 && ports.v6 == 0) {
      return const SyncIssue(code: SyncIssueCode.probePortUnavailable);
    }
    if (_discovery.broadcastUnavailable) {
      return const SyncIssue(code: SyncIssueCode.broadcastUnavailable);
    }
    final manual = _manualPeersProvider?.call() ?? const <ManualPeer>[];
    if (_everDiscoveredPeer && manual.isEmpty) {
      return const SyncIssue(code: SyncIssueCode.discoverySilent);
    }
    return null;
  }

  @override
  Future<SyncPushResult> push(
    SyncEnvelope envelope, {
    SyncRoundWindow? window,
  }) async {
    if (!_running) return SyncPushResult.none;
    final passphrase = await _passphraseProvider();
    if (passphrase == null || passphrase.trim().isEmpty) {
      return const SyncPushResult(
        error: SyncIssue(code: SyncIssueCode.noPassphrase),
      );
    }
    final payload = await _codec.encrypt(envelope, passphrase);
    final path = envelope.isDelta ? journalPath : snapshotPath;
    final succeededIds = <String>[];
    final failedIds = <String>[];
    var succeeded = 0;
    var failed = 0;
    SyncIssue? firstError;
    // 推送直接使用候选端点，不再依赖「上一轮 pull 留下的 _peers」。本轮起点
    // 由引擎显式传入（与 pull 同一个窗口）：presence 的 lastHeardAt 来自
    // 同一次轮次的探测窗口，刚在 pull 里听到的对端仍算预期对端，失败才会计
    // 入 failedIds（名册看不到真实推送失败的问题由此避免）。
    for (final peer in _candidates(window?.startedAt ?? _nowMs())) {
      final host = await _postSnapshot(peer, payload, path);
      if (host != null) {
        succeeded++;
        _everDiscoveredPeer = true;
        if (peer.deviceId.isNotEmpty) succeededIds.add(peer.deviceId);
        _verifyPeer(peer, host);
        continue;
      }
      // 试探性对端失败不计数、不把整轮打成 partial。
      if (!peer.expected) continue;
      failed++;
      if (peer.deviceId.isNotEmpty) failedIds.add(peer.deviceId);
      firstError ??= SyncIssue(
        code: SyncIssueCode.peerPushFailed,
        args: {'peer': peer.label},
      );
    }
    return SyncPushResult(
      succeededPeers: succeeded,
      failedPeers: failed,
      succeededIds: succeededIds,
      failedIds: failedIds,
      bytesOut: payload.length * succeeded,
      error: firstError,
    );
  }

  /// 局域网直连没有远端存储：显式清理远端文件对它不适用。
  @override
  Future<bool> deleteRemote(String deviceId) async => false;

  /// 候选 = 手动地址簿 + presence + 持久化已知端点。
  ///
  /// 手动 / presence 是「预期对端」：失败计数并上报；只有持久化端点的是
  /// 「试探性对端」：连不上是常态（换网 / 关机），不该污染整轮状态。
  List<SyncPeerCandidate> _candidates(int roundStartedAt) {
    final peers = <SyncPeerCandidate>[];
    void add(SyncPeerCandidate peer) {
      if (peer.port <= 0) return;
      for (var i = 0; i < peers.length; i++) {
        final existing = peers[i];
        final sameDevice = peer.deviceId.isNotEmpty &&
            existing.deviceId.isNotEmpty &&
            peer.deviceId == existing.deviceId;
        final sameEndpoint =
            _normalizeHost(existing.host) == _normalizeHost(peer.host) &&
                existing.port == peer.port;
        if (sameDevice || sameEndpoint) {
          peers[i] = existing.merge(peer);
          return;
        }
      }
      peers.add(peer);
    }

    for (final manual in _manualPeersProvider?.call() ?? const <ManualPeer>[]) {
      if (manual.httpPort <= 0) continue;
      if (manual.deviceId == deviceId) continue;
      add(SyncPeerCandidate(
        deviceId: manual.deviceId,
        name: manual.name,
        host: normalizePeerHost(manual.host),
        port: manual.httpPort,
        probePort: manual.probePort,
        expected: true,
      ));
    }
    for (final presence in _discovery.presence) {
      // 本轮没再听到的 presence 只是历史记忆：仍可直连（推送 / 拉取兜底），
      // 但失败不再计入「预期对端」，否则离线设备会把整轮打成 partial。
      final fresh = presence.lastHeardAt >= roundStartedAt;
      add(SyncPeerCandidate(
        deviceId: presence.deviceId,
        name: presence.name,
        host: presence.host,
        port: presence.httpPort,
        probePort: presence.probePort,
        addresses: presence.addresses,
        snapshotId: presence.snapshotId,
        journalHead: presence.journalHead,
        snapshotFresh: fresh,
        expected: fresh,
      ));
    }
    for (final endpoint
        in _knownPeersProvider?.call() ?? const <LanPeerEndpoint>[]) {
      if (endpoint.deviceId == deviceId) continue;
      add(SyncPeerCandidate(
        deviceId: endpoint.deviceId,
        name: '',
        host: normalizePeerHost(endpoint.host),
        port: endpoint.httpPort,
        probePort: endpoint.probePort,
        expected: false,
      ));
    }
    return peers;
  }

  /// 已知端点（持久化 + 手动地址簿里学到 HTTP 端口的条目）。
  List<LanPeerEndpoint> _knownEndpoints() {
    final endpoints = <LanPeerEndpoint>[];
    for (final endpoint
        in _knownPeersProvider?.call() ?? const <LanPeerEndpoint>[]) {
      if (endpoint.deviceId == deviceId) continue;
      endpoints.add(endpoint);
    }
    for (final manual in _manualPeersProvider?.call() ?? const <ManualPeer>[]) {
      if (manual.httpPort <= 0 || manual.deviceId == deviceId) continue;
      endpoints.add(LanPeerEndpoint(
        deviceId: manual.deviceId,
        host: normalizePeerHost(manual.host),
        httpPort: manual.httpPort,
        probePort: manual.probePort,
        verifiedAt: 0,
      ));
    }
    return endpoints;
  }

  /// 单播探测目标：测试注入 + 手动地址簿 + 已知端点（发现层再并入 presence）。
  List<LanProbeTarget> _probeTargetList() {
    final targets = <LanProbeTarget>[];
    for (final target in _probeTargets) {
      targets.add((host: normalizePeerHost(target.host), port: target.port));
    }
    for (final manual in _manualPeersProvider?.call() ?? const <ManualPeer>[]) {
      if (manual.deviceId == deviceId) continue;
      targets.add((
        host: normalizePeerHost(manual.host),
        port: manual.probePort > 0 ? manual.probePort : _udpPort,
      ));
    }
    for (final endpoint
        in _knownPeersProvider?.call() ?? const <LanPeerEndpoint>[]) {
      if (endpoint.deviceId == deviceId) continue;
      targets.add((
        host: normalizePeerHost(endpoint.host),
        port: endpoint.probePort > 0 ? endpoint.probePort : _udpPort,
      ));
    }
    return targets;
  }

  bool get _isCellularNow => _isCellular?.call() ?? false;

  Future<Uint8List> _ensureDiscoveryKey() async {
    final passphrase = await _passphraseProvider();
    if (passphrase == null || passphrase.trim().isEmpty) {
      throw const SyncCryptoException('同步口令为空');
    }
    if (_keyPassphrase == passphrase && _cachedDiscoveryKey != null) {
      return _cachedDiscoveryKey!;
    }
    final key = await _codec.discoveryKey(passphrase);
    _keyPassphrase = passphrase;
    _cachedDiscoveryKey = key;
    return key;
  }

  void _verifyPeer(SyncPeerCandidate peer, String host) {
    if (peer.deviceId.isEmpty) return;
    final normalized = normalizePeerHost(host);
    // 只持久化可路由地址：link-local / 带 zone / 回环是当前链路或同机的
    // 临时观测，写进端点表下次换网必然失效。
    if (!isRoutablePeerAddress(normalized)) return;
    _onPeerVerified?.call(LanPeerEndpoint(
      deviceId: peer.deviceId,
      host: normalized,
      httpPort: peer.port,
      probePort: peer.probePort,
      verifiedAt: _nowMs(),
    ));
  }

  /// 手动条目首次接触（或地址 / 端点端口变化）后回写学到的信息。
  ///
  /// **观测到的来源端口不写回**：来源端口随 NAT / 对端重启变化，写回会把
  /// 用户配置的探测端口改成一个下次不一定存在的动态端口。
  void _resolveManualPeer(LanPeerSighting sighting) {
    final manualPeers = _manualPeersProvider?.call() ?? const <ManualPeer>[];
    final peerHost = _normalizeHost(sighting.host);
    for (final entry in manualPeers) {
      if (_normalizeHost(entry.host) != peerHost) continue;
      if (entry.deviceId == sighting.deviceId &&
          entry.httpPort == sighting.httpPort) {
        return;
      }
      _onPeerResolved?.call(entry.mergeLearned(
        httpPort: sighting.httpPort,
        deviceId: sighting.deviceId,
        name: sighting.name,
      ));
      return;
    }
  }

  static String _normalizeHost(String host) =>
      InternetAddress.tryParse(host.trim())?.address ?? host.trim();

  Future<({Uint8List bytes, String host})?> _fetchSnapshot(
          SyncPeerCandidate peer) =>
      _getPayload(peer, snapshotPath);

  /// 拉取增量窗口（带本机游标；对端在游标落后于窗口起点时回全量快照）。
  Future<({Uint8List bytes, String host})?> _fetchJournal(
    SyncPeerCandidate peer,
    int since,
  ) =>
      _getPayload(peer, journalPath, query: {'since': '$since'});

  /// GET 对端端点：按候选地址 → 观测源地址依次尝试（最多 3 个地址）。
  Future<({Uint8List bytes, String host})?> _getPayload(
    SyncPeerCandidate peer,
    String path, {
    Map<String, String>? query,
  }) async {
    _snapshotGetCount++;
    final deadline = DateTime.now().add(peerRequestBudget);
    for (final host in peer.hosts) {
      final timeout = _remainingBudget(deadline);
      if (timeout == null) break;
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        final request = await client
            .getUrl(_peerUri(host, peer.port, path, query))
            .timeout(timeout);
        final response = await request.close().timeout(timeout);
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          continue;
        }
        final bytes = await _readBody(response);
        if (bytes == null) continue;
        return (bytes: bytes, host: host);
      } catch (_) {
        // 该地址不可达 / 超时：换下一个候选地址。
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  Future<String?> _postSnapshot(
    SyncPeerCandidate peer,
    Uint8List payload,
    String path,
  ) async {
    final deadline = DateTime.now().add(peerRequestBudget);
    for (final host in peer.hosts) {
      final timeout = _remainingBudget(deadline);
      if (timeout == null) break;
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        final request = await client
            .postUrl(_peerUri(host, peer.port, path, null))
            .timeout(timeout);
        request.headers.contentType = ContentType.binary;
        request.add(payload);
        final response = await request.close().timeout(timeout);
        await response.drain<void>();
        if (response.statusCode == HttpStatus.ok) return host;
      } catch (_) {
        // 该地址推送失败：换下一个候选地址。
      } finally {
        client.close(force: true);
      }
    }
    // 推送失败交由对端下一轮拉取兜底（失败计数上抛给报告）。
    return null;
  }

  /// 剩余预算；已耗尽返回 null（不再发起新地址尝试）。
  Duration? _remainingBudget(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return null;
    return remaining < _requestTimeout ? remaining : _requestTimeout;
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
      if (path == PairingHttpPaths.prefix ||
          path.startsWith('${PairingHttpPaths.prefix}/')) {
        await _handlePairingHttp(request);
        return;
      }
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
          final payload = await _codec.encrypt(envelope, passphrase);
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
              final envelope = await _codec.decrypt(bytes, passphrase);
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

  /// `/molia-sync/v2/pair/*`：交给配对服务，body 上限 8KB（远小于同步载荷）。
  ///
  /// 配对服务未注入 / 已停止时返回 404：旧路径与未启用能力都不做兼容分支。
  Future<void> _handlePairingHttp(HttpRequest request) async {
    final handler = _pairing;
    if (handler == null) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    Uint8List body = Uint8List(0);
    if (request.method == 'POST') {
      final read = await _readBody(
        request,
        maxBytes: pairingMaxBodyBytes,
      );
      if (read == null) {
        request.response.statusCode = HttpStatus.requestEntityTooLarge;
        return;
      }
      body = read;
    }
    final response = await handler.handle(PairingHttpRequest(
      method: request.method,
      path: request.uri.path,
      sourceHost: request.connectionInfo?.remoteAddress.address ?? '',
      query: request.uri.queryParameters,
      body: body,
    ));
    request.response.statusCode = response.statusCode;
    if (response.body.isNotEmpty) {
      request.response.headers.contentType = ContentType.parse(
        response.contentType,
      );
      request.response.write(response.body);
    }
  }

  /// 增量端点的服务端语义：请求游标之后的窗口；未注入提供者时回全量快照。
  Future<SyncEnvelope> _journalFor(String? sinceParam) async {
    final provider = _journalProvider;
    if (provider == null) return _snapshotProvider();
    final since = int.tryParse(sinceParam ?? '') ?? SyncPullRequest.noCursor;
    return provider(since);
  }

  Future<Uint8List?> _readBody(
    Stream<List<int>> stream, {
    int maxBytes = maxSnapshotBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > maxBytes) return null;
    }
    return builder.toBytes();
  }
}

class _PullStats {
  final List<SyncEnvelope> envelopes = [];
  final List<String> seenIds = [];
  final Map<String, SyncIssue> failedIssues = {};
  var expectedSeen = 0;
  var tentativeContacted = 0;
  var skipped = 0;
  var failed = 0;
  var httpFailedAny = 0;
  var bytesIn = 0;
  var contacted = false;
  SyncIssue? firstError;
}
