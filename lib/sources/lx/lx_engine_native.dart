import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import '../../data/http/app_dio.dart';
import 'lx_engine_types.dart';
import 'lx_native_utils.dart';
import 'lx_script_info.dart';

/// JS 引擎堆内存上限（64 MiB）。
///
/// 音源脚本是不可信代码（docs/pitfalls.md #8），显式写明上限便于未来单独调参。
const int _jsMemoryLimit = 64 * 1024 * 1024;

/// JS 引擎栈上限（1 MiB，引擎默认值）。
const int _jsStackSize = 1024 * 1024;

/// 脚本单次 HTTP 请求允许声明的最长超时（`lx.request` 的 `timeout` 会被截断到此值）。
///
/// 它同时是 invoke 自适应预算的上界：脚本能等多久网络，宿主就该允许它等多久，
/// 否则「脚本还在等网络、宿主已经判超时」必然错配（见 [LxEngine._invoke]）。
const Duration _maxScriptHttpTimeout = Duration(seconds: 120);

/// 引擎探活（ping/pong）等待上限：超时即判定脚本把 isolate 卡死（死循环）。
///
/// 只在 invoke 超时后调用，不进入热路径；2s 足够让正常执行中的 JS 交出事件循环。
const Duration _probeTimeout = Duration(seconds: 2);

/// invoke 自适应延长的余量：脚本在途 HTTP 最长剩余时长之外再给一点结算时间。
const Duration _invokeExtendSlack = Duration(seconds: 5);

/// LX 音源 JS 引擎（原生平台实现）。
///
/// 在独立 isolate 中运行 QuickJS（quickjs_engine，QuickJS-NG），并通过其消息通道
/// 与 Dart 通信：
/// - JS -> Dart：`sendMessage('lx', JSON.stringify(...))`
/// - Dart -> JS：以 Dart 值直接调用 `__lxDeliver` / `__lxSetup`（JSInvokable）
///   与同步工具函数绑定
///
/// 独立 isolate 的好处：
/// - 不阻塞 UI 线程；
/// - 脚本把事件循环卡死（死循环）时，主 isolate 探活失败后 kill 掉它重新拉起。
class LxEngine {
  Isolate? _isolate;
  SendPort? _commandPort;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _subscription;
  ReceivePort? _isolateErrorPort;
  StreamSubscription<dynamic>? _isolateErrorSubscription;

  final Map<String, Completer<_LxResponse>> _pending = {};
  final Map<String, LxSourceDecl> _sources = {};
  final StreamController<LxLogEntry> _logController =
      StreamController<LxLogEntry>.broadcast();
  final StreamController<LxUpdateAlert> _alertController =
      StreamController<LxUpdateAlert>.broadcast();

  /// 等待 `pong` 的探活请求（key 为 ping id），见 [_probe]。
  final Map<int, Completer<_EngineHealth>> _pongWaiters = {};

  Completer<Map<String, LxSourceDecl>>? _readyCompleter;
  LxScriptInfo? _script;
  bool _dead = false;
  int _seq = 0;
  int _pingSeq = 0;

  Stream<LxLogEntry> get logs => _logController.stream;
  Stream<LxUpdateAlert> get updateAlerts => _alertController.stream;
  Map<String, LxSourceDecl> get sources => Map.unmodifiable(_sources);
  LxScriptInfo? get script => _script;
  bool get isRunning => !_dead && _isolate != null && _readyCompleter?.isCompleted == true;

