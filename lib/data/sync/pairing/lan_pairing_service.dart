/// 局域网一键配对服务（`MSP/1` 发现 + `/molia-sync/v2/pair/*` HTTP）。
///
/// 角色：
/// - **发起方**：`requestPairing` 生成一次性 P-256 密钥与 requestId，POST
///   `/pair/request`，随后轮询 `/pair/status`；接受后按方向解密接收方口令或
///   POST `/pair/complete` 交出本机口令；
/// - **接收方**：`handle` 校验请求、判定同组 / 冲突 / join / invite，把待确认
///   请求推给 UI；`respond` 接受后才产生密封口令（join）或等待 complete
///   （invite）。
///
/// 安全边界：
/// - 口令只在 ECDH + HKDF + AES-256-GCM 密封后离开本机；不写日志 / 错误详情；
/// - AAD 绑定 requestId / intent / 双方 deviceId，确认码由双方公钥与 nonce
///   派生，不经过口令；
/// - pending 的临时私钥 / 密封载荷在接受 / 拒绝 / 过期 / 停止时立即释放。
///
/// 策略：
/// - 只在前台、非蜂窝、局域网传输运行时发送 / 应答配对包；
/// - 同步页扫描期间按 [scanRefreshInterval] 复用 sweep 定时器补发 probe，
///   候选 TTL 仍是 15 秒；探测端口为 0 时 [startScan] 直接失败；
/// - 后台 / 锁屏 / 省电（组合根把省电并入 `canPrompt`）返回 unavailable；
/// - pending ≤8、TTL 60s、同一时间一个可见弹窗、每来源请求限流。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../../domain/models/device_sync.dart';
import '../../../domain/models/sync_nearby_pairing.dart';
import '../../../domain/ports/sync_pairing.dart';
import '../../../utils/peer_address.dart';
import '../sync_passphrase.dart';
import '../transport/lan_pairing_packet.dart';
import 'pairing_crypto.dart';
import 'pairing_http.dart';

/// 发送一条 MSP 包（host 为空 = 广播 / 组播；否则单播）。
typedef PairingPacketSender = Future<bool> Function(
  Uint8List packet, {
  String? host,
  int? port,
});

/// `SyncPairingPort` 的局域网实现。
class LanPairingService implements SyncPairingPort, PairingHttpHandler {
  LanPairingService({
    required this.deviceId,
    required this._deviceName,
    required this._readPassphrase,
    required this._writePassphrase,
    this._ensurePassphrase,
    required this._hasGroup,
    required this._canPrompt,
    required this._isCellular,
    required this._httpPortProvider,
    this._probePortProvider,
    this._localAddressesProvider,
    this._addPeerEndpoint,
    this._discoveryKeyProvider,
    this._packets,
    this._sendPacket,
    PairingHttpClient? httpClient,
    int Function()? nowMs,
    Logger? logger,
    this.requestTtl = const Duration(seconds: 60),
    this.inviteCompleteTimeout = const Duration(seconds: 5),
    this.statusPollInterval = const Duration(milliseconds: 500),
    this.httpTimeout = const Duration(seconds: 4),
    this.sweepInterval = const Duration(seconds: 1),
    this.scanProbeDelaysMs = const [100, 500, 1500],
    this.scanRefreshInterval = const Duration(seconds: 5),
    this.maxPending = 8,
    this.maxRequests = 64,
    this.requestRateLimit = 10,
    this.requestRateWindow = const Duration(seconds: 10),
    this.statusRateLimit = 240,
    this.statusRateWindow = const Duration(seconds: 10),
  })  : _httpClient = httpClient ?? IoPairingHttpClient(),
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _logger = logger ?? Logger('molia.sync.pairing') {
    _rateLimiter = MspRateLimiter(
      perSourceLimit: requestRateLimit,
      globalLimit: requestRateLimit * 8,
      window: requestRateWindow,
    );
    // 状态轮询是发起方的正常读取（500ms 一次），不能和「新建请求」共用
    // 10/10s 的限流；单独给一份宽松得多的预算，仍按来源隔离。
    _statusRateLimiter = MspRateLimiter(
      perSourceLimit: statusRateLimit,
      globalLimit: statusRateLimit * 8,
      window: statusRateWindow,
    );
  }

  final String deviceId;
  final String Function() _deviceName;
  final Future<String?> Function() _readPassphrase;
  final Future<void> Function(String passphrase) _writePassphrase;
  final Future<String> Function()? _ensurePassphrase;
  final bool Function() _hasGroup;
  final bool Function() _canPrompt;
  final bool Function() _isCellular;
  final int Function() _httpPortProvider;
  final int Function()? _probePortProvider;
  final Future<List<String>> Function()? _localAddressesProvider;
  final Future<void> Function(LanPeerEndpoint endpoint)? _addPeerEndpoint;
  final Future<Uint8List> Function(String passphrase)? _discoveryKeyProvider;
  final Stream<LanPairingDatagram>? _packets;
  final PairingPacketSender? _sendPacket;
  final PairingHttpClient _httpClient;
  final int Function() _nowMs;
  final Logger _logger;

  final Duration requestTtl;

  /// invite 接受后等待发起方 `/pair/complete` 的上限；超过只说明「对方还
  /// 没完成」，请求仍可在 [requestTtl] 内完成，因此不按失败处理。
  final Duration inviteCompleteTimeout;
  final Duration statusPollInterval;
  final Duration httpTimeout;
  final Duration sweepInterval;
  final List<int> scanProbeDelaysMs;

  /// 扫描期间的补探间隔：复用 sweep 定时器，按此节奏补发新 nonce 的 probe，
  /// 让候选随对端上线 / 用户犹豫持续刷新（候选 TTL 仍是 15 秒，不清空）。
  final Duration scanRefreshInterval;
  final int maxPending;
  final int maxRequests;
  final int requestRateLimit;
  final Duration requestRateWindow;
  final int statusRateLimit;
  final Duration statusRateWindow;

  late final MspRateLimiter _rateLimiter;
  late final MspRateLimiter _statusRateLimiter;
  final PairingCandidateCache _candidates = PairingCandidateCache();

  final StreamController<List<SyncNearbyDevice>> _nearby =
      StreamController<List<SyncNearbyDevice>>.broadcast();
  final StreamController<SyncPairingRequest> _incomingRequests =
      StreamController<SyncPairingRequest>.broadcast();
  final StreamController<SyncPairingAttempt> _attempts =
      StreamController<SyncPairingAttempt>.broadcast();

  final Map<String, _IncomingPairing> _requests = {};
  final Map<String, _OutgoingPairing> _outgoing = {};

  StreamSubscription<LanPairingDatagram>? _packetSub;
  Timer? _sweepTimer;
  final List<Timer> _scanTimers = [];

  bool _running = false;
  bool _scanning = false;
  bool _hidden = false;
  String? _activePromptId;
  bool _disposed = false;

  /// 上次发起扫描探测的时间（毫秒；0 = 当前没有待补探的扫描）。
  int _lastScanProbeAtMs = 0;

  /// 仅测试：sweep 定时器是否仍在跑（后台必须为 false）。
  bool get debugSweepScheduled => _sweepTimer?.isActive ?? false;

  /// 仅测试：当前仍持有密封载荷的请求数（验证过期 / 裁剪会释放）。
  int get debugSealedPayloadCount =>
      _requests.values.where((entry) => entry.sealed != null).length;

  /// 仅测试：请求表当前条数。
  int get debugRequestCount => _requests.length;

  /// 仅测试：直接触发请求表裁剪（不先跑过期清理）。
  void debugTrimRequests(int nowMs) => _trimRequests(nowMs);

  @override
  Stream<List<SyncNearbyDevice>> get nearbyDevices => _nearby.stream;

