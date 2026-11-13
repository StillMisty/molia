/// 投屏会话控制器：发现 → 连接 → 远端播放 / 控制 → 断开。
///
/// 设计边界：
/// - 只依赖 `CastDiscovery` / `CastTransport` / `CastPlaybackPort` 三个端口；
/// - 命令串行执行（一次只发一条），远端轮询带代号，过期结果不会覆盖新命令；
/// - 开始投屏只暂停本地播放，**没有任何**恢复本地播放的调用；
/// - 断开 / 失败只发一次提示，本地保持暂停，绝不自动恢复出第二个声源；
/// - 不伪造本地 `PlaybackSnapshot`：远端位置只在 [remote] 读模型里。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/cast.dart';
import '../../domain/ports/cast_ports.dart';

enum CastNotice { disconnected, noDevices, noNext, sourceRejected, failed }

class CastSessionController extends ChangeNotifier {
  CastSessionController({
    required this.discovery,
    required this.transport,
    required this.playback,
    this.onNotice,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final CastDiscovery discovery;
  final CastTransport transport;
  final CastPlaybackPort playback;
  final void Function(CastNotice notice)? onNotice;
  final DateTime Function() _clock;

  CastSessionState _state = CastSessionState.idle;
  CastDevice? _activeDevice;
  CastMedia? _current;
  CastRemoteState _remote = const CastRemoteState();
  CastRejectionReason? _lastRejection;
  List<CastDevice> _devices = const [];
  bool _localPaused = false;
  bool _disposed = false;

  /// 命令代号：每条新命令 +1；轮询返回时代号变了就丢弃。
  int _generation = 0;

  /// 命令串行链：所有远端命令按调用顺序执行。
  Future<void> _tail = Future<void>.value();

  CastSessionState get state => _state;
  CastDevice? get activeDevice => _activeDevice;
  CastMedia? get current => _current;
  CastRemoteState get remote => _remote;
  CastRejectionReason? get lastRejection => _lastRejection;
  List<CastDevice> get devices => _devices;

  /// 本地是否已被投屏暂停（断开也不恢复）。
  bool get localPaused => _localPaused;

  bool get isConnected => _state == CastSessionState.connected;

  /// 按需发现；空列表进入 error 并发一次 noDevices 提示。
  Future<List<CastDevice>> discover() async {
    _state = CastSessionState.discovering;
    _lastRejection = null;
    _notify();
    try {
      _devices = await discovery.discover();
    } catch (_) {
      _devices = const [];
    }
    if (_disposed) return const [];
    _state = _devices.isEmpty ? CastSessionState.error : CastSessionState.idle;
    if (_devices.isEmpty) _notice(CastNotice.noDevices);
    _notify();
    return _devices;
  }

  Future<void> connect(CastDevice device) => _serialize(() async {
    _state = CastSessionState.connecting;
    _notify();
    try {
      await transport.connect(device);
      _activeDevice = device;
      _state = CastSessionState.connected;
    } catch (_) {
      _state = CastSessionState.error;
      _notice(CastNotice.failed);
    }
    _notify();
  });

  /// 投屏一条候选：先暂停本地一次，再让远端起播。
  Future<void> cast(CastCandidate candidate) => _serialize(() async {
    if (!isConnected) return;
    final eligibility = CastSourcePolicy.evaluate(
      candidate.source,
      now: _clock(),
    );
    if (!eligibility.isEligible) {
      _lastRejection = eligibility.reason;
      _notice(CastNotice.sourceRejected);
      _notify();
      return;
    }
    await _pauseLocalOnce();
    try {
      await transport.play(candidate.media);
      _current = candidate.media;
      _remote = CastRemoteState(
        isPlaying: true,
        duration: candidate.media.duration,
      );
      _generation++;
      _lastRejection = null;
    } catch (_) {
      _state = CastSessionState.error;
      _notice(CastNotice.failed);
    }
    _notify();
  });

  Future<void> pause() => _serialize(() async {
    if (!isConnected) return;
    _generation++;
    await transport.pause();
    _remote = CastRemoteState(
      position: _remote.position,
      isPlaying: false,
      duration: _remote.duration,
    );
    _notify();
  });

  Future<void> resume() => _serialize(() async {
    if (!isConnected) return;
    _generation++;
    await transport.resume();
    _remote = CastRemoteState(
      position: _remote.position,
      isPlaying: true,
      duration: _remote.duration,
    );
    _notify();
  });

  Future<void> seek(Duration position) => _serialize(() async {
    if (!isConnected) return;
    _generation++;
    await transport.seek(position);
    _remote = CastRemoteState(
      position: position,
      isPlaying: _remote.isPlaying,
      duration: _remote.duration,
    );
    _notify();
  });

  /// 下一首：从现有队列取候选并重新做来源判定；不合格不碰远端。
  Future<void> next() => _serialize(() async {
    if (!isConnected) return;
    CastCandidate? candidate;
    try {
      candidate = await playback.nextMedia();
    } catch (_) {
      candidate = null;
    }
    if (candidate == null) {
      _notice(CastNotice.noNext);
      return;
    }
    final eligibility = CastSourcePolicy.evaluate(
      candidate.source,
      now: _clock(),
    );
    if (!eligibility.isEligible) {
      _lastRejection = eligibility.reason;
      _notice(CastNotice.sourceRejected);
      _notify();
      return;
    }
    _generation++;
    await transport.play(candidate.media);
    _current = candidate.media;
    _remote = CastRemoteState(
      isPlaying: true,
      duration: candidate.media.duration,
    );
    _lastRejection = null;
    _notify();
  });

  /// 低频轮询：代号变了（有新命令）就丢弃这次结果。
  Future<void> poll() async {
    if (!isConnected) return;
    final generation = _generation;
    CastRemoteState next;
    try {
      next = await transport.poll();
    } catch (_) {
      return;
    }
    if (_disposed || generation != _generation || !isConnected) return;
    _remote = next;
    _notify();
  }

  /// 断开：停远端、本地保持暂停、只提示一次。
  Future<void> disconnect() => _serialize(() async {
    if (_state == CastSessionState.idle) return;
    try {
      await transport.stop();
    } catch (_) {
      // 远端已失联也照样收口本地状态。
    }
    _state = CastSessionState.idle;
    _activeDevice = null;
    _current = null;
    _remote = const CastRemoteState();
    _devices = const [];
    _localPaused = false;
    _generation++;
    _notice(CastNotice.disconnected);
    _notify();
  });

  Future<void> _pauseLocalOnce() async {
    if (_localPaused) return;
    _localPaused = true;
    try {
      await playback.pauseForCast();
    } catch (_) {
      // 暂停本地失败不应阻止远端起播；控制器仍记录已尝试。
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.catchError((_) {});
    return next;
  }

  void _notice(CastNotice notice) => onNotice?.call(notice);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(discovery.stop());
    super.dispose();
  }
}