  /// 启动引擎并运行脚本，等待脚本发送 `inited` 事件。
  Future<Map<String, LxSourceDecl>> start(
    LxScriptInfo script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await dispose();
    _dead = false;
    _script = script;
    _sources.clear();

    final prelude = await _loadPrelude();
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final readyCompleter = Completer<Map<String, LxSourceDecl>>();
    _readyCompleter = readyCompleter;

    _subscription = receivePort.listen(_onIsolateMessage);

    final isolateErrorPort = ReceivePort();
    _isolateErrorPort = isolateErrorPort;
    _isolateErrorSubscription = isolateErrorPort.listen((message) {
      if (kDebugMode) debugPrint('[LxEngine] isolate event: $message');
    });

    try {
      _isolate = await Isolate.spawn(
        _lxIsolateEntry,
        <dynamic>[
          receivePort.sendPort,
          <String, dynamic>{
            'prelude': prelude,
            'script': script.script,
            'info': {
              'name': script.name,
              'description': script.description,
              'version': script.version,
              'author': script.author,
              'homepage': script.homepage,
              'rawScript': script.script,
            },
          },
        ],
        debugName: 'lx-engine-${script.name}',
        onError: isolateErrorPort.sendPort,
        onExit: isolateErrorPort.sendPort,
        errorsAreFatal: true,
      );
    } catch (e) {
      _dead = true;
      throw LxEngineException('无法启动音源引擎: $e');
    }

    try {
      final sources = await readyCompleter.future.timeout(timeout);
      // 通道自检：确认主 isolate -> 引擎 isolate 的命令通道可用
      _commandPort?.send(const <String, dynamic>{'cmd': 'ping'});
      return sources;
    } on TimeoutException {
      await dispose();
      throw const LxEngineException('音源脚本初始化超时');
    } catch (e) {
      await dispose();
      if (e is LxEngineException) rethrow;
      throw LxEngineException('音源脚本初始化失败: $e');
    }
  }

  /// 获取音乐播放地址。
  Future<String> getMusicUrl({
    required String source,
    required Map<String, dynamic> musicInfo,
    required String quality,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final data = await _invoke(
      'musicUrl',
      source,
      {'type': quality, 'musicInfo': musicInfo},
      timeout: timeout,
    );
    if (data is! String || data.isEmpty) {
      throw const LxEngineException('音源未返回有效的播放地址');
    }
    return data;
  }

  /// 获取歌词（脚本 `lyric` action）。
  Future<LxLyricResult> getLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final data = await _invoke(
      'lyric',
      source,
      {'musicInfo': musicInfo},
      timeout: timeout,
    );
    if (data is! Map) {
      throw const LxEngineException('音源未返回歌词');
    }
    return LxLyricResult.fromJson(data);
  }