  @override
  Stream<SyncPairingRequest> get incomingRequests => _incomingRequests.stream;

  @override
  Stream<SyncPairingAttempt> get attempts => _attempts.stream;

  @override
  bool get scanning => _scanning;

  @override
  bool get hasGroup => _ownHasGroup();

  @override
  Future<void> start() async {
    if (_disposed || _running) return;
    _running = true;
    _hidden = false;
    _packetSub = _packets?.listen(
      _onPacket,
      onError: (Object _) {},
    );
    _startSweepTimer();
  }

  void _startSweepTimer() {
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(sweepInterval, (_) => _sweep());
  }

  @override
  Future<void> stop() async {
    if (!_running && _packetSub == null) return;
    _running = false;
    _scanning = false;
    _hidden = false;
    _lastScanProbeAtMs = 0;
    _cancelScanTimers();
    _sweepTimer?.cancel();
    _sweepTimer = null;
    await _packetSub?.cancel();
    _packetSub = null;
    _candidates.clear();
    if (!_nearby.isClosed) _nearby.add(const []);
    _activePromptId = null;
    for (final entry in _requests.values) {
      // 停止后不会再有 complete：让仍在 respond() 里等待的调用方拿到结论，
      // 而不是挂到超时。
      entry.complete(SyncPairingOutcome.unavailable);
      entry.clearSecrets();
    }
    _requests.clear();
    for (final entry in _outgoing.values) {
      entry.cancelled = true;
      entry.clearSecrets();
    }
    _outgoing.clear();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    _httpClient.close();
    await _nearby.close();
    await _incomingRequests.close();
    await _attempts.close();
  }

  bool get _canUsePairing =>
      _running && !_hidden && _canPrompt() && !_isCellular();

  bool _ownHasGroup() {
    try {
      return _hasGroup();
    } catch (_) {
      return false;
    }
  }

  // ---- 扫描与 MSP ----

  @override
  Future<bool> startScan() async {
    if (_disposed || !_canUsePairing) return false;
    // 配对探测端口不可用时不再假装「正在查找」：本机发不出 MSP，扫描只会
    // 停在空的「正在查找」。provider 为 null（旧测试 / 无发现层接线）保持
    // 原行为。
    final probePort = _probePortProvider;
    if (probePort != null && probePort() == 0) return false;
    _scanning = true;
    _lastScanProbeAtMs = _nowMs();
    _cancelScanTimers();
    _candidates.clear();
    _emitNearby();
    final packet = await _buildProbePacket();
    if (!_scanning || packet == null) return false;
    for (final delay in scanProbeDelaysMs) {
      if (delay <= 0) {
        await _sendProbe(packet);
        continue;
      }
      _scanTimers.add(Timer(Duration(milliseconds: delay), () {
        unawaited(_sendProbe(packet));
      }));
    }
    return true;
  }

  @override
  void stopScan() {
    _scanning = false;
    _lastScanProbeAtMs = 0;
    _cancelScanTimers();
    _candidates.clear();
    _emitNearby();
  }

  @override
  Future<bool> probeAddress(String host, {int probePort = 0}) async {
    if (!_canUsePairing) return false;
    final normalized = normalizePeerHost(host);
    if (!isValidPeerHost(normalized)) return false;
    final port = probePort == 0 ? ManualPeer.defaultProbePort : probePort;
    if (!isValidPeerPort(port)) return false;
    final packet = await _buildProbePacket();
    if (packet == null) return false;
    // 手动地址是发现失败时的兜底：打开扫描状态，让随后单播回来的 announce
    // 能进入候选表（否则 _onPacket 会按「未扫描」丢弃）。
    if (!_scanning) {
      _scanning = true;
      _lastScanProbeAtMs = _nowMs();
      _emitNearby();
    }
    try {
      final sent =
          await _sendPacket?.call(packet, host: normalized, port: port);
      return sent ?? false;
    } catch (e) {
      _logger.fine('单播配对探测失败', e);
      return false;
    }
  }

  @override
  void onAppHidden() {
    _hidden = true;
    // 后台不再补探：sweep 本身会被取消，这里一并清掉补探基准，避免回前台
    // 恢复时按「距上次补探已经很久」立刻多补一条。
    _lastScanProbeAtMs = 0;
    _cancelScanTimers();
    // 后台没有候选更新需求：停掉周期 sweep（省电，也避免隐藏期间刷新
    // 候选 / 清 pending）；回前台时按 _running 重新挂上。
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _candidates.clear();
    _emitNearby();
    // 后台不展示 / 不接受待确认请求：直接按过期处理，回前台后重新探测。
    for (final entry in List<_IncomingPairing>.of(_requests.values)) {
      if (entry.status == SyncPairingStatus.pending) {
        _expireEntry(entry);
      }
    }
    for (final entry in _outgoing.values) {
      entry.cancelled = true;
    }
  }

  @override
  void onAppResumed() {
    _hidden = false;
    if (!_running) return;
    if (!debugSweepScheduled) _startSweepTimer();
    if (!_scanning || !_canUsePairing) return;
    // 回前台立刻补一次，并把补探基准重置：这次补探之后仍按扫描间隔续期。
    _lastScanProbeAtMs = _nowMs();
    unawaited(_resendProbe());
  }

  Future<void> _resendProbe() async {
    final packet = await _buildProbePacket();
    if (packet != null) await _sendProbe(packet);
  }

  Future<Uint8List?> _buildProbePacket() async {
    final addresses = await _localAddresses();
    try {
      return Msp1.encode(Msp1Message(
        type: Msp1.typeProbe,
        deviceId: deviceId,
        name: _deviceName(),
        httpPort: _httpPortProvider(),
        probePort: _probePortProvider?.call() ?? 0,
        addresses: addresses,
        hasGroup: _ownHasGroup(),
        bootId: _bootId,
        nonce: _randomToken(16),
      ));
    } catch (e) {
      _logger.fine('构建配对探测包失败', e);
      return null;
    }
  }

  Future<void> _sendProbe(Uint8List packet) async {
    if (!_canUsePairing) return;
    try {
      await _sendPacket?.call(packet);
    } catch (e) {
      _logger.fine('发送配对探测包失败', e);
    }
  }

  Future<void> _onPacket(LanPairingDatagram datagram) async {
    if (!_running) return;
    final message = datagram.message;
    if (message.deviceId == deviceId) return;
    if (message.isProbe) {
      if (!_canUsePairing) return;
      final packet = await _buildAnnouncePacket();
      if (packet == null) return;
      try {
        await _sendPacket?.call(
          packet,
          host: datagram.sourceHost,
          port: datagram.sourcePort,
        );
      } catch (e) {
        _logger.fine('发送配对应答失败', e);
      }
      return;
    }
    // 后台 / 蜂窝下不应答，也不刷新候选：候选只服务前台配对入口。
    if (!message.isAnnounce || !_scanning || !_canUsePairing) return;
    final changed = _candidates.upsert(
      message: message,
      sourceHost: datagram.sourceHost,
      sourcePort: datagram.sourcePort,
      nowMs: datagram.receivedAt,
    );
    if (changed) _emitNearby();
  }

  Future<Uint8List?> _buildAnnouncePacket() async {
    final addresses = await _localAddresses();
    try {
      return Msp1.encode(Msp1Message(
        type: Msp1.typeAnnounce,
        deviceId: deviceId,
        name: _deviceName(),
        httpPort: _httpPortProvider(),
        probePort: _probePortProvider?.call() ?? 0,
        addresses: addresses,
        hasGroup: _ownHasGroup(),
        bootId: _bootId,
        nonce: _randomToken(16),
      ));
    } catch (e) {
      _logger.fine('构建配对应答包失败', e);
      return null;
    }
  }

