/// 听歌同步观察者：把播放快照 / 进度转成事件并异步投递。
///
/// 硬约束：
/// - **纯观察者**：不 import provider、不改播放内核；组合根把
///   `PlaybackProvider` 的快照与 position 通道接进来；
/// - 永不阻塞播放：入队是内存 + 一次 prefs 写，发送全部在独立 Future 中；
/// - 每个服务同一时间最多一个在途请求；失败按 outbox 的退避重试；
/// - 日志不含访问口令、会话密钥、签名或请求正文。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../domain/models/playback.dart';
import '../../domain/models/scrobble.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/scrobble_sink.dart';
import '../../domain/scrobble/scrobble_rules.dart';
import 'lastfm_sink.dart';
import 'scrobble_outbox.dart';
import 'scrobble_preferences.dart';

/// 连接操作的结论（设置页据此给文案）。
enum ScrobbleConnectResult { connected, invalidCredential, unreachable }

class ScrobbleService extends ChangeNotifier {
  ScrobbleService({
    required this.preferences,
    required this.outbox,
    required ScrobbleSink listenBrainzSink,
    required ScrobbleSink lastFmSink,
    required LastFmApiConfig lastFmConfig,
    Future<bool> Function(Uri uri)? openBrowser,
    LastFmAuth Function()? lastFmAuthBuilder,
    DateTime Function()? clock,
    this.autoDeliver = true,
  }) : _sinks = {
         ScrobbleTarget.listenBrainz: listenBrainzSink,
         ScrobbleTarget.lastFm: lastFmSink,
       },
       _lastFmConfig = lastFmConfig,
       _lastFmAuthBuilder =
           lastFmAuthBuilder ??
           (() => LastFmAuth(
             config: lastFmConfig,
             openBrowser: openBrowser ?? ((_) async => false),
           )),
       _clock = clock ?? DateTime.now;

  final ScrobblePreferences preferences;
  final ScrobbleOutbox outbox;
  final Map<ScrobbleTarget, ScrobbleSink> _sinks;
  final LastFmApiConfig _lastFmConfig;
  final LastFmAuth Function() _lastFmAuthBuilder;
  final DateTime Function() _clock;

  /// 生产为 true；单测关掉后手动调用 [pumpNow]，避免真实计时器。
  final bool autoDeliver;

  final Logger _logger = Logger('molia.scrobble');

  final Map<ScrobbleTarget, ScrobbleTargetStatus> _statuses = {
    ScrobbleTarget.listenBrainz: ScrobbleTargetStatus.disconnected,
    ScrobbleTarget.lastFm: ScrobbleTargetStatus.disconnected,
  };
  final Map<ScrobbleTarget, String> _credentials = {};
  final Set<ScrobbleTarget> _inFlight = {};
  final Set<String> _loggedSkipped = {};

  bool _ready = false;
  bool _disposed = false;
  Timer? _timer;
  PlaybackSnapshot _snapshot = PlaybackSnapshot.empty;
  ScrobbleSession? _session;
  String? _sessionIdentity;
  LastFmAuth? _lastFmAuth;

  bool get ready => _ready;

  bool get masterEnabled => preferences.masterEnabled;

  bool get lastFmConfigured => _lastFmConfig.isConfigured;

  LastFmAuthStage get lastFmStage => _lastFmAuth?.stage ?? LastFmAuthStage.idle;

  Uri? get lastFmAuthorizationUri => _lastFmAuth?.authorizationUri;

  ScrobbleTargetStatus statusOf(ScrobbleTarget target) =>
      _statuses[target] ?? ScrobbleTargetStatus.disconnected;

  String accountOf(ScrobbleTarget target) => preferences.accountFor(target);

  /// 当前内存中的凭证（sink 的同步回调读它；不在日志 / UI 暴露）。
  String credentialFor(ScrobbleTarget target) => _credentials[target] ?? '';

  bool consentFor(ScrobbleTarget target) => preferences.consentFor(target);

  int queuedFor(ScrobbleTarget target) => outbox.lengthFor(target);