  /// 获取封面（脚本 `pic` action）。
  Future<String> getPic({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final data = await _invoke(
      'pic',
      source,
      {'musicInfo': musicInfo},
      timeout: timeout,
    );
    if (data is! String || data.isEmpty) {
      throw const LxEngineException('音源未返回封面地址');
    }
    return data;
  }

  /// 调用脚本扩展搜索（`search` / `musicSearch`，非 LX 官方 action）。
  Future<dynamic> search({
    required String source,
    required String action,
    required String keyword,
    int page = 1,
    int limit = 20,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _invoke(
      action,
      source,
      {
        'keyword': keyword,
        'page': page,
        'limit': limit,
        'pagesize': limit,
      },
      timeout: timeout,
    );
  }

  Future<dynamic> _invoke(
    String action,
    String source,
    Map<String, dynamic> info, {
    required Duration timeout,
  }) async {
    if (_dead || _commandPort == null) {
      throw const LxEngineException('音源引擎未运行');
    }
    final reqId = 'req_${++_seq}';
    final completer = Completer<_LxResponse>();
    _pending[reqId] = completer;
    if (kDebugMode) debugPrint('[LxEngine] invoke $action @$source req=$reqId');
    _commandPort!.send(<String, dynamic>{
      'cmd': 'invoke',
      'reqId': reqId,
      'payload': {'source': source, 'action': action, 'info': info},
    });

    // 超时只让「这一个请求」失败，不杀引擎、不连坐其他在途请求：
    // - 脚本还在等网络（isolate 探活有应答 + 有在途 HTTP）→ 按它自己声明的
    //   HTTP 超时延长预算（`timeout + _maxScriptHttpTimeout` 封顶）；
    // - 脚本把事件循环卡死（探活无应答，如死循环）→ 才重启引擎。
    var limit = timeout;
    var waited = Duration.zero;
    final budget = timeout + _maxScriptHttpTimeout;
    while (true) {
      try {
        final response = await completer.future.timeout(limit);
        if (!response.ok) {
          throw LxEngineException(response.error ?? '未知错误');
        }
        return response.data;
      } on TimeoutException {
        waited += limit;
        final health = await _probe();
        if (!health.alive) {
          _pending.remove(reqId);
          await dispose();
          throw LxEngineException(
              '音源请求超时（${timeout.inSeconds}s），引擎无响应已重启');
        }
        if (health.inflightHttp > 0 &&
            health.httpRemaining > Duration.zero &&
            waited < budget) {
          limit = health.httpRemaining + _invokeExtendSlack;
          if (waited + limit > budget) limit = budget - waited;
          continue;
        }
        _pending.remove(reqId);
        _abandon(reqId);
        throw LxEngineTimeoutException('音源请求超时（${timeout.inSeconds}s）');
      }
    }
  }

  /// 探活：ping 由 isolate 内的 host 在事件循环空闲时回 pong。
  ///
  /// 脚本死循环时 isolate 一直卡在 QuickJS 的 FFI 调用里，命令通道不会被处理，
  /// 探活即失败；顺带回传 isolate 侧的网络活动（在途 HTTP 数与最长剩余超时），
  /// 供 [_invoke] 决定「继续等」还是「判超时」。
  Future<_EngineHealth> _probe() async {
    final port = _commandPort;
    if (_dead || port == null) return const _EngineHealth.dead();
    final id = ++_pingSeq;
    final completer = Completer<_EngineHealth>();
    _pongWaiters[id] = completer;
    try {
      port.send(<String, dynamic>{'cmd': 'ping', 'id': id});
      return await completer.future.timeout(_probeTimeout);
    } on TimeoutException {
      return const _EngineHealth.dead();
    } finally {
      _pongWaiters.remove(id);
    }
  }

  /// 通知 isolate：该请求已放弃（脚本可能永远不回响应），别为它维持快泵。
  void _abandon(String reqId) {
    try {
      _commandPort?.send(<String, dynamic>{'cmd': 'abandon', 'reqId': reqId});
    } catch (_) {}
  }

  void _onIsolateMessage(dynamic message) {
    if (message is! Map) return;
    final type = message['type'];
    switch (type) {
      case 'port':
        _commandPort = message['port'] as SendPort;
        if (kDebugMode) debugPrint('[LxEngine] command port received');
        break;
      case 'ready':
        final rawSources = message['sources'];
        _sources.clear();
        if (rawSources is Map) {
          for (final entry in rawSources.entries) {
            final key = entry.key.toString();
            _sources[key] = LxSourceDecl.fromJson(key, entry.value);
          }
        }
        final completer = _readyCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete(Map<String, LxSourceDecl>.from(_sources));
        }
        break;
      case 'initFailed':
        _dead = true;
        final completer = _readyCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            LxEngineException(message['error']?.toString() ?? '脚本初始化失败'),
          );
        }
        break;
      case 'response':
        final reqId = message['reqId']?.toString();
        if (kDebugMode) {
          debugPrint(
              '[LxEngine] response $reqId ok=${message['ok']} error=${message['error']}');
        }
        final completer = reqId == null ? null : _pending.remove(reqId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(_LxResponse(
            ok: message['ok'] == true,
            data: message['data'],
            error: message['error']?.toString(),
          ));
        }
        break;
      case 'pong':
        final waiter = _pongWaiters.remove(message['id']);
        if (waiter != null && !waiter.isCompleted) {
          final remainingMs =
              (message['httpRemainingMs'] as num?)?.toInt() ?? 0;
          waiter.complete(_EngineHealth(
            alive: true,
            inflightHttp: (message['inflightHttp'] as num?)?.toInt() ?? 0,
            httpRemaining: Duration(milliseconds: remainingMs.clamp(0, 1 << 31)),
          ));
        }
        break;
      case 'log':
        if (!_logController.isClosed) {
          _logController.add(LxLogEntry(
            message['level']?.toString() ?? 'log',
            message['message']?.toString() ?? '',
          ));
        }
        break;
      case 'updateAlert':
        if (!_alertController.isClosed) {
          _alertController.add(LxUpdateAlert(
            log: message['log']?.toString() ?? '',
            updateUrl: message['updateUrl']?.toString(),
          ));
        }
        break;
    }
  }

  Future<void> dispose() async {
    _dead = true;
    final port = _commandPort;
    if (port != null) {
      try {
        port.send(const <String, dynamic>{'cmd': 'dispose'});
      } catch (_) {}
    }
    await _subscription?.cancel();
    _subscription = null;
    await _isolateErrorSubscription?.cancel();
    _isolateErrorSubscription = null;
    _isolateErrorPort?.close();
    _isolateErrorPort = null;
    _receivePort?.close();
    _receivePort = null;
    _commandPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    for (final waiter in _pongWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(const _EngineHealth.dead());
    }
    _pongWaiters.clear();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const LxEngineException('音源引擎已关闭'));
      }
    }
    _pending.clear();
  }

  Future<void> close() async {
    await dispose();
    await _logController.close();
    await _alertController.close();
  }

  Future<String> _loadPrelude() async {
    try {
      return await rootBundle.loadString('assets/lx/lx_prelude.js');
    } catch (e) {
      throw LxEngineException('加载音源运行时失败: $e');
    }
  }
}

