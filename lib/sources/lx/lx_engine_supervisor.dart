import 'dart:async';

import 'package:flutter/foundation.dart';

import 'lx_engine.dart';
import 'lx_engine_types.dart';
import 'lx_script_info.dart';

/// 引擎生命周期状态（施工图 docs/architecture.md §2.5.1）。
///
/// ```
/// stopped ──start(script)──▶ starting ──ready──▶ ready
///    ▲                          │ 失败              │ isolate 退出 / 引擎无响应
///    │                          ▼                   ▼
///    └────────────────────── restarting ◀───────────┘
///                              │ 连续失败 ≥ 阈值（重启尝试次数 / 连续超时次数）
///                              ▼
///                            failed
///                              │ 冷却后（下一次 invoke / retryNow）
///                              ▼
///                          starting ──成功──▶ ready；失败 → failed（重置冷却）
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

  /// 连续多次自动重启失败（或连续超时熔断）：先释放 isolate，冷却
  /// `recoveryCooldown` 后由下一次请求自动做一次半开恢复（重放同一脚本），
  /// 也可由 [LxEngineSupervisor.retryNow] 绕过冷却立即尝试；原因见
  /// [LxEngineSupervisor.failureReason]。
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
///   没有任何成功 invoke）进入 [LxEngineState.failed]，先暂停自动重启，避免
///   “脚本每次都崩溃时每首歌都吃满 20s 超时”；
/// - `failed` 不是终点：记录失败时刻，冷却 `recoveryCooldown`（默认 60s）后
///   由下一次 invoke 自动做**一次**半开恢复（重放同一脚本），成功即回到
///   [LxEngineState.ready]；失败重新进入 `failed` 并重置冷却。并发请求共享
///   同一次半开恢复（single-flight），不会重复 `start`；[retryNow] 供「重试」
///   按钮 / 网络恢复绕过冷却立即尝试一次；
/// - invoke 超时不再杀掉引擎（引擎侧会自动探活，只有真卡死才重启），
///   但连续 [maxConsecutiveTimeouts] 次超时说明脚本「每次起来都慢」，
///   同样进入 [LxEngineState.failed] 并记录 [failureReason]；
/// - 每次状态迁移通过 [onStateChanged] 同步通知（SourceManager 借此在重启
///   成功后刷新 `activeSources`，修复“引擎死了源列表还在”）。
class LxEngineSupervisor {
  LxEngineSupervisor({
    LxEngine Function()? engineFactory,
    List<Duration> restartDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 2),
      Duration(seconds: 8),
    ],
    this._readyWaitTimeout = const Duration(seconds: 10),
    int maxConsecutiveTimeouts = 3,
    Duration recoveryCooldown = const Duration(seconds: 60),
  }) : assert(restartDelays.isNotEmpty, '至少需要一个退避间隔'),
       assert(maxConsecutiveTimeouts > 0, '熔断阈值必须为正数'),
       assert(!recoveryCooldown.isNegative, '半开恢复冷却不能为负（0 表示每次请求都可立即重试）'),
       _engine = (engineFactory ?? LxEngine.new)(),
       _restartDelays = List<Duration>.unmodifiable(restartDelays),
       _maxConsecutiveTimeouts = maxConsecutiveTimeouts,
       _recoveryCooldown = recoveryCooldown;

  /// 被包装的引擎实例（重启时复用同一实例重放 `start`）。
  final LxEngine _engine;

  /// 自动重启的退避间隔；长度即最大连续重启次数。
  final List<Duration> _restartDelays;

  /// 重启期间等待 ready 的上限。
  final Duration _readyWaitTimeout;

  /// 连续超时熔断阈值（见 [restartAttempts] 旁的说明）。
  final int _maxConsecutiveTimeouts;

  /// failed 后的半开恢复冷却：冷却期内请求直接失败，不再反复重跑脚本
  /// （脚本启动本身要几百毫秒，断网时每次请求都重跑等于白烧 CPU）。
  final Duration _recoveryCooldown;

  LxEngineState _state = LxEngineState.stopped;
  LxScriptInfo? _lastScript;
  int _restartAttempts = 0;
  int _consecutiveTimeouts = 0;
  int _restartGeneration = 0;
  int _recoveryGeneration = 0;
  Timer? _backoffTimer;
  Completer<bool>? _backoffCompleter;
  Completer<void>? _readyCompleter;
  Completer<void>? _recoveryCompleter;
  DateTime? _failedAt;
  bool _disposed = false;
  String? _failureReason;

  /// 状态迁移回调（同步触发；仅在状态确实变化时调用）。
  void Function(LxEngineState state)? onStateChanged;

  /// 当前状态。
  LxEngineState get state => _state;

  /// 是否处于「已停止、等待半开恢复」状态（冷却期内请求直接失败）。
  bool get isFailed => _state == LxEngineState.failed;

  /// 是否正在自动重启。
  bool get isRestarting => _state == LxEngineState.restarting;

  /// 进入 [LxEngineState.failed] 的原因（诊断 / 上报用）；未处于 failed 时为 null。
  String? get failureReason => _failureReason;

  /// 连续崩溃计数（诊断/测试用）：重放 start 失败或重启后再次崩溃时累加，
  /// 任意一次成功 invoke 后清零。
  int get restartAttempts => _restartAttempts;

  /// 连续超时计数（诊断/测试用）：引擎存活但连续不回响应时累加，
  /// 任意一次成功 invoke 后清零。
  int get consecutiveTimeouts => _consecutiveTimeouts;

  /// 与 [LxEngine.isRunning] 同义，但重启期间为 false。
  bool get isRunning => _state == LxEngineState.ready && _engine.isRunning;

  Stream<LxLogEntry> get logs => _engine.logs;
  Stream<LxUpdateAlert> get updateAlerts => _engine.updateAlerts;
  Map<String, LxSourceDecl> get sources => _engine.sources;
  LxScriptInfo? get script => _engine.script;

  /// 启动引擎并运行脚本（外部入口；同时记录脚本供自动重启 / 半开恢复重放）。
  ///
  /// 失败时状态回到 [LxEngineState.stopped] 并原样抛出（不做自动重启，
  /// 由调用方决定是否重试）；成功进入 [LxEngineState.ready] 并触发回调。
  Future<Map<String, LxSourceDecl>> start(
    LxScriptInfo script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _lastScript = script;
    _cancelPendingRestart();
    _cancelPendingRecovery();
    _restartAttempts = 0;
    _consecutiveTimeouts = 0;
    _failureReason = null;
    _failedAt = null;
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
    return _guard(
      () => _engine.getMusicUrl(
        source: source,
        musicInfo: musicInfo,
        quality: quality,
        timeout: timeout,
      ),
    );
  }

  Future<LxLyricResult> getLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _guard(
      () => _engine.getLyric(
        source: source,
        musicInfo: musicInfo,
        timeout: timeout,
      ),
    );
  }

  Future<String> getPic({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) {
    return _guard(
      () => _engine.getPic(
        source: source,
        musicInfo: musicInfo,
        timeout: timeout,
      ),
    );
  }

  Future<dynamic> search({
    required String source,
    required String action,
    required String keyword,
    int page = 1,
    int limit = 20,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _guard(
      () => _engine.search(
        source: source,
        action: action,
        keyword: keyword,
        page: page,
        limit: limit,
        timeout: timeout,
      ),
    );
  }

  /// 立即尝试一次恢复，绕过半开冷却（音源页「重试」/ 网络恢复触发）。
  ///
  /// 返回是否已恢复到可用状态：无脚本 / 已 ready 时没有可做的事，同样返回
  /// true；尝试失败时保持 [LxEngineState.failed] 并重置冷却，返回 false。
  Future<bool> retryNow() async {
    if (_disposed) return false;
    if (_state == LxEngineState.ready) return true;
    if (_state == LxEngineState.starting ||
        _state == LxEngineState.restarting) {
      // 已有启动 / 重启在途：等它出结果，不再叠加第二次 start。
      try {
        await _ensureReady();
      } on LxEngineException {
        return false;
      }
      return _state == LxEngineState.ready;
    }
    if (_lastScript == null) return true;
    await _runRecoveryAttempt();
    return _state == LxEngineState.ready;
  }

  /// 停止引擎并取消待执行的自动重启（可再次 [start] 复用同一实例）。
  Future<void> dispose() async {
    _cancelPendingRestart();
    _cancelPendingRecovery();
    _lastScript = null;
    _restartAttempts = 0;
    _consecutiveTimeouts = 0;
    _failureReason = null;
    _failedAt = null;
    _setState(LxEngineState.stopped);
    await _engine.dispose();
  }

  /// 终态关闭：取消自动重启并关闭底层引擎（含日志/告警流）。
  Future<void> close() async {
    _disposed = true;
    _cancelPendingRestart();
    _cancelPendingRecovery();
    _lastScript = null;
    _restartAttempts = 0;
    _consecutiveTimeouts = 0;
    _failureReason = null;
    _failedAt = null;
    _setState(LxEngineState.stopped);
    await _engine.close();
  }

  /// invoke 统一入口：确保 ready → 执行 → 崩溃检测/触发重启。
  Future<T> _guard<T>(Future<T> Function() action) async {
    if (_state == LxEngineState.failed) {
      // failed 不是终点：冷却后由下一次请求自动尝试一次半开恢复。
      await _recoverFromFailed();
    } else if (_state == LxEngineState.ready && !_engine.isRunning) {
      _handleCrash(); // isolate 已退出但尚无 invoke 失败：立即进入重启
    }
    await _ensureReady();
    try {
      final result = await action();
      // 有成功请求证明脚本恢复健康：清零连续崩溃 / 超时计数。
      _restartAttempts = 0;
      _consecutiveTimeouts = 0;
      return result;
    } on LxEngineTimeoutException {
      // 只统计「引擎活着但请求没回响应」：引擎侧探活已排除卡死，不重启。
      // 网络类失败（脚本里的 HTTP 报错）走下面的通用分支，不算进超时熔断。
      _consecutiveTimeouts++;
      if (_consecutiveTimeouts >= _maxConsecutiveTimeouts) {
        await _fail('音源脚本连续 $_consecutiveTimeouts 次请求超时，已停止自动重试');
      }
      rethrow;
    } catch (e) {
      if (!_disposed && !_engine.isRunning) {
        _handleCrash(); // isolate 退出 / 引擎无响应被重启
      }
      rethrow;
    }
  }

  /// failed 状态下的入口门：冷却未到直接拒绝，冷却已到尝试一次半开恢复。
  ///
  /// 冷却用「失败时刻 + 冷却时长」而不是一次性 Timer：应用可能整段挂着不动，
  /// 按需判定不会有定时器泄漏，也天然把「用户刚点播放」当作恢复时机。
  Future<void> _recoverFromFailed() async {
    final reason = _failureReason ?? '音源引擎已停止';
    final failedAt = _failedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _recoveryCooldown) {
      throw LxEngineUnavailableException(reason);
    }
    if (_lastScript == null) {
      // 没有脚本可重放（理论上只出现在构造后未 start 就 failed）：不假装恢复。
      throw LxEngineUnavailableException(reason);
    }
    await _runRecoveryAttempt();
    if (_state != LxEngineState.ready) {
      throw LxEngineUnavailableException(_failureReason ?? reason);
    }
  }

  /// 单飞的半开恢复：并发调用共享同一次 `start`，不会重复执行脚本。
  Future<void> _runRecoveryAttempt() {
    final pending = _recoveryCompleter;
    if (pending != null) return pending.future;
    final completer = Completer<void>();
    _recoveryCompleter = completer;
    _attemptRecovery().whenComplete(() {
      if (identical(_recoveryCompleter, completer)) _recoveryCompleter = null;
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  /// 用 [_lastScript] 做一次半开恢复：成功 ready，失败回到 failed 并重置冷却。
  Future<void> _attemptRecovery() async {
    final script = _lastScript;
    if (script == null) return;
    if (_state == LxEngineState.ready ||
        _state == LxEngineState.starting ||
        _state == LxEngineState.restarting) {
      return; // 已有启动 / 重启在途：不叠加第二次 start
    }
    final generation = _recoveryGeneration;
    _setState(LxEngineState.starting);
    try {
      await _engine.start(script);
      if (_disposed || generation != _recoveryGeneration) return;
      _restartAttempts = 0;
      _consecutiveTimeouts = 0;
      _failureReason = null;
      _failedAt = null;
      // onStateChanged(ready) 会驱动 SourceManager 刷新 activeSources。
      _setState(LxEngineState.ready);
    } catch (e) {
      if (_disposed || generation != _recoveryGeneration) return;
      if (kDebugMode) debugPrint('[LxEngineSupervisor] 半开恢复失败: $e');
      // _fail 会重置 _failedAt：下一次冷却从这次失败重新计时。
      await _fail('音源引擎自动恢复失败，请稍后重试');
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
          // 状态机不变，只换错误类型：这两条路径都表示「请求还没被执行」，
          // 属于可恢复的暂时不可用（不同调用方会重试）。
          throw const LxEngineUnavailableException('音源引擎重启超时，请稍后重试');
        }
      }
      if (_state == LxEngineState.ready) return;
    }
    final reason = _state == LxEngineState.failed
        ? (_failureReason ?? '音源引擎已停止')
        : '音源引擎未运行';
    throw LxEngineUnavailableException(reason);
  }

  /// 检测到崩溃：进入 [LxEngineState.restarting] 并启动退避重启循环。
  void _handleCrash() {
    if (_disposed) return;
    if (_state == LxEngineState.restarting || _state == LxEngineState.failed) {
      return; // 已在重启/已停用：避免并发重复触发
    }
    final script = _lastScript;
    if (script == null) return; // 从未成功 start：无脚本可重放
    // 连续崩溃计数只在有成功请求后清零（见 _guard）；达到上限直接停用，
    // 避免“每次重启都成功、但脚本每次都崩溃”时无限循环 20s 超时。
    if (_restartAttempts >= _restartDelays.length) {
      unawaited(_fail('音源脚本连续重启 $_restartAttempts 次仍不可用，已停止自动重启'));
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
          debugPrint(
            '[LxEngineSupervisor] 自动重启失败'
            '($_restartAttempts/${_restartDelays.length}): $e',
          );
        }
        if (_restartAttempts >= _restartDelays.length) {
          await _fail('音源脚本连续重启 $_restartAttempts 次均失败，已停止自动重启');
          return;
        }
      }
    }
  }

  /// 进入 failed 终态：记录原因与失败时刻、取消重启、释放引擎。
  ///
  /// 释放 isolate 的原因：脚本已证明不可用（每次起来都慢 / 每次崩溃），
  /// 继续留着它只会白占内存与 CPU；冷却后的半开恢复 / 外部 `start` 会重新
  /// 执行脚本。`_lastScript` 保留，否则半开恢复无从重放。
  Future<void> _fail(String reason) async {
    if (_state == LxEngineState.failed || _disposed) return;
    _failureReason = reason;
    // 冷却从这次失败起算：_attemptRecovery 失败时由这里重置，避免连点
    // 「重试」在脚本确实坏掉时反复吃启动超时。
    _failedAt = DateTime.now();
    _cancelPendingRestart();
    _setState(LxEngineState.failed);
    if (kDebugMode) debugPrint('[LxEngineSupervisor] $reason');
    await _engine.dispose();
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

  /// 取消半开恢复的等待者（不中断在途 `start`，只让等待者醒来重新判定状态）。
  ///
  /// `dispose` / `close` / 外部 `start` 都要经过这里：否则等待者会一直挂在
  /// 一个再也不会推进的状态上，直到 ready 等待超时。
  void _cancelPendingRecovery() {
    _recoveryGeneration++;
    final pending = _recoveryCompleter;
    _recoveryCompleter = null;
    if (pending != null && !pending.isCompleted) pending.complete();
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