  /// 单个服务是否真正在发送：总开关 + 服务开关 + 凭据齐全。
  bool activeFor(ScrobbleTarget target) =>
      masterEnabled &&
      preferences.enabledFor(target) &&
      (_credentials[target] ?? '').isNotEmpty;

  /// 授权失效后停止发送，直到用户重新连接（凭据保留，队列保留）。
  bool _canSend(ScrobbleTarget target) =>
      activeFor(target) &&
      statusOf(target) != ScrobbleTargetStatus.needsAuthorization;

  /// 首帧后的启动尾巴：读偏好 / 凭据 / 发件箱，恢复在途状态。
  Future<void> init() async {
    await preferences.init();
    await outbox.load();
    for (final target in ScrobbleTarget.values) {
      _credentials[target] = await preferences.readCredential(target);
      _statuses[target] = _initialStatus(target);
    }
    _ready = true;
    _syncSession(_snapshot);
    _schedule();
    _notify();
  }

  /// 凭据可能由另一台设备同步过来：重读偏好与口令，但不改变设备本地开关。
  Future<void> reloadFromPreferences() async {
    if (!_ready) return;
    await preferences.init();
    for (final target in ScrobbleTarget.values) {
      _credentials[target] = await preferences.readCredential(target);
      if (_statuses[target] != ScrobbleTargetStatus.needsAuthorization) {
        _statuses[target] = _initialStatus(target);
      }
    }
    _notify();
  }

  ScrobbleTargetStatus _initialStatus(ScrobbleTarget target) {
    if (!preferences.enabledFor(target)) {
      return ScrobbleTargetStatus.disconnected;
    }
    if ((_credentials[target] ?? '').isEmpty) {
      return ScrobbleTargetStatus.needsAuthorization;
    }
    return ScrobbleTargetStatus.connected;
  }

  // ---------------------------------------------------------------------
  // 设置 / 授权
  // ---------------------------------------------------------------------

  Future<void> grantConsent(ScrobbleTarget target) async {
    await preferences.recordConsent(target);
    _notify();
  }

  Future<void> setMasterEnabled(bool value) async {
    await preferences.setMasterEnabled(value);
    if (!value) _endSession();
    _schedule();
    _notify();
  }

  Future<ScrobbleConnectResult> connectListenBrainz(String token) async {
    final credential = token.trim();
    final sink = _sinks[ScrobbleTarget.listenBrainz];
    if (sink is! ScrobbleCredentialSink) {
      return ScrobbleConnectResult.unreachable;
    }
    final credentialSink = sink as ScrobbleCredentialSink;
    final check = await credentialSink.validateCredential(credential);
    if (!check.reachable) return ScrobbleConnectResult.unreachable;
    if (!check.isValid) return ScrobbleConnectResult.invalidCredential;

    await preferences.writeCredential(ScrobbleTarget.listenBrainz, credential);
    _credentials[ScrobbleTarget.listenBrainz] = credential;
    await preferences.recordConsent(ScrobbleTarget.listenBrainz);
    await preferences.setEnabled(ScrobbleTarget.listenBrainz, true);
    await preferences.setAccount(
      ScrobbleTarget.listenBrainz,
      check.accountName ?? '',
    );
    await preferences.setMasterEnabled(true);
    _statuses[ScrobbleTarget.listenBrainz] = ScrobbleTargetStatus.connected;
    _spawnSessionIfNeeded();
    _schedule();
    _notify();
    return ScrobbleConnectResult.connected;
  }

  /// 开始 Last.fm 浏览器授权；返回 null 表示本版本未内置应用凭证。
  Future<LastFmAuthStage> beginLastFmAuthorization() async {
    _lastFmAuth = _lastFmAuthBuilder();
    final stage = await _lastFmAuth!.begin();
    _notify();
    return stage;
  }