class _LxResponse {
  final bool ok;
  final dynamic data;
  final String? error;

  const _LxResponse({required this.ok, this.data, this.error});
}

/// 引擎探活结果（见 [LxEngine._probe]）。
class _EngineHealth {
  /// isolate 是否在 [_probeTimeout] 内响应了 pong。
  final bool alive;

  /// 引擎内在途的脚本 HTTP 请求数。
  final int inflightHttp;

  /// 在途请求中距离各自声明的超时还剩的最长时间（已按 0 截断）。
  final Duration httpRemaining;

  const _EngineHealth({
    required this.alive,
    this.inflightHttp = 0,
    this.httpRemaining = Duration.zero,
  });

  const _EngineHealth.dead()
      : alive = false,
        inflightHttp = 0,
        httpRemaining = Duration.zero;
}

void _lxIsolateEntry(List<dynamic> args) {
  final mainPort = args[0] as SendPort;
  final config = Map<String, dynamic>.from(args[1] as Map);
  _LxIsolateHost(mainPort, config).run();
}

class _LxIsolateHost {
  /// 任务泵的快/慢频率。
  ///
  /// QuickJS 只暴露「执行全部待处理 job」，不暴露「还有没有 job」，所以用活动
  /// 状态近似事件驱动：有 invoke / HTTP 在途时 25ms（脚本 Promise 链要尽快推进），
  /// 空闲降到 250ms（脚本自发的 setInterval 轮询仍会被推进，但不再每秒唤醒 40 次）。
  static const Duration _fastPump = Duration(milliseconds: 25);
  static const Duration _idlePump = Duration(milliseconds: 250);

  final SendPort _mainPort;
  final String _prelude;
  final String _script;
  final Map<String, dynamic> _info;

  JavascriptRuntime? _runtime;
  ReceivePort? _commandPort;
  Timer? _pumpTimer;
  Duration _pumpInterval = _fastPump;
  bool _ready = false;
  bool _initFailed = false;

  /// Dart -> JS 的两个入口函数引用（见 [_deliver] 与 [_initRuntime]）。
  JSInvokable? _deliverFn;
  JSInvokable? _setupFn;

  /// 每请求一个取消令牌：脚本侧 `httpCancel` 直接取消对应的那一个请求。
  final Map<String, CancelToken> _cancelTokens = {};

  /// 在途脚本 HTTP 请求的截止时间（探活时回报给主 isolate，用于自适应 invoke 预算）。
  final Map<String, DateTime> _httpDeadlines = {};

