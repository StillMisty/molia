import 'dart:async';

import 'package:flutter/foundation.dart';

import 'lx_engine.dart';
import 'lx_engine_types.dart';
import 'lx_script_info.dart';

/// 引擎生命周期状态（施工图 docs/architecture.md §2.5.1）。
///
/// ```
/// stopped ──start(script)──▶ starting ──ready──▶ ready
///    ▲                          │ 失败              │ invoke 超时 / isolate 退出
///    │                          ▼                   ▼
///    └────────────────────── restarting ◀───────────┘
///                              │ 连续失败 ≥ restartDelays.length
///                              ▼
///                            failed
/// ```
enum LxEngineState {
  /// 未启动 / 已 dispose。
  stopped,

  /// 正在执行脚本（外部 [LxEngineSupervisor.start]）。
  starting,

  /// 脚本就绪，可接受 invoke。
  ready,

  /// 崩溃后按退避间隔自动重放 [LxEngineSupervisor.start]。
  restarting,

  /// 连续多次自动重启失败：停止自动重启，直到外部再次 [LxEngineSupervisor.start]。
  failed,
}

/// `LxEngine` 的自愈包装（组合而非继承，引擎本体与协议零改动）。
///
/// 职责：
/// - 对外 API 与 [LxEngine] 同名同签名，`SourceManager` 可最小替换；
/// - invoke 超时 / isolate 退出（表现为 `engine.isRunning == false`）后，
///   用**同一脚本**按 0.5s / 2s / 8s 退避自动重放 `start`；
/// - 重启期间到达的请求等待 ready（默认 10s 上限），超时才失败；
/// - 连续 [restartDelays] 次崩溃（重放 `start` 失败，或重启后再次崩溃且期间
///   没有任何成功 invoke）进入 [LxEngineState.failed]，不再自动重启，避免
///   “脚本每次都崩溃时每首歌都吃满 20s 超时”；
/// - 每次状态迁移通过 [onStateChanged] 同步通知（SourceManager 借此在重启
///   成功后刷新 `activeSources`，修复“引擎死了源列表还在”）。
///
/// Web 占位实现（stub）下不进入状态机：invoke 直接透传失败，避免无意义的重启循环。
class LxEngineSupervisor {
  LxEngineSupervisor({
    LxEngine Function()? engineFactory,
    List<Duration> restartDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 2),
      Duration(seconds: 8),
    ],
    Duration readyWaitTimeout = const Duration(seconds: 10),
  })  : assert(restartDelays.isNotEmpty, '至少需要一个退避间隔'),
        _engine = (engineFactory ?? LxEngine.new)(),
        _restartDelays = List<Duration>.unmodifiable(restartDelays),
        _readyWaitTimeout = readyWaitTimeout;

  /// 被包装的引擎实例（重启时复用同一实例重放 `start`）。
  final LxEngine _engine;

  /// 自动重启的退避间隔；长度即最大连续重启次数。
  final List<Duration> _restartDelays;

  /// 重启期间等待 ready 的上限。
  final Duration _readyWaitTimeout;

  LxEngineState _state = LxEngineState.stopped;
  LxScriptInfo? _lastScript;
  int _restartAttempts = 0;
  int _restartGeneration = 0;
  Timer? _backoffTimer;
  Completer<bool>? _backoffCompleter;
  Completer<void>? _readyCompleter;
  bool _disposed = false;

  /// 状态迁移回调（同步触发；仅在状态确实变化时调用）。
  void Function(LxEngineState state)? onStateChanged;

  /// 当前状态。
  LxEngineState get state => _state;

  /// 是否处于「连续重启失败」终态。
  bool get isFailed => _state == LxEngineState.failed;

  /// 是否正在自动重启。
  bool get isRestarting => _state == LxEngineState.restarting;

  /// 连续崩溃计数（诊断/测试用）：重放 start 失败或重启后再次崩溃时累加，
  /// 任意一次成功 invoke 后清零。
  int get restartAttempts => _restartAttempts;

  /// 与 [LxEngine.isRunning] 同义，但重启期间为 false。
  bool get isRunning => _state == LxEngineState.ready && _engine.isRunning;

  Stream<LxLogEntry> get logs => _engine.logs;
  Stream<LxUpdateAlert> get updateAlerts => _engine.updateAlerts;
  Map<String, LxSourceDecl> get sources => _engine.sources;
  LxScriptInfo? get script => _engine.script;

  /// 启动引擎并运行脚本（外部入口；同时记录脚本供自动重启重放）。
  ///
  /// 失败时状态回到 [LxEngineState.stopped] 并原样抛出（不做自动重启，
  /// 由调用方决定是否重试）；成功进入 [LxEngineState.ready] 并触发回调。
  Future<Map<String, LxSourceDecl>> start(
    LxScriptInfo script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _lastScript = script;
    _cancelPendingRestart();
    _restartAttempts = 0;
    _setState(LxEngineState.starting);
    try {
      final sources = await _engine.start(script, timeout: timeout);
      _setState(LxEngineState.ready);
      return sources;
    } catch (_) {
      _setState(LxEngineState.stopped);
      rethrow;
    }
  }

  Future<String> getMusicUrl({
    required String source,
    required Map<String, dynamic> musicInfo,
    required String quality,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _guard(() => _engine.getMusicUrl(
          source: source,
          musicInfo: musicInfo,
          quality: quality,
          timeout: timeout,
        ));
  }

  Future<LxLyricResult> getLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _guard(() => _engine.getLyric(
          source: source,
          musicInfo: musicInfo,
          timeout: timeout,
        ));
  }

  Future<String> getPic({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) {
    return _guard(() => _engine.getPic(
          source: source,
          musicInfo: musicInfo,
          timeout: timeout,
        ));
  }

  Future<dynamic> search({
    required String source,
    required String action,
    required String keyword,
    int page = 1,
    int limit = 20,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _guard(() => _engine.search(
          source: source,
          action: action,
          keyword: keyword,
          page: page,
          limit: limit,
          timeout: timeout,
        ));
  }

  /// 停止引擎并取消待执行的自动重启（可再次 [start] 复用同一实例）。
  Future<void> dispose() async {
    _cancelPendingRestart();
    _lastScript = null;
    _restartAttempts = 0;
    _setState(LxEngineState.stopped);
    await _engine.dispose();
  }

  /// 终态关闭：取消自动重启并关闭底层引擎（含日志/告警流）。
  Future<void> close() async {
    _disposed = true;
    _cancelPendingRestart();
    _lastScript = null;
    _restartAttempts = 0;
    _setState(LxEngineState.stopped);
    await _engine.close();
  }

  // 内部实现

  /// invoke 统一入口：确保 ready → 执行 → 崩溃检测/触发重启。
  Future<T> _guard<T>(Future<T> Function() action) async {
    // Web stub：没有 isolate 可自愈，直接透传失败。
    if (kIsWeb) return action();

    if (_state == LxEngineState.ready && !_engine.isRunning) {
      _handleCrash(); // isolate 已退出但尚无 invoke 失败：立即进入重启
    }
    await _ensureReady();
    try {
      final result = await action();
      // 有成功请求证明脚本恢复健康：清零连续崩溃计数。
      _restartAttempts = 0;
      return result;
    } catch (e) {
      if (!_disposed && !_engine.isRunning) {
        _handleCrash(); // invoke 超时 / isolate 退出
      }
      rethrow;
    }
  }

  /// 等待引擎就绪；重启期间最多等待 [_readyWaitTimeout]。
  Future<void> _ensureReady() async {
    if (_state == LxEngineState.ready) return;
    if (_state == LxEngineState.starting ||
        _state == LxEngineState.restarting) {
      final completer = _readyCompleter;
      if (completer != null) {
        try {
          await completer.future.timeout(_readyWaitTimeout);
        } on TimeoutException {
          throw const LxEngineException('音源引擎重启超时，请稍后重试');
        }
      }
      if (_state == LxEngineState.ready) return;
    }
    throw const LxEngineException('音源引擎未运行');
  }

  /// 检测到崩溃：进入 [LxEngineState.restarting] 并启动退避重启循环。
  void _handleCrash() {
    if (_disposed || kIsWeb) return;
    if (_state == LxEngineState.restarting || _state == LxEngineState.failed) {
      return; // 已在重启/已停用：避免并发重复触发
    }
    final script = _lastScript;
    if (script == null) return; // 从未成功 start：无脚本可重放
    // 连续崩溃计数只在有成功请求后清零（见 _guard）；达到上限直接停用，
    // 避免“每次重启都成功、但脚本每次都崩溃”时无限循环 20s 超时。
    if (_restartAttempts >= _restartDelays.length) {
      _setState(LxEngineState.failed);
      return;
    }
    _setState(LxEngineState.restarting);
    final generation = _restartGeneration;
    unawaited(_restartLoop(generation));
  }

  /// 退避重启循环：间隔取 [_restartDelays]，每次尝试重放同一脚本。
  Future<void> _restartLoop(int generation) async {
    final script = _lastScript;
    if (script == null) {
      _setState(LxEngineState.failed);
      return;
    }
    while (!_disposed &&
        generation == _restartGeneration &&
        _state == LxEngineState.restarting) {
      final index = _restartAttempts < _restartDelays.length
          ? _restartAttempts
          : _restartDelays.length - 1;
      final cancelled = !await _waitBackoff(_restartDelays[index]);
      if (cancelled ||
          _disposed ||
          generation != _restartGeneration ||
          _state != LxEngineState.restarting) {
        return;
      }
      _restartAttempts++;
      try {
        await _engine.start(script);
        if (_disposed || generation != _restartGeneration) return;
        // 注意：不在此清零 _restartAttempts——只有成功 invoke 才证明恢复；
        // 若重启后再次崩溃，计数继续累加，达到上限进入 failed。
        _setState(LxEngineState.ready);
        return;
      } catch (e) {
        if (_disposed || generation != _restartGeneration) return;
        if (kDebugMode) {
          debugPrint('[LxEngineSupervisor] 自动重启失败'
              '($_restartAttempts/${_restartDelays.length}): $e');
        }
        if (_restartAttempts >= _restartDelays.length) {
          _setState(LxEngineState.failed);
          return;
        }
      }
    }
  }

  /// 可取消的退避等待；返回 false 表示被外部 start/dispose 取消。
  Future<bool> _waitBackoff(Duration delay) {
    if (delay <= Duration.zero) return Future<bool>.value(true);
    final completer = Completer<bool>();
    _backoffCompleter = completer;
    _backoffTimer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete(true);
    });
    return completer.future.whenComplete(() {
      if (identical(_backoffCompleter, completer)) _backoffCompleter = null;
      _backoffTimer = null;
    });
  }

  /// 使当前重启循环失效并唤醒退避等待。
  void _cancelPendingRestart() {
    _restartGeneration++;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    final backoff = _backoffCompleter;
    _backoffCompleter = null;
    if (backoff != null && !backoff.isCompleted) backoff.complete(false);
  }

  void _setState(LxEngineState next) {
    if (_state == next) return;
    _state = next;
    switch (next) {
      case LxEngineState.starting:
      case LxEngineState.restarting:
        _readyCompleter ??= Completer<void>();
        break;
      case LxEngineState.ready:
      case LxEngineState.failed:
      case LxEngineState.stopped:
        final completer = _readyCompleter;
        _readyCompleter = null;
        // 统一以正常完成唤醒等待者：由等待方检查状态决定成功/失败，
        // 避免无监听者的 completeError 变成未处理异步异常。
        if (completer != null && !completer.isCompleted) completer.complete();
        break;
    }
    if (!_disposed) onStateChanged?.call(next);
  }
}