  /// 用户从浏览器回来后确认完成，用临时令牌换会话密钥。
  Future<LastFmAuthStage> completeLastFmAuthorization() async {
    final auth = _lastFmAuth;
    if (auth == null) return LastFmAuthStage.failed;
    final stage = await auth.complete();
    if (stage != LastFmAuthStage.connected) {
      _notify();
      return stage;
    }
    final key = auth.takeSessionKey();
    if (key == null || key.isEmpty) {
      _notify();
      return LastFmAuthStage.failed;
    }
    await preferences.writeCredential(ScrobbleTarget.lastFm, key);
    _credentials[ScrobbleTarget.lastFm] = key;
    await preferences.recordConsent(ScrobbleTarget.lastFm);
    await preferences.setEnabled(ScrobbleTarget.lastFm, true);
    await preferences.setAccount(ScrobbleTarget.lastFm, auth.accountName ?? '');
    await preferences.setMasterEnabled(true);
    _statuses[ScrobbleTarget.lastFm] = ScrobbleTargetStatus.connected;
    _lastFmAuth = null;
    _spawnSessionIfNeeded();
    _schedule();
    _notify();
    return LastFmAuthStage.connected;
  }

  void cancelLastFmAuthorization() {
    _lastFmAuth?.cancel();
    _lastFmAuth = null;
    _notify();
  }

  /// 断开：清凭据、清该服务的待发送事件、关闭该服务的开关。
  Future<void> disconnect(ScrobbleTarget target) async {
    await preferences.clearCredential(target);
    _credentials[target] = '';
    await preferences.setEnabled(target, false);
    await preferences.setAccount(target, '');
    await outbox.discardTarget(target);
    _statuses[target] = ScrobbleTargetStatus.disconnected;
    if (_lastFmAuth != null && target == ScrobbleTarget.lastFm) {
      _lastFmAuth = null;
    }
    final anyEnabled = ScrobbleTarget.values.any(preferences.enabledFor);
    if (!anyEnabled) {
      await preferences.setMasterEnabled(false);
    }
    _endSession();
    _notify();
  }

  /// 供测试与设置页诊断：当前发件箱条目总数。
  int get queuedTotal => outbox.length;

  // ---------------------------------------------------------------------
  // 播放观察入口（组合根接线）
  // ---------------------------------------------------------------------