  /// isolate 内尚未回响应的 invoke（reqId 集合，idempotent 增删）。
  final Set<dynamic> _invokeInFlight = {};

  /// 本 isolate 共用的 HTTP 客户端（音源脚本的网络请求都经 [lx.request] 走这里）。
  final Dio _dio = createAppDio();

  _LxIsolateHost(this._mainPort, Map<String, dynamic> config)
      : _prelude = config['prelude'] as String,
        _script = config['script'] as String,
        _info = Map<String, dynamic>.from(config['info'] as Map);

  void run() {
    final commandPort = ReceivePort();
    _commandPort = commandPort;
    _mainPort.send(<String, dynamic>{'type': 'port', 'port': commandPort.sendPort});
    commandPort.listen(_onCommand);
    _initRuntime();
  }

  void _initRuntime() {
    try {
      // 运行时默认只装 core Web API（无内置 fetch/XHR），音源脚本的网络请求
      // 统一走我们自己的 lx.request 桥接（见 docs/pitfalls.md #2）。
      // 不用 quickjs_engine 的 getJavascriptRuntime()：它固定装内置 fetch 与
      // handlePromises 的 JS 辅助函数，这里两样都不需要（Promise 由任务泵推进），
      // 直接建 runtime 少装一段无人调用的 JS。
      // 堆上限显式传入：脚本是不可信代码，靠内存上限兜底失控分配；
      // timeout 不设——运行时是长生命周期会话，全局超时会误伤正常长任务，
      // 单次请求超时由 Dart 侧 _invoke 控制，死循环由探活 + kill isolate 兜底。
      final runtime = QuickJsRuntime2(
        stackSize: _jsStackSize,
        memoryLimit: _jsMemoryLimit,
      );
      _runtime = runtime;

      // 先注册消息通道，避免脚本初始化阶段的 inited 事件丢失
      runtime.onMessage('lx', _onJsMessage);

      final preludeResult = runtime.evaluate(_prelude, sourceUrl: 'lx_prelude.js');
      if (preludeResult.isError) {
        _failInit('音源运行时加载失败: ${preludeResult.stringResult}');
        return;
      }
      // 取到消息入口的 JS 函数引用：之后所有 Dart -> JS 投递都以 Dart 值直接
      // 调用（FFI 值转换），不再拼接 JS 源码再 evaluate —— 省掉「jsonEncode →
      // QuickJS 编译大字符串 → JS 解析」三段开销，也不再让大 payload 在
      // JS 堆里以「源码 + 对象」两份形态驻留（堆上限 64MiB）。
      final deliverFn = runtime.evaluate('__lxDeliver');
      final setupFn = runtime.evaluate('__lxSetup');
      if (deliverFn.isError ||
          setupFn.isError ||
          deliverFn.rawResult is! JSInvokable ||
          setupFn.rawResult is! JSInvokable) {
        _failInit('音源运行时缺少消息入口: ${deliverFn.stringResult}');
        return;
      }
      _deliverFn = deliverFn.rawResult as JSInvokable;
      _setupFn = setupFn.rawResult as JSInvokable;

      _bindNativeFunctions(runtime);
      final setupError = _invokeJs(_setupFn!, _jsonSafe(_info), 'lxSetup');
      if (setupError != null) {
        _failInit('音源运行时初始化失败: $setupError');
        return;
      }

      final result = runtime.evaluate(_script, sourceUrl: 'lx_source.js');
      if (result.isError) {
        _failInit(result.stringResult);
        return;
      }

      // 任务泵：具体频率随活动状态切换，见 _fastPump/_idlePump
      _schedulePump();
      _pumpJobs();
      _log('debug', 'runtime init done');

      // 脚本可能同步发送 inited（_onJsMessage 会处理）
      if (!_ready && !_initFailed) {
        // 等待 inited；若长时间未发送，主侧会超时处理
      }
    } catch (e) {
      _failInit(e.toString());
    }
  }