  Future<List<String>> _localAddresses() async {
    try {
      return await _localAddressesProvider?.call() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  void _emitNearby() {
    if (_nearby.isClosed) return;
    _nearby.add(_candidates.current(_nowMs()));
  }

  void _sweep() {
    if (!_running) return;
    final now = _nowMs();
    final changed = _candidates.sweep(now);
    if (changed) _emitNearby();
    _refreshScanProbe(now);
    for (final entry in List<_IncomingPairing>.of(_requests.values)) {
      _expireIfNeeded(entry, now);
    }
    _trimRequests(now);
  }

  /// 扫描期补探：复用 sweep 定时器，按 [scanRefreshInterval] 补发新 nonce 的
  /// probe。只刷新候选，不碰已有候选（TTL 仍由 [_candidates.sweep] 负责）。
  void _refreshScanProbe(int now) {
    if (!_scanning || !_canUsePairing) return;
    final interval = scanRefreshInterval.inMilliseconds;
    if (interval <= 0) return;
    if (now - _lastScanProbeAtMs < interval) return;
    _lastScanProbeAtMs = now;
    unawaited(_resendProbe());
  }

  void _cancelScanTimers() {
    // 列表本身就是「待取消的扫描定时器」集合：已触发的条目虽无可取消，
    // 也要从列表移除（removeWhere 恒真），新扫描开始时不会跨扫描累积。
    _scanTimers.removeWhere((timer) {
      if (timer.isActive) timer.cancel();
      return true;
    });
  }

  // ---- 发起方 ----

  @override
  Future<SyncPairingResult> requestPairing(SyncNearbyDevice device) async {
    if (!_canUsePairing) {
      return const SyncPairingResult(outcome: SyncPairingOutcome.unavailable);
    }
    if (_outgoing.isNotEmpty) {
      return const SyncPairingResult(outcome: SyncPairingOutcome.busy);
    }
    if (device.httpPort <= 0) {
      return const SyncPairingResult(outcome: SyncPairingOutcome.unreachable);
    }

    String? ownPassphrase;
    try {
      ownPassphrase = await _readPassphrase();
    } catch (_) {
      ownPassphrase = null;
    }
    var ownHasGroup = _ownHasGroup();
    if (ownHasGroup &&
        (ownPassphrase == null || ownPassphrase.trim().isEmpty)) {
      ownHasGroup = false;
    }
    final intent =
        ownHasGroup ? SyncPairingIntent.invite : SyncPairingIntent.join;
    final requestId = _randomToken(16);
    final keyPair = PairingCrypto.generateKeyPair();
    final nonce = _randomBytes(PairingCrypto.nonceLength);
    final outgoing = _OutgoingPairing(
      requestId: requestId,
      device: device,
      intent: intent,
      keyPair: keyPair,
      publicKey: Uint8List.fromList(keyPair.publicKey),
      nonce: nonce,
      expiresAt: _nowMs() + requestTtl.inMilliseconds,
      ownHasGroup: ownHasGroup,
    );
    _outgoing[requestId] = outgoing;
    try {
      final proof = ownHasGroup && ownPassphrase != null
          ? await _buildGroupProof(ownPassphrase, requestId)
          : null;
      final posted = await _postRequest(outgoing, proof: proof);
      outgoing.peerHost = posted.host;
      final immediate = await _applyInitialReply(outgoing, posted.reply);
      if (immediate != null) return immediate;
      return await _pollStatus(outgoing);
    } on PairingCryptoException {
      // 公钥 / 密封数据异常不把细节回给 UI，也不写日志原文。
      return _finish(
        outgoing,
        SyncPairingStatus.unavailable,
      );
    } on _PairingUnreachable {
      return _finish(
        outgoing,
        SyncPairingStatus.unavailable,
        outcome: SyncPairingOutcome.unreachable,
      );
    } catch (e) {
      // 这里可能包住口令读写 / 密封路径：只记异常类型，绝不记异常原文。
      _logger.fine('配对请求失败（${outgoing.requestId}）：${e.runtimeType}');
      return _finish(outgoing, SyncPairingStatus.unavailable);
    } finally {
      outgoing.clearSecrets();
      _outgoing.remove(requestId);
    }
  }

  Future<({PairingHttpReply reply, String host})> _postRequest(
    _OutgoingPairing outgoing, {
    Uint8List? proof,
  }) async {
    final ownHasGroup = outgoing.ownHasGroup;
    final body = <String, Object?>{
      'v': 1,
      'requestId': outgoing.requestId,
      'deviceId': deviceId,
      'deviceName': _deviceName(),
      'intent': outgoing.intent.name,
      'publicKey': _encodeToken(outgoing.publicKey),
      'nonce': _encodeToken(outgoing.nonce),
      'group': ownHasGroup,
      'http': _httpPortProvider(),
      'probe': _probePortProvider?.call() ?? 0,
      if (proof != null) 'proof': _encodeToken(proof),
    };
    final bytes = utf8.encode(jsonEncode(body));
    _PairingUnreachable? lastError;
    for (final host in _hostsOf(outgoing.device)) {
      try {
        final reply = await _httpClient.send(
          method: 'POST',
          host: host,
          port: outgoing.device.httpPort,
          path: PairingHttpPaths.request,
          body: bytes,
          timeout: httpTimeout,
        );
        return (reply: reply, host: host);
      } catch (e) {
        lastError = _PairingUnreachable('$e');
      }
    }
    throw lastError ?? const _PairingUnreachable('没有可用地址');
  }

  Future<SyncPairingResult?> _applyInitialReply(
    _OutgoingPairing outgoing,
    PairingHttpReply reply,
  ) async {
    final status = _statusFromHttp(reply);
    if (status != null) {
      return _finish(
        outgoing,
        status,
        outcome: _outcomeForHttp(reply.statusCode),
      );
    }
    final map = _decodeReplyMap(reply);
    final protocolStatus = SyncPairingStatus.parse(map['status'] as String?);
    if (protocolStatus == SyncPairingStatus.pending) {
      final receiverPublicKey = _decodeTokenField(map, 'publicKey');
      final receiverNonce = _decodeTokenField(map, 'nonce');
      outgoing.receiverPublicKey = receiverPublicKey;
      outgoing.receiverNonce = receiverNonce;
      outgoing.code = _confirmationCode(
        outgoing,
        receiverPublicKey: receiverPublicKey,
        receiverNonce: receiverNonce,
      );
      _emitAttempt(outgoing, SyncPairingStatus.pending);
      return null;
    }
    if (protocolStatus == SyncPairingStatus.accepted) {
      // 第一次 POST 就回 accepted = 对端跳过了待确认阶段。没有先拿到接收方
      // 公钥 / nonce（也就没有给用户看过 6 位确认码）时绝不接受，否则恶意
      // 接收方可以无提示地把口令塞给发起方。
      if (outgoing.code.isEmpty ||
          outgoing.receiverPublicKey == null ||
          outgoing.receiverNonce == null) {
        return _finish(outgoing, SyncPairingStatus.unavailable);
      }
      return _applyAccepted(outgoing, map);
    }
    if (protocolStatus == SyncPairingStatus.sameGroup) {
      await _rememberOutgoingEndpoint(outgoing);
      return _finish(outgoing, SyncPairingStatus.sameGroup);
    }
    return _finish(outgoing, protocolStatus);
  }

  Future<SyncPairingResult> _pollStatus(_OutgoingPairing outgoing) async {
    var transportErrors = 0;
    while (!outgoing.cancelled) {
      final now = _nowMs();
      if (now >= outgoing.expiresAt) {
        return _finish(outgoing, SyncPairingStatus.expired);
      }
      await Future<void>.delayed(statusPollInterval);
      if (outgoing.cancelled) break;
      PairingHttpReply reply;
      try {
        reply = await _httpClient.send(
          method: 'GET',
          host: outgoing.peerHost ?? outgoing.device.host,
          port: outgoing.device.httpPort,
          path: PairingHttpPaths.status,
          query: {'id': outgoing.requestId},
          timeout: httpTimeout,
        );
      } catch (_) {
        // 连续失败说明对端不可达：不要陪跑到 60s，尽早给用户结论。
        transportErrors++;
        if (transportErrors >= 3) {
          return _finish(
            outgoing,
            SyncPairingStatus.unavailable,
            outcome: SyncPairingOutcome.unreachable,
          );
        }
        continue;
      }
      // 拿到合法 HTTP 响应就重置抖动计数（busy / 404 等仍按状态处理）。
      transportErrors = 0;
      final status = _statusFromHttp(reply);
      if (status != null) {
        if (status == SyncPairingStatus.busy) continue;
        return _finish(
          outgoing,
          status,
          outcome: _outcomeForHttp(reply.statusCode),
        );
      }
      final map = _decodeReplyMap(reply);
      final protocolStatus = SyncPairingStatus.parse(map['status'] as String?);
      if (protocolStatus == SyncPairingStatus.pending) {
        continue;
      }
      if (protocolStatus == SyncPairingStatus.accepted) {
        return _applyAccepted(outgoing, map);
      }
      if (protocolStatus == SyncPairingStatus.sameGroup) {
        await _rememberOutgoingEndpoint(outgoing);
      }
      return _finish(outgoing, protocolStatus);
    }
    return _finish(
      outgoing,
      SyncPairingStatus.cancelled,
      outcome: SyncPairingOutcome.cancelled,
    );
  }

  Future<SyncPairingResult> _applyAccepted(
    _OutgoingPairing outgoing,
    Map<String, Object?> map,
  ) async {
    // 只认 pending 阶段已经展示过确认码的材料；accepted 响应不能再补一份
    // 公钥 / nonce 当兜底（否则可绕过确认码阶段）。
    final receiverPublicKey = outgoing.receiverPublicKey;
    final receiverNonce = outgoing.receiverNonce;
    if (outgoing.code.isEmpty ||
        receiverPublicKey == null ||
        receiverNonce == null) {
      return _finish(outgoing, SyncPairingStatus.unavailable);
    }
    final key = PairingCrypto.deriveSessionKey(
      privateKey: outgoing.keyPair.privateKey,
      peerPublicKey: receiverPublicKey,
      initiatorNonce: outgoing.nonce,
      receiverNonce: receiverNonce,
    );
    final aad = _aad(outgoing);
    if (outgoing.intent == SyncPairingIntent.join) {
      final sealed = map['sealed'];
      if (sealed is! String) {
        return _finish(outgoing, SyncPairingStatus.unavailable);
      }
      final plaintext = PairingCrypto.open(
        key: key,
        sealed: _decodeToken(sealed),
        aad: aad,
      );
      final passphrase = utf8.decode(plaintext);
      if (SyncPassphrase.normalize(passphrase).length < 16) {
        return _finish(outgoing, SyncPairingStatus.unavailable);
      }
      await _writePassphrase(passphrase);
      await _rememberOutgoingEndpoint(outgoing);
      return _finish(outgoing, SyncPairingStatus.accepted);
    }

    // invite：发起方已有组，接受后把本机口令密封交给接收方。
    final own = await _readPassphrase();
    if (own == null || SyncPassphrase.normalize(own).length < 16) {
      return _finish(outgoing, SyncPairingStatus.unavailable);
    }
    final sealed = PairingCrypto.seal(
      key: key,
      plaintext: utf8.encode(own),
      aad: aad,
    );
    final body = utf8.encode(jsonEncode({
      'v': 1,
      'requestId': outgoing.requestId,
      'deviceId': deviceId,
      'sealed': _encodeToken(sealed),
    }));
    try {
      final reply = await _httpClient.send(
        method: 'POST',
        host: outgoing.peerHost ?? outgoing.device.host,
        port: outgoing.device.httpPort,
        path: PairingHttpPaths.complete,
        body: body,
        timeout: httpTimeout,
      );
      if (reply.statusCode != 200) {
        return _finish(
          outgoing,
          SyncPairingStatus.unavailable,
          outcome: SyncPairingOutcome.unreachable,
        );
      }
      // 200 不等于成功：必须解析 JSON，只有 status=accepted 才算口令已写入。
      final map = _decodeReplyMap(reply);
      final completeStatus = SyncPairingStatus.parse(
        map['status'] is String ? map['status'] as String : null,
      );
      if (completeStatus != SyncPairingStatus.accepted) {
        return _finish(
          outgoing,
          completeStatus == SyncPairingStatus.rejected ||
                  completeStatus == SyncPairingStatus.conflict
              ? completeStatus
              : SyncPairingStatus.unavailable,
        );
      }
      await _rememberOutgoingEndpoint(outgoing);
      return _finish(outgoing, SyncPairingStatus.accepted);
    } on _BadPairingRequest {
      // 200 但 body 结构不对：对端有问题，不是网络不可达。
      return _finish(outgoing, SyncPairingStatus.unavailable);
    } catch (_) {
      return _finish(
        outgoing,
        SyncPairingStatus.unavailable,
        outcome: SyncPairingOutcome.unreachable,
      );
    }
  }

  @override
  Future<void> cancelPairing(String requestId) async {
    final outgoing = _outgoing[requestId];
    if (outgoing == null) return;
    outgoing.cancelled = true;
    _emitAttempt(outgoing, SyncPairingStatus.cancelled);
  }

  // ---- 接收方 HTTP ----

  @override
  Future<PairingHttpResponse> handle(PairingHttpRequest request) async {
    if (!_running) {
      return PairingHttpResponse.json(
        {'v': 1, 'status': SyncPairingStatus.unavailable.name},
        statusCode: 200,
      );
    }
    try {
      if (request.bodyLength > pairingMaxBodyBytes) {
        return PairingHttpResponse.json(
          {'v': 1, 'status': SyncPairingStatus.busy.name},
          statusCode: 413,
        );
      }
      switch (request.path) {
        case PairingHttpPaths.request:
          return await _handleRequestBody(request);
        case PairingHttpPaths.status:
          return _handleStatusRequest(request);
        case PairingHttpPaths.complete:
          return await _handleCompleteRequest(request);
        default:
          return const PairingHttpResponse(statusCode: 404, body: '');
      }
    } on _BadPairingRequest {
      return PairingHttpResponse.json(
        {'v': 1, 'status': SyncPairingStatus.unavailable.name},
        statusCode: 400,
      );
    } on PairingCryptoException {
      // 坏公钥 / 结构非法：400，不产生弹窗、不写日志原文。
      return PairingHttpResponse.json(
        {'v': 1, 'status': SyncPairingStatus.unavailable.name},
        statusCode: 400,
      );
    } catch (e) {
      // 请求处理可能接触口令 / 密封载荷：日志只留路径与异常类型。
      _logger.fine(
        '配对 HTTP 请求处理失败（${request.path}）：${e.runtimeType}',
      );
      return PairingHttpResponse.json(
        {'v': 1, 'status': SyncPairingStatus.unavailable.name},
        statusCode: 500,
      );
    }
  }

  Future<PairingHttpResponse> _handleRequestBody(
    PairingHttpRequest request,
  ) async {
    if (request.method != 'POST') {
      return const PairingHttpResponse(
        statusCode: 405,
        body: '',
      );
    }
    if (!_rateLimiter.allow(request.sourceHost, _nowMs())) {
      return PairingHttpResponse.json(
        {'v': 1, 'status': SyncPairingStatus.busy.name},
        statusCode: 429,
      );
    }
    final map = _decodeRequestMap(request.body);
    final requestId = _readId(map, 'requestId');
    final existing = _requests[requestId];
    if (existing != null) {
      // 同一 requestId 的重试（多发几个地址 / 网络重传）返回原响应。
      _expireIfNeeded(existing, _nowMs());
      return PairingHttpResponse.json(_responseBody(existing));
    }
    if (!_canUsePairing) {
      return PairingHttpResponse.json({
        'v': 1,
        'status': SyncPairingStatus.unavailable.name,
      });
    }

    if (_pendingCount >= maxPending) {
      return PairingHttpResponse.json({
        'v': 1,
        'status': SyncPairingStatus.busy.name,
      });
    }

    final peerDeviceId = _readString(map, 'deviceId', maxLength: 128);
    if (peerDeviceId == deviceId) {
      throw const _BadPairingRequest('不能与自己配对');
    }
    final peerName =
        _readString(map, 'deviceName', maxLength: 128, allowEmpty: true);
    final requestedIntent =
        SyncPairingIntent.tryParse(map['intent'] as String?) ??
            (throw const _BadPairingRequest('配对意图缺失'));
    final peerPublicKey = _decodeTokenField(map, 'publicKey');
    final peerNonce = _decodeTokenField(map, 'nonce');
    if (peerNonce.length != PairingCrypto.nonceLength) {
      throw const _BadPairingRequest('nonce 长度无效');
    }
    // 公钥在入队前就验证在曲线上：坏公钥不产生弹窗。
    PairingCrypto.validatePublicKey(peerPublicKey);
    final peerHasGroup = map['group'] == true;
    final proof =
        map['proof'] is String ? _decodeToken(map['proof'] as String) : null;
    final peerHttpPort = _readPort(map['http']);
    final peerProbePort = _readPort(map['probe']);
    final peerHost = request.sourceHost;

    final ownPassphrase = await _readPassphrase();
    final receiverHasGroup = _ownHasGroup() &&
        ownPassphrase != null &&
        ownPassphrase.trim().isNotEmpty;

    var effectiveIntent = SyncPairingIntent.join;
    if (receiverHasGroup && peerHasGroup) {
      final key = await _discoveryKey(ownPassphrase);
      final expected = PairingCrypto.groupProof(
        discoveryKey: key,
        requestId: requestId,
      );
      final matches =
          proof != null && PairingCrypto.constantTimeEquals(expected, proof);
      if (!matches) {
        // 双方都有组但不是同一组：不传口令，也不弹接受窗。
        return PairingHttpResponse.json({
          'v': 1,
          'requestId': requestId,
          'status': SyncPairingStatus.conflict.name,
          'hasGroup': true,
        });
      }
      await _rememberEndpointFromRequest(
        peerDeviceId: peerDeviceId,
        peerHost: peerHost,
        peerHttpPort: peerHttpPort,
        peerProbePort: peerProbePort,
      );
      return PairingHttpResponse.json({
        'v': 1,
        'requestId': requestId,
        'status': SyncPairingStatus.sameGroup.name,
        'hasGroup': true,
      });
    }
    if (receiverHasGroup && !peerHasGroup) {
      effectiveIntent = SyncPairingIntent.join;
    } else if (!receiverHasGroup && peerHasGroup) {
      effectiveIntent = SyncPairingIntent.invite;
    } else {
      effectiveIntent = SyncPairingIntent.join;
    }
    if (requestedIntent != effectiveIntent) {
      return PairingHttpResponse.json({
        'v': 1,
        'requestId': requestId,
        'status': SyncPairingStatus.conflict.name,
        'hasGroup': receiverHasGroup,
      });
    }
    // 读口令 / 派生 proof 期间可能又进来一条请求：入队前重新检查上限与
    // 幂等，避免并发请求绕过 pending 上限。
    final raced = _requests[requestId];
    if (raced != null) {
      _expireIfNeeded(raced, _nowMs());
      return PairingHttpResponse.json(_responseBody(raced));
    }
    if (!_canUsePairing) {
      return PairingHttpResponse.json({
        'v': 1,
        'status': SyncPairingStatus.unavailable.name,
      });
    }
    if (_pendingCount >= maxPending) {
      return PairingHttpResponse.json({
        'v': 1,
        'status': SyncPairingStatus.busy.name,
      });
    }
    _makeRoomForRequest();

    final keyPair = PairingCrypto.generateKeyPair();
    final localNonce = _randomBytes(PairingCrypto.nonceLength);
    final entry = _IncomingPairing(
      requestId: requestId,
      peerDeviceId: peerDeviceId,
      peerName: peerName,
      peerHost: peerHost,
      peerHttpPort: peerHttpPort,
      peerProbePort: peerProbePort,
      intent: effectiveIntent,
      peerHasGroup: peerHasGroup,
      receiverHasGroup: receiverHasGroup,
      peerPublicKey: peerPublicKey,
      localNonce: localNonce,
      peerNonce: peerNonce,
      keyPair: keyPair,
      createdAt: _nowMs(),
      expiresAt: _nowMs() + requestTtl.inMilliseconds,
    );
    entry.code = PairingCrypto.confirmationCode(
      requestId: requestId,
      intent: effectiveIntent,
      initiatorDeviceId: peerDeviceId,
      receiverDeviceId: deviceId,
      initiatorNonce: peerNonce,
      receiverNonce: localNonce,
      initiatorPublicKey: peerPublicKey,
      receiverPublicKey: keyPair.publicKey,
    );
    _requests[requestId] = entry;
    _presentNext();
    return PairingHttpResponse.json(_responseBody(entry));
  }

  PairingHttpResponse _handleStatusRequest(PairingHttpRequest request) {
    if (request.method != 'GET') {
      return const PairingHttpResponse(statusCode: 405, body: '');
    }
    if (!_statusRateLimiter.allow(request.sourceHost, _nowMs())) {
      return PairingHttpResponse.json(
        {'v': 1, 'status': SyncPairingStatus.busy.name},
        statusCode: 429,
      );
    }
    final rawId = request.query['id'];
    if (rawId == null) throw const _BadPairingRequest('缺少 requestId');
    // 与 request / complete 的 requestId 同一套 token 规则：不允许空串、
    // 超长或带路径符号的查询值穿透到表查找。
    final requestId = _validateId(rawId);
    final entry = _requests[requestId];
    if (entry == null) {
      return PairingHttpResponse.json({
        'v': 1,
        'requestId': requestId,
        'status': SyncPairingStatus.expired.name,
      });
    }
    _expireIfNeeded(entry, _nowMs());
    return PairingHttpResponse.json(_responseBody(entry));
  }

  Future<PairingHttpResponse> _handleCompleteRequest(
    PairingHttpRequest request,
  ) async {
    if (request.method != 'POST') {
      return const PairingHttpResponse(statusCode: 405, body: '');
    }
    // `/pair/complete` 刻意不要求前台（不检查 `_canUsePairing`）：用户点
    // 「接受」时确认窗只会在前台出现，授权已经发生；从接受走到发起方下一次
    // 轮询之间，接收方可能刚好锁屏 / 切到后台。这里若按后台拒绝，就会留下
    // 「已接受但口令永远写不进来」的半完成状态。complete 仍受已接受 entry、
    // requestId、临时密钥与 request TTL 约束，后台进程不能凭空发起一次写入。
    if (!_rateLimiter.allow(request.sourceHost, _nowMs())) {
      return PairingHttpResponse.json(
        {'v': 1, 'status': SyncPairingStatus.busy.name},
        statusCode: 429,
      );
    }
    final map = _decodeRequestMap(request.body);
    final requestId = _readId(map, 'requestId');
    final entry = _requests[requestId];
    if (entry == null) {
      return const PairingHttpResponse(statusCode: 404, body: '');
    }
    _expireIfNeeded(entry, _nowMs());
    if (entry.status == SyncPairingStatus.expired) {
      entry.complete(SyncPairingOutcome.expired);
      return PairingHttpResponse.json({
        'v': 1,
        'requestId': requestId,
        'status': SyncPairingStatus.expired.name,
      });
    }
    if (entry.intent != SyncPairingIntent.invite ||
        entry.status != SyncPairingStatus.accepted) {
      throw const _BadPairingRequest('当前请求不接受 complete');
    }
    if (entry.completed) {
      entry.complete(SyncPairingOutcome.accepted);
      return PairingHttpResponse.json({
        'v': 1,
        'requestId': requestId,
        'status': SyncPairingStatus.accepted.name,
      });
    }
    final keyPair = entry.keyPair;
    if (keyPair == null) {
      entry.complete(SyncPairingOutcome.expired);
      return PairingHttpResponse.json({
        'v': 1,
        'requestId': requestId,
        'status': SyncPairingStatus.expired.name,
      });
    }
    try {
      final sealed = _decodeTokenField(map, 'sealed');
      final key = PairingCrypto.deriveSessionKey(
        privateKey: keyPair.privateKey,
        peerPublicKey: entry.peerPublicKey,
        initiatorNonce: entry.peerNonce,
        receiverNonce: entry.localNonce,
      );
      final plaintext = PairingCrypto.open(
        key: key,
        sealed: sealed,
        aad: _aadFor(
          requestId: requestId,
          intent: entry.intent,
          initiatorDeviceId: entry.peerDeviceId,
          receiverDeviceId: deviceId,
        ),
      );
      final passphrase = utf8.decode(plaintext);
      if (SyncPassphrase.normalize(passphrase).length < 16) {
        throw const _BadPairingRequest('口令无效');
      }
      await _writePassphrase(passphrase);
      entry.completed = true;
      entry.clearSecrets();
      await _rememberEndpointFromRequest(
        peerDeviceId: entry.peerDeviceId,
        peerHost: entry.peerHost,
        peerHttpPort: entry.peerHttpPort,
        peerProbePort: entry.peerProbePort,
      );
      entry.complete(SyncPairingOutcome.accepted);
      return PairingHttpResponse.json({
        'v': 1,
        'requestId': requestId,
        'status': SyncPairingStatus.accepted.name,
      });
    } catch (_) {
      // 密封 / 口令 / 落盘任一失败都不能让等待方误以为已加入；保留 entry
      // 到 TTL，发起方仍可重试 complete。
      entry.complete(SyncPairingOutcome.unavailable);
      rethrow;
    }
  }

  @override
  Future<SyncPairingOutcome> respond(
    String requestId, {
    required bool accept,
  }) async {
    final entry = _requests[requestId];
    if (entry == null) return SyncPairingOutcome.expired;
    _expireIfNeeded(entry, _nowMs());
    if (entry.status != SyncPairingStatus.pending) {
      return SyncPairingOutcome.fromStatus(entry.status);
    }
    if (!accept) {
      entry.status = SyncPairingStatus.rejected;
      entry.clearSecrets();
      _afterPromptResolved(entry);
      return SyncPairingOutcome.rejected;
    }
    try {
      if (entry.intent == SyncPairingIntent.join) {
        final passphrase = await _ensureOwnPassphrase();
        final key = _deriveIncomingKey(entry);
        entry.sealed = PairingCrypto.seal(
          key: key,
          plaintext: utf8.encode(passphrase),
          aad: _aadFor(
            requestId: entry.requestId,
            intent: entry.intent,
            initiatorDeviceId: entry.peerDeviceId,
            receiverDeviceId: deviceId,
          ),
        );
        // 密封载荷只给发起方留一个 TTL 的读取窗口；过期后必须清掉，
        // 不能靠原请求的 pending TTL（接受可能发生在 59s）。
        entry.sealedExpiresAt = _nowMs() + requestTtl.inMilliseconds;
        entry.status = SyncPairingStatus.accepted;
        // sealed 要留给发起方轮询读取；只释放临时私钥。
        entry.clearKeyPair();
        await _rememberEndpointFromRequest(
          peerDeviceId: entry.peerDeviceId,
          peerHost: entry.peerHost,
          peerHttpPort: entry.peerHttpPort,
          peerProbePort: entry.peerProbePort,
        );
      } else {
        // invite：等发起方 POST complete；临时私钥保留到收完 / 过期。
        // 端点要等 complete 真正写入口令后再保存，用户点「接受」不算完成。
        entry.status = SyncPairingStatus.accepted;
        final completion = entry.beginCompletion();
        _afterPromptResolved(entry);
        // 有界等待：complete 正常在发起方下一次轮询（≤500ms）到达；5s 仍
        // 没来只说明对方还没完成，不把已接受改成失败——对端仍可在 TTL 内
        // 补发 complete，所以按 unavailable 交回 UI 提示「已接受，但对方
        // 还没完成」，同时释放等待方。
        return await completion.future.timeout(
          inviteCompleteTimeout,
          onTimeout: () {
            entry.complete(SyncPairingOutcome.unavailable);
            return SyncPairingOutcome.unavailable;
          },
        );
      }
      _afterPromptResolved(entry);
      return SyncPairingOutcome.accepted;
    } on PairingCryptoException {
      entry.status = SyncPairingStatus.unavailable;
      entry.clearSecrets();
      _afterPromptResolved(entry);
      return SyncPairingOutcome.unavailable;
    } catch (e) {
      _logger.fine('接受配对请求失败（$requestId）：${e.runtimeType}');
      entry.status = SyncPairingStatus.unavailable;
      entry.clearSecrets();
      _afterPromptResolved(entry);
      return SyncPairingOutcome.unavailable;
    }
  }

  Uint8List _deriveIncomingKey(_IncomingPairing entry) {
    final keyPair = entry.keyPair;
    if (keyPair == null) {
      throw const PairingCryptoException('临时密钥已释放');
    }
    return PairingCrypto.deriveSessionKey(
      privateKey: keyPair.privateKey,
      peerPublicKey: entry.peerPublicKey,
      initiatorNonce: entry.peerNonce,
      receiverNonce: entry.localNonce,
    );
  }

  Future<String> _ensureOwnPassphrase() async {
    final existing = await _readPassphrase();
    if (existing != null && SyncPassphrase.normalize(existing).length >= 16) {
      return existing;
    }
    final ensure = _ensurePassphrase;
    if (ensure != null) return ensure();
    final generated = SyncPassphrase.generate();
    await _writePassphrase(generated);
    return generated;
  }

  Map<String, Object?> _responseBody(_IncomingPairing entry) {
    final body = <String, Object?>{
      'v': 1,
      'requestId': entry.requestId,
      'status': entry.status.name,
      'hasGroup': entry.receiverHasGroup,
    };
    if (entry.status == SyncPairingStatus.pending) {
      final keyPair = entry.keyPair;
      if (keyPair != null) {
        body['publicKey'] = _encodeToken(keyPair.publicKey);
        body['nonce'] = _encodeToken(entry.localNonce);
      }
      body['http'] = _httpPortProvider();
      body['probe'] = _probePortProvider?.call() ?? 0;
    } else if (entry.status == SyncPairingStatus.accepted &&
        entry.intent == SyncPairingIntent.join &&
        entry.sealed != null) {
      body['sealed'] = _encodeToken(entry.sealed!);
    }
    return body;
  }

  int get _pendingCount => _requests.values
      .where((entry) => entry.status == SyncPairingStatus.pending)
      .length;

  void _presentNext() {
    if (_disposed ||
        _activePromptId != null ||
        _incomingRequests.isClosed ||
        !_canUsePairing) {
      return;
    }
    _IncomingPairing? next;
    for (final entry in _requests.values) {
      if (entry.status != SyncPairingStatus.pending) continue;
      if (entry.prompted) continue;
      if (next == null ||
          entry.createdAt < next.createdAt ||
          (entry.createdAt == next.createdAt &&
              entry.requestId.compareTo(next.requestId) < 0)) {
        next = entry;
      }
    }
    if (next == null) return;
    next.prompted = true;
    _activePromptId = next.requestId;
    _incomingRequests.add(SyncPairingRequest(
      requestId: next.requestId,
      peerDeviceId: next.peerDeviceId,
      peerName: next.peerName,
      intent: next.intent,
      code: next.code,
      expiresAt: next.expiresAt,
      peerHasGroup: next.peerHasGroup,
    ));
  }

  void _afterPromptResolved(_IncomingPairing entry) {
    if (_activePromptId == entry.requestId) {
      _activePromptId = null;
    }
    _presentNext();
  }

  void _expireIfNeeded(_IncomingPairing entry, int nowMs) {
    if (entry.status == SyncPairingStatus.pending) {
      if (nowMs >= entry.expiresAt) _expireEntry(entry);
      return;
    }
    if (entry.status != SyncPairingStatus.accepted) return;
    // invite：接受后等 complete，仍受原请求 TTL 约束。
    if (entry.intent == SyncPairingIntent.invite) {
      if (!entry.completed && nowMs >= entry.expiresAt) _expireEntry(entry);
      return;
    }
    // join：接受后密封载荷有自己的 TTL（接受时间 + requestTtl），过期即
    // 清掉，status 不能再吐旧 sealed。
    final sealedExpiresAt = entry.sealedExpiresAt;
    if (sealedExpiresAt != null && nowMs >= sealedExpiresAt) {
      _expireEntry(entry);
    }
  }

  void _expireEntry(_IncomingPairing entry) {
    entry.status = SyncPairingStatus.expired;
    // invite 已接受、正在等 complete：过期就是最终结论，不能只清密钥让
    // respond() 挂到超时。
    entry.complete(SyncPairingOutcome.expired);
    entry.clearSecrets();
    if (_activePromptId == entry.requestId) {
      _activePromptId = null;
      _presentNext();
    }
  }

  /// 为一条新请求腾出位置：请求表有界（防伪造请求无限增长）。优先移除最旧
  /// 的终态请求；pending 最多 8 条，不会把仍在等待的请求挤掉。
  void _makeRoomForRequest() {
    while (_requests.length >= maxRequests) {
      String? oldestId;
      var oldestAt = 1 << 62;
      for (final entry in _requests.entries) {
        if (entry.value.status == SyncPairingStatus.pending) continue;
        if (entry.value.createdAt < oldestAt) {
          oldestAt = entry.value.createdAt;
          oldestId = entry.key;
        }
      }
      if (oldestId == null) return;
      _discardEntry(oldestId);
    }
  }

  /// 从请求表移除一条 entry：先结束可能仍在等待 complete 的 respond()，
  /// 再释放密钥 / 密封载荷。
  void _discardEntry(String requestId) {
    final entry = _requests.remove(requestId);
    if (entry == null) return;
    entry.complete(SyncPairingOutcome.unavailable);
    entry.clearSecrets();
  }

  void _trimRequests(int nowMs) {
    if (_requests.length <= maxRequests) return;
    final removable = <String>[];
    for (final entry in _requests.entries) {
      if (entry.value.status == SyncPairingStatus.pending) continue;
      if (nowMs - entry.value.expiresAt < requestTtl.inMilliseconds * 2) {
        continue;
      }
      removable.add(entry.key);
    }
    for (final id in removable) {
      if (_requests.length <= maxRequests) break;
      // 裁剪同样要释放密封载荷 / 临时私钥：不能只把索引从表里摘掉。
      _discardEntry(id);
    }
  }

  Future<void> _rememberEndpointFromRequest({
    required String peerDeviceId,
    required String peerHost,
    required int peerHttpPort,
    required int peerProbePort,
  }) async {
    if (peerHttpPort <= 0 || peerHost.trim().isEmpty) return;
    try {
      await _addPeerEndpoint?.call(LanPeerEndpoint(
        deviceId: peerDeviceId,
        host: peerHost,
        httpPort: peerHttpPort,
        probePort: peerProbePort,
        verifiedAt: _nowMs(),
      ));
    } catch (e) {
      _logger.fine('保存配对端点失败', e);
    }
  }

  Future<void> _rememberOutgoingEndpoint(_OutgoingPairing outgoing) =>
      _rememberEndpointFromRequest(
        peerDeviceId: outgoing.device.deviceId,
        peerHost: outgoing.peerHost ?? outgoing.device.host,
        peerHttpPort: outgoing.device.httpPort,
        peerProbePort: outgoing.device.probePort,
      );

  // ---- 辅助 ----

  Future<Uint8List> _discoveryKey(String passphrase) {
    final provider = _discoveryKeyProvider;
    if (provider == null) {
      throw const PairingCryptoException('未配置发现密钥派生');
    }
    return provider(passphrase);
  }

  Future<Uint8List> _buildGroupProof(
    String passphrase,
    String requestId,
  ) async {
    final key = await _discoveryKey(passphrase);
    return PairingCrypto.groupProof(discoveryKey: key, requestId: requestId);
  }

  String _confirmationCode(
    _OutgoingPairing outgoing, {
    required Uint8List receiverPublicKey,
    required Uint8List receiverNonce,
  }) =>
      PairingCrypto.confirmationCode(
        requestId: outgoing.requestId,
        intent: outgoing.intent,
        initiatorDeviceId: deviceId,
        receiverDeviceId: outgoing.device.deviceId,
        initiatorNonce: outgoing.nonce,
        receiverNonce: receiverNonce,
        initiatorPublicKey: outgoing.publicKey,
        receiverPublicKey: receiverPublicKey,
      );

  Uint8List _aad(_OutgoingPairing outgoing) => _aadFor(
        requestId: outgoing.requestId,
        intent: outgoing.intent,
        initiatorDeviceId: deviceId,
        receiverDeviceId: outgoing.device.deviceId,
      );

  Uint8List _aadFor({
    required String requestId,
    required SyncPairingIntent intent,
    required String initiatorDeviceId,
    required String receiverDeviceId,
  }) =>
      PairingCrypto.aad(
        requestId: requestId,
        intent: intent,
        initiatorDeviceId: initiatorDeviceId,
        receiverDeviceId: receiverDeviceId,
      );

  SyncPairingResult _finish(
    _OutgoingPairing outgoing,
    SyncPairingStatus status, {
    SyncPairingOutcome? outcome,
  }) {
    _emitAttempt(outgoing, status);
    return SyncPairingResult(
      outcome: outcome ?? SyncPairingOutcome.fromStatus(status),
      attempt: outgoing.code.isEmpty
          ? null
          : SyncPairingAttempt(
              requestId: outgoing.requestId,
              peerDeviceId: outgoing.device.deviceId,
              peerName: outgoing.device.name,
              intent: outgoing.intent,
              code: outgoing.code,
              status: outgoing.status,
              expiresAt: outgoing.expiresAt,
            ),
    );
  }

  void _emitAttempt(_OutgoingPairing outgoing, SyncPairingStatus status) {
    outgoing.status = status;
    if (_attempts.isClosed || outgoing.code.isEmpty) return;
    _attempts.add(SyncPairingAttempt(
      requestId: outgoing.requestId,
      peerDeviceId: outgoing.device.deviceId,
      peerName: outgoing.device.name,
      intent: outgoing.intent,
      code: outgoing.code,
      status: status,
      expiresAt: outgoing.expiresAt,
    ));
  }

  /// 旧路径 / 不支持的请求形态：结果要能让 UI 说「对端版本不支持」。
  SyncPairingOutcome _outcomeForHttp(int statusCode) {
    if (statusCode == 404 ||
        statusCode == 400 ||
        statusCode == 405 ||
        statusCode == 413) {
      return SyncPairingOutcome.unsupported;
    }
    if (statusCode == 429) return SyncPairingOutcome.busy;
    return SyncPairingOutcome.unavailable;
  }

  /// HTTP 层错误 → 类型化结局；`null` = 需要继续解析 200 响应。
  SyncPairingStatus? _statusFromHttp(PairingHttpReply reply) {
    if (reply.statusCode == 200) return null;
    if (reply.statusCode == 429) return SyncPairingStatus.busy;
    if (reply.statusCode == 404 ||
        reply.statusCode == 400 ||
        reply.statusCode == 405 ||
        reply.statusCode == 413) {
      return SyncPairingStatus.unavailable;
    }
    if (reply.statusCode == 503) return SyncPairingStatus.unavailable;
    return SyncPairingStatus.unavailable;
  }

  Map<String, Object?> _decodeReplyMap(PairingHttpReply reply) {
    if (reply.statusCode != 200) {
      throw const _PairingUnreachable('状态响应非 200');
    }
    final raw = _decodeMap(reply.body);
    if (raw['v'] != 1) throw const _PairingUnreachable('协议版本不支持');
    return raw;
  }

  Map<String, Object?> _decodeRequestMap(List<int> body) {
    final String text;
    try {
      text = utf8.decode(body, allowMalformed: false);
    } catch (_) {
      throw const _BadPairingRequest('请求不是合法 UTF-8');
    }
    final raw = _decodeMap(text);
    if (raw['v'] != 1) throw const _BadPairingRequest('协议版本不支持');
    return raw;
  }

  Map<String, Object?> _decodeMap(String body) {
    Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (_) {
      throw const _BadPairingRequest('JSON 结构无效');
    }
    if (raw is! Map) throw const _BadPairingRequest('JSON 不是对象');
    return raw.cast<String, Object?>();
  }

  String _readId(Map<String, Object?> map, String key) =>
      _validateId(_readString(map, key, maxLength: 128));

  String _validateId(String value) {
    final id = value.trim();
    if (id.length < 8 ||
        id.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const _BadPairingRequest('requestId 无效');
    }
    return id;
  }

  String _readString(
    Map<String, Object?> map,
    String key, {
    required int maxLength,
    bool allowEmpty = false,
  }) {
    final value = map[key];
    if (value is! String) throw const _BadPairingRequest('字段缺失');
    final trimmed = value.trim();
    if (!allowEmpty && trimmed.isEmpty) {
      throw const _BadPairingRequest('字段为空');
    }
    if (trimmed.length > maxLength) {
      throw const _BadPairingRequest('字段过长');
    }
    return trimmed;
  }

  Uint8List _decodeTokenField(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String) throw const _BadPairingRequest('密钥字段缺失');
    return _decodeToken(value);
  }

  Uint8List _decodeToken(String value) {
    if (value.isEmpty || value.length > 1024) {
      throw const _BadPairingRequest('密钥字段长度无效');
    }
    try {
      return base64Url.decode(base64Url.normalize(value));
    } catch (_) {
      throw const _BadPairingRequest('密钥字段编码无效');
    }
  }

  int _readPort(Object? raw) {
    if (raw is! num) return 0;
    final value = raw.toInt();
    return value < 0 || value > 65535 ? 0 : value;
  }

  Iterable<String> _hostsOf(SyncNearbyDevice device) sync* {
    final seen = <String>{};
    // UDP 来源地址是真实观测值：即使回环 / link-local 也先试（同机回环
    // 测试与直连场景依赖它）。自报的 addrs 没有认证，只接受可路由 IP。
    final source = device.host.trim();
    if (source.isNotEmpty && seen.add(source)) {
      yield source;
    }
    for (final raw in device.addresses) {
      if (!isRoutablePeerAddress(raw)) continue;
      final host = normalizePeerHost(raw);
      if (host.isEmpty || !seen.add(host)) continue;
      yield host;
      if (seen.length >= 4) return;
    }
  }

  static String _encodeToken(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _randomToken(int length) => _encodeToken(_randomBytes(length));

  /// 进程内 boot id：MSP 应答用于识别对端重启（与 MSD 的 bootId 同义）。
  static final String _bootId = _randomToken(8);
}

class _IncomingPairing {
  _IncomingPairing({
    required this.requestId,
    required this.peerDeviceId,
    required this.peerName,
    required this.peerHost,
    required this.peerHttpPort,
    required this.peerProbePort,
    required this.intent,
    required this.peerHasGroup,
    required this.receiverHasGroup,
    required this.peerPublicKey,
    required this.localNonce,
    required this.peerNonce,
    required this.keyPair,
    required this.createdAt,
    required this.expiresAt,
  });

  final String requestId;
  final String peerDeviceId;
  final String peerName;
  final String peerHost;
  final int peerHttpPort;
  final int peerProbePort;
  final SyncPairingIntent intent;
  final bool peerHasGroup;
  final bool receiverHasGroup;
  final Uint8List peerPublicKey;
  final Uint8List localNonce;
  final Uint8List peerNonce;
  final int createdAt;
  final int expiresAt;

  PairingKeyPair? keyPair;
  SyncPairingStatus status = SyncPairingStatus.pending;
  String code = '';
  Uint8List? sealed;

  /// join 接受后密封载荷的读取截止时间（仅 accepted + join 有意义）。
  int? sealedExpiresAt;
  bool prompted = false;
  bool completed = false;

  /// invite 接受后由 `respond()` 等待、`/pair/complete` 或生命周期事件结束。
  Completer<SyncPairingOutcome>? _completion;

  Completer<SyncPairingOutcome> beginCompletion() =>
      _completion ??= Completer<SyncPairingOutcome>();

  void complete(SyncPairingOutcome outcome) {
    final completion = _completion;
    if (completion == null || completion.isCompleted) return;
    completion.complete(outcome);
  }

  void clearKeyPair() {
    keyPair?.destroy();
    keyPair = null;
  }

  void clearSecrets() {
    clearKeyPair();
    sealed?.fillRange(0, sealed!.length, 0);
    sealed = null;
  }
}

class _OutgoingPairing {
  _OutgoingPairing({
    required this.requestId,
    required this.device,
    required this.intent,
    required this.keyPair,
    required this.publicKey,
    required this.nonce,
    required this.expiresAt,
    required this.ownHasGroup,
  });

  final String requestId;
  final SyncNearbyDevice device;
  final SyncPairingIntent intent;
  final PairingKeyPair keyPair;
  final Uint8List publicKey;
  final Uint8List nonce;
  final int expiresAt;
  final bool ownHasGroup;

  Uint8List? receiverPublicKey;
  Uint8List? receiverNonce;
  String? peerHost;
  String code = '';
  SyncPairingStatus status = SyncPairingStatus.pending;
  bool cancelled = false;

  void clearSecrets() {
    keyPair.destroy();
    receiverPublicKey = null;
    receiverNonce = null;
  }
}

class _BadPairingRequest implements Exception {
  const _BadPairingRequest(this.message);

  final String message;
}

class _PairingUnreachable implements Exception {
  const _PairingUnreachable(this.message);

  final String message;
}