  void onSnapshot(PlaybackSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_ready) return;
    _syncSession(snapshot);
  }

  void onPosition(Duration position) {
    if (!_ready || !_snapshot.isPlaying) return;
    final session = _session;
    if (session == null) return;
    final event = session.onPosition(position);
    if (event == null) return;
    _enqueueForActiveTargets(event);
  }

  void _syncSession(PlaybackSnapshot snapshot) {
    final track = snapshot.current;
    final identity = track == null ? null : _identityOf(track);
    if (track == null) {
      _endSession();
      return;
    }
    if (!snapshot.isPlaying) return;
    if (!ScrobbleTarget.values.any(activeFor)) {
      // 没有启用的服务时不建立会话：用户中途开启只从现在开始算。
      _endSession();
      return;
    }
    if (_session != null && _sessionIdentity == identity) return;
    final scrobbleTrack = _toScrobbleTrack(track, snapshot);
    if (scrobbleTrack == null || !ScrobbleRules.isEligible(scrobbleTrack)) {
      if (scrobbleTrack != null && _loggedSkipped.add(identity!)) {
        _logger.info('曲目缺少标题 / 歌手或短于 30 秒，不参与听歌同步');
      }
      _endSession();
      return;
    }
    _session = ScrobbleSession(
      track: scrobbleTrack,
      startedAt: _clock().toUtc(),
    );
    _sessionIdentity = identity;
    _emitNowPlaying(_session!);
  }

  /// 服务在播放中途被开启：为当前正在播放的曲目补一个会话（不下发已播
  /// 过的进度，避免把开启前的播放也上报）。
  void _spawnSessionIfNeeded() {
    if (_snapshot.current == null || !_snapshot.isPlaying) return;
    _syncSession(_snapshot);
  }

  void _endSession() {
    _session = null;
    _sessionIdentity = null;
  }

  ScrobbleTrack? _toScrobbleTrack(Track track, PlaybackSnapshot snapshot) {
    final duration = (track.duration ?? Duration.zero) > Duration.zero
        ? track.duration!
        : snapshot.duration;
    return ScrobbleTrack(
      title: track.title.trim(),
      artist: track.artistLabel.trim(),
      album: track.album?.trim(),
      duration: duration,
    );
  }

  static String _identityOf(Track track) => track.id.uri;

  void _emitNowPlaying(ScrobbleSession session) {
    final event = session.nowPlayingEvent();
    for (final target in ScrobbleTarget.values) {
      if (!_canSend(target)) continue;
      final sink = _sinks[target]!;
      unawaited(_deliverNowPlaying(target, sink, event.listen));
    }
  }

  Future<void> _deliverNowPlaying(
    ScrobbleTarget target,
    ScrobbleSink sink,
    ScrobbleListen listen,
  ) async {
    try {
      final delivery = await sink.sendNowPlaying(listen);
      if (delivery.outcome == ScrobbleDeliveryOutcome.unauthorized) {
        _statuses[target] = ScrobbleTargetStatus.needsAuthorization;
        _notify();
      }
      // 其余失败静默：now-playing 是提示，不进 outbox，不打扰用户。
    } catch (_) {
      // 观察者永远不把异常抛回播放链路。
    }
  }

  void _enqueueForActiveTargets(ScrobbleEvent base) {
    for (final target in ScrobbleTarget.values) {
      if (!_canSend(target)) continue;
      final event = base.copyWith(
        id: '${base.id}-${target.name}',
        target: target,
        createdAt: _clock().toUtc(),
      );
      unawaited(outbox.add(event));
    }
    if (autoDeliver) unawaited(pumpNow());
  }

  // ---------------------------------------------------------------------
  // 投递调度
  // ---------------------------------------------------------------------

  /// 检查所有到期的条目并投递；每个服务最多一个在途请求。
  Future<void> pumpNow() async {
    if (!_ready || _disposed) return;
    final deliveries = <Future<void>>[];
    for (final target in ScrobbleTarget.values) {
      if (!_canSend(target) || _inFlight.contains(target)) continue;
      final due = outbox.due(target);
      if (due.isEmpty) continue;
      final entry = due.first;
      _inFlight.add(target);
      deliveries.add(
        _deliver(target, entry).whenComplete(() {
          _inFlight.remove(target);
          _schedule();
        }),
      );
    }
    if (deliveries.isNotEmpty) await Future.wait(deliveries);
    _schedule();
  }

  Future<void> _deliver(
    ScrobbleTarget target,
    ScrobbleOutboxEntry entry,
  ) async {
    final sink = _sinks[target];
    if (sink == null) return;
    ScrobbleDelivery delivery;
    try {
      delivery = await sink.sendScrobble(entry.event.listen);
    } catch (_) {
      delivery = const ScrobbleDelivery.retryable();
    }
    if (_disposed) return;
    switch (delivery.outcome) {
      case ScrobbleDeliveryOutcome.success:
        await outbox.markDelivered(entry.event.id);
        _statuses[target] = ScrobbleTargetStatus.connected;
      case ScrobbleDeliveryOutcome.retryable:
        await outbox.markRetry(entry.event.id, retryAfter: delivery.retryAfter);
        _statuses[target] = ScrobbleTargetStatus.retrying;
      case ScrobbleDeliveryOutcome.unauthorized:
        _statuses[target] = ScrobbleTargetStatus.needsAuthorization;
      case ScrobbleDeliveryOutcome.permanent:
        // 请求本身不可能成功：丢掉这一条，避免永久占用发件箱。
        await outbox.drop(entry.event.id);
        _statuses[target] = ScrobbleTargetStatus.error;
    }
    _notify();
  }

  void _schedule() {
    if (!autoDeliver || !_ready || _disposed) return;
    _timer?.cancel();
    _timer = null;
    final next = outbox.nextDueAt();
    if (next == null) return;
    final now = _clock();
    var delay = next.difference(now);
    if (delay.isNegative) delay = Duration.zero;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(pumpNow());
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