  void _bindNativeFunctions(JavascriptRuntime runtime) {
    try {
      final setterResult =
          runtime.evaluate('(function(key, val){ globalThis[key] = val; })');
      if (setterResult.isError) return;
      final setter = setterResult.rawResult as JSInvokable;

      void bind(String name, Function fn) {
        setter.invoke([name, fn]);
      }

      bind('__lxMd5', (String input) => LxNativeUtils.md5(input));
      bind(
        '__lxAesEncrypt',
        (Uint8List buffer, String mode, dynamic key, dynamic iv) =>
            LxNativeUtils.aesEncrypt(buffer, mode, key, iv),
      );
      bind(
        '__lxRsaEncrypt',
        (Uint8List buffer, String key) =>
            LxNativeUtils.rsaEncrypt(buffer, key),
      );
      bind('__lxRandomBytes', (int size) => LxNativeUtils.randomBytes(size));
      bind('__lxZlibInflate', (Uint8List data) => LxNativeUtils.zlibInflate(data));
      bind('__lxZlibDeflate', (Uint8List data) => LxNativeUtils.zlibDeflate(data));
    } catch (e) {
      _log('warn', '绑定原生工具函数失败: $e');
    }
  }

  void _pumpJobs() {
    try {
      _runtime?.executePendingJob();
    } catch (_) {
      // 忽略任务泵送错误
    }
  }

  /// 是否有在途工作（invoke 未回响应 / HTTP 未结束）：决定任务泵频率。
  bool get _busy => _invokeInFlight.isNotEmpty || _httpDeadlines.isNotEmpty;

  void _schedulePump() {
    _pumpTimer?.cancel();
    _pumpTimer = Timer.periodic(_pumpInterval, (_) => _pumpJobs());
  }

  /// 活动状态变化时切换泵频率（频率没变就不动计时器）。
  void _syncPumpInterval() {
    final next = _busy ? _fastPump : _idlePump;
    if (next == _pumpInterval) return;
    _pumpInterval = next;
    _schedulePump();
  }

  /// 以 Dart 值直接调用 JS 入口函数；返回 null 表示成功，否则为错误描述。
  ///
  /// 值经 [_jsonSafe] 归一（Map/List/String/num/bool/null → FFI 直接转换，
  /// 其他对象退化为字符串），脚本侧能表达的集合与消息协议（JSON 值）一致。
  String? _invokeJs(JSInvokable fn, dynamic value, String what) {
    try {
      fn.invoke([value]);
      return null;
    } catch (e) {
      final error = '$what failed: $e';
      _log('error', error);
      return error;
    }
  }

  void _onCommand(dynamic message) {
    if (message is! Map) return;
    switch (message['cmd']) {
      case 'invoke':
        final reqId = message['reqId'];
        if (kDebugMode) _log('debug', 'isolate invoke req=$reqId');
        _invokeInFlight.add(reqId);
        _syncPumpInterval();
        _deliver(<String, dynamic>{
          'type': 'invoke',
          'reqId': reqId,
          'payload': message['payload'],
        });
        break;
      case 'abandon':
        // 主 isolate 已判该请求超时：停止为它维持快泵（脚本若稍后回响应，
        // _onJsMessage 的 remove 是幂等的）。
        _invokeInFlight.remove(message['reqId']);
        _syncPumpInterval();
        break;
      case 'ping':
        final id = message['id'];
        if (id == null) {
          if (kDebugMode) _log('debug', 'pong from isolate');
          break;
        }
        // 探活应答：事件循环空闲才会走到这里（脚本被卡住时主侧收不到）。
        // 顺带回报网络活动，供主侧决定 invoke 是「继续等」还是「判超时」。
        _mainPort.send(<String, dynamic>{
          'type': 'pong',
          'id': id,
          'inflightHttp': _httpDeadlines.length,
          'httpRemainingMs': _longestHttpRemaining().inMilliseconds,
        });
        break;
      case 'dispose':
        _shutdown();
        break;
    }
  }

  /// 在途 HTTP 请求里距离各自声明的超时还剩的最长时间。
  Duration _longestHttpRemaining() {
    if (_httpDeadlines.isEmpty) return Duration.zero;
    final now = DateTime.now();
    var longest = Duration.zero;
    for (final deadline in _httpDeadlines.values) {
      final remaining = deadline.difference(now);
      if (remaining > longest) longest = remaining;
    }
    return longest;
  }

  void _onJsMessage(dynamic message) {
    if (message is! Map) return;
    final type = message['type']?.toString();
    final data = message['data'];
    if (type != 'log' && kDebugMode) {
      _log('debug', 'jsMsg type=$type');
    }
    switch (type) {
      case 'inited':
        if (_initFailed) return;
        if (!_ready) {
          _ready = true;
          final sources = (data is Map && data['sources'] is Map)
              ? data['sources'] as Map
              : const <String, dynamic>{};
          _mainPort.send(<String, dynamic>{
            'type': 'ready',
            'sources': jsonDecode(jsonEncode(sources)),
          });
        }
        break;
      case 'response':
        if (data is Map) {
          _invokeInFlight.remove(data['reqId']);
          _syncPumpInterval();
          // data 直接来自 sendMessage 的 jsonDecode，已是可跨 isolate 传递的
          // JSON 值，不再做一遍 _jsonSafe 深拷贝（搜索结果可能是大数组）。
          _mainPort.send(<String, dynamic>{
            'type': 'response',
            'reqId': data['reqId'],
            'ok': data['ok'] == true,
            'data': data['data'],
            'error': data['error'],
          });
        }
        break;
      case 'http':
        if (data is Map) _handleHttp(Map<String, dynamic>.from(data));
        break;
      case 'httpCancel':
        if (data is Map) {
          final reqId = data['reqId']?.toString();
          if (reqId != null) _cancelTokens.remove(reqId)?.cancel();
        }
        break;
      case 'log':
        if (data is Map) {
          _mainPort.send(<String, dynamic>{
            'type': 'log',
            'level': data['level']?.toString() ?? 'log',
            'message': data['message']?.toString() ?? '',
          });
        }
        break;
      case 'updateAlert':
        if (data is Map) {
          _mainPort.send(<String, dynamic>{
            'type': 'updateAlert',
            'log': data['log']?.toString() ?? '',
            'updateUrl': data['updateUrl']?.toString(),
          });
        }
        break;
    }
  }

  Future<void> _handleHttp(Map<String, dynamic> data) async {
    final reqId = data['reqId']?.toString();
    if (reqId == null) return;
    final url = data['url']?.toString() ?? '';
    final timeoutMs = data['timeout'] is num
        ? (data['timeout'] as num).toInt()
        : 30000;
    // 脚本声明的超时截断到 _maxScriptHttpTimeout：它同时是 invoke 自适应预算的
    // 依据，脚本不能通过声明一个天文数字的超时把宿主预算撑爆（见 LxEngine._invoke）。
    final timeout = Duration(
      milliseconds: timeoutMs.clamp(1, _maxScriptHttpTimeout.inMilliseconds),
    );
    final cancelToken = CancelToken();
    _cancelTokens[reqId] = cancelToken;
    _httpDeadlines[reqId] = DateTime.now().add(timeout);
    _syncPumpInterval();

    try {
      final headers = <String, String>{};
      final rawHeaders = data['headers'];
      if (rawHeaders is Map) {
        for (final entry in rawHeaders.entries) {
          headers[entry.key.toString()] = entry.value.toString();
        }
      }

      Object? body = data['body'];
      final form = data['form'];
      final formData = data['formData'];
      if (form is Map || formData is Map) {
        final fields = (form is Map ? form : formData) as Map;
        body = fields.entries
            .map((e) =>
                '${Uri.encodeQueryComponent(e.key.toString())}=${Uri.encodeQueryComponent(e.value.toString())}')
            .join('&');
        headers.putIfAbsent(
          'Content-Type',
          () => 'application/x-www-form-urlencoded',
        );
      } else if (body != null && body is! String) {
        headers.putIfAbsent('Content-Type', () => 'application/json');
        body = jsonEncode(body);
      }

      final response = await _dio
          .requestUri<dynamic>(
            Uri.parse(url),
            data: body,
            cancelToken: cancelToken,
            options: Options(
              method: (data['method']?.toString() ?? 'GET').toUpperCase(),
              headers: headers,
              responseType: ResponseType.stream,
            ),
          )
          .timeout(timeout);
      final raw = utf8.decode(
        await _collectBodyBytes(streamBody(response).stream),
        allowMalformed: true,
      );

      // 只回原文（raw）：body 由 prelude 在 JS 侧 JSON.parse 还原。
      // 宿主侧同时回原文 + 解析好的 body 会让同一份数据走两遍
      // 「解码 → 编码 → 解析」，且两份都驻留 JS 堆（上限 64MiB）。
      // 脚本读 resp.raw / resp.body / 回调第三参数的行为不变（见 lx_prelude.js）。
      _deliver(<String, dynamic>{
        'type': 'httpResult',
        'reqId': reqId,
        'error': null,
        'response': {
          'statusCode': response.statusCode,
          'statusMessage': response.statusMessage ?? '',
          'headers': flatResponseHeaders(response),
        },
        'raw': raw,
      });
    } on TimeoutException {
      // 真正掐断底层连接：否则请求会在后台继续跑完再被丢弃，白占带宽与连接池。
      cancelToken.cancel('request timeout');
      _deliver(<String, dynamic>{
        'type': 'httpResult',
        'reqId': reqId,
        'error': 'request timeout',
      });
    } catch (e) {
      _deliver(<String, dynamic>{
        'type': 'httpResult',
        'reqId': reqId,
        'error': e.toString(),
      });
    } finally {
      _cancelTokens.remove(reqId);
      _httpDeadlines.remove(reqId);
      _syncPumpInterval();
    }
  }

  static Future<Uint8List> _collectBodyBytes(Stream<Uint8List> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  void _deliver(Map<String, dynamic> message) {
    final deliverFn = _deliverFn;
    if (_runtime == null || deliverFn == null) return;
    _invokeJs(deliverFn, _jsonSafe(message), 'lxDeliver');
    _pumpJobs();
  }

  void _failInit(String error) {
    if (_initFailed) return;
    _initFailed = true;
    _mainPort.send(<String, dynamic>{'type': 'initFailed', 'error': error});
    _shutdown();
  }

  void _log(String level, String message) {
    // debug 级日志只服务本地排查：release 下不再为它们付 isolate 消息开销
    // （这些日志覆盖每条 invoke / 每条 JS 消息）。
    if (level == 'debug' && !kDebugMode) return;
    _mainPort.send(<String, dynamic>{
      'type': 'log',
      'level': level,
      'message': message,
    });
  }

  void _shutdown() {
    _pumpTimer?.cancel();
    _pumpTimer = null;
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _httpDeadlines.clear();
    _invokeInFlight.clear();
    try {
      _runtime?.dispose();
    } catch (_) {}
    _runtime = null;
    _deliverFn = null;
    _setupFn = null;
    // Dio 持有连接池与定时器，不关会随 isolate 一起泄漏到进程退出
    try {
      _dio.close(force: true);
    } catch (_) {}
    _commandPort?.close();
    _commandPort = null;
    // 由主 isolate 调用 kill 终止本 isolate
  }
}

/// 归一化为「FFI 值转换可表达」的 JSON 值。
///
/// Map 键统一转字符串、未知对象退化为 `toString()`：保证消息里只有 FFI 值转换
/// 认识的字面量类型（脚本据此读 `musicInfo` / `payload` 字段）。
dynamic _jsonSafe(dynamic value) {
  if (value == null) return null;
  if (value is num || value is bool || value is String) return value;
  if (value is List) {
    return value.map(_jsonSafe).toList(growable: false);
  }
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      result[entry.key.toString()] = _jsonSafe(entry.value);
    }
    return result;
  }
  return value.toString();
}
