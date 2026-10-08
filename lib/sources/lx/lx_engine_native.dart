import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import 'lx_engine_types.dart';
import 'lx_native_utils.dart';
import 'lx_script_info.dart';

/// LX 音源 JS 引擎（原生平台实现）。
///
/// 在独立 isolate 中运行 QuickJS / JavaScriptCore，并通过 flutter_js 的消息通道
/// 与 Dart 通信：
/// - JS -> Dart：`sendMessage('lx', JSON.stringify(...))`
/// - Dart -> JS：`__lxDeliver(...)` / 同步工具函数绑定
///
/// 独立 isolate 的好处：
/// - 不阻塞 UI 线程；
/// - 脚本出现死循环时可以直接 kill isolate 恢复。
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

  Completer<Map<String, LxSourceDecl>>? _readyCompleter;
  LxScriptInfo? _script;
  bool _dead = false;
  int _seq = 0;

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
    try {
      final response = await completer.future.timeout(timeout);
      if (!response.ok) {
        throw LxEngineException(response.error ?? '未知错误');
      }
      return response.data;
    } on TimeoutException {
      _pending.remove(reqId);
      // 可能是脚本死循环，直接重启引擎恢复
      await dispose();
      throw LxEngineException('音源请求超时（${timeout.inSeconds}s），引擎已重启');
    }
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

// Isolate 内部实现

void _lxIsolateEntry(List<dynamic> args) {
  final mainPort = args[0] as SendPort;
  final config = Map<String, dynamic>.from(args[1] as Map);
  _LxIsolateHost(mainPort, config).run();
}

class _LxIsolateHost {
  final SendPort _mainPort;
  final String _prelude;
  final String _script;
  final Map<String, dynamic> _info;

  JavascriptRuntime? _runtime;
  ReceivePort? _commandPort;
  Timer? _pumpTimer;
  bool _ready = false;
  bool _initFailed = false;

  final Map<String, http.Client> _httpClients = {};

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
      // 注意：必须关闭 flutter_js 的内置 fetch（xhr: false）。
      // enableFetch() 会在后台 isolate 中调用 rootBundle.loadString，
      // 而 rootBundle 依赖平台通道，会在 isolate 中产生未处理异常并杀掉 isolate。
      // LX 脚本的网络请求统一走我们自己的 lx.request 桥接。
      final runtime = getJavascriptRuntime(xhr: false);
      _runtime = runtime;

      // 先注册消息通道，避免脚本初始化阶段的 inited 事件丢失
      runtime.onMessage('lx', _onJsMessage);

      final preludeResult = runtime.evaluate(_prelude, sourceUrl: 'lx_prelude.js');
      if (preludeResult.isError) {
        _failInit('音源运行时加载失败: ${preludeResult.stringResult}');
        return;
      }
      _bindNativeFunctions(runtime);
      final setupResult = runtime.evaluate(
        '__lxSetup(${_jsonToJs(_info)})',
        sourceUrl: 'lx_setup.js',
      );
      if (setupResult.isError) {
        _failInit('音源运行时初始化失败: ${setupResult.stringResult}');
        return;
      }

      final result = runtime.evaluate(_script, sourceUrl: 'lx_source.js');
      if (result.isError) {
        _failInit(result.stringResult);
        return;
      }

      // 周期性执行 QuickJS 微任务，推进脚本 Promise 链
      var firstTick = true;
      _pumpTimer = Timer.periodic(
        const Duration(milliseconds: 25),
        (_) {
          if (firstTick) {
            firstTick = false;
            _log('debug', 'pump tick');
          }
          _pumpJobs();
        },
      );
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

  void _onCommand(dynamic message) {
    if (message is! Map) return;
    switch (message['cmd']) {
      case 'invoke':
        final reqId = message['reqId'];
        final payload = message['payload'];
        _log('debug', 'isolate invoke req=$reqId');
        _deliver(<String, dynamic>{
          'type': 'invoke',
          'reqId': reqId,
          'payload': payload,
        });
        break;
      case 'ping':
        _log('debug', 'pong from isolate');
        break;
      case 'dispose':
        _shutdown();
        break;
    }
  }

  void _onJsMessage(dynamic message) {
    if (message is! Map) return;
    final type = message['type']?.toString();
    final data = message['data'];
    if (type != 'log') {
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
          _mainPort.send(<String, dynamic>{
            'type': 'response',
            'reqId': data['reqId'],
            'ok': data['ok'] == true,
            'data': _jsonSafe(data['data']),
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
          final client = reqId == null ? null : _httpClients.remove(reqId);
          client?.close();
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
    final timeout = Duration(
      milliseconds: timeoutMs.clamp(1, 120000),
    );
    final client = http.Client();
    _httpClients[reqId] = client;

    try {
      final request = http.Request(
        (data['method']?.toString() ?? 'GET').toUpperCase(),
        Uri.parse(url),
      );

      final headers = data['headers'];
      if (headers is Map) {
        for (final entry in headers.entries) {
          request.headers[entry.key.toString()] = entry.value.toString();
        }
      }

      final body = data['body'];
      final form = data['form'];
      final formData = data['formData'];
      if (form is Map || formData is Map) {
        final fields = (form is Map ? form : formData) as Map;
        request.body = fields.entries
            .map((e) =>
                '${Uri.encodeQueryComponent(e.key.toString())}=${Uri.encodeQueryComponent(e.value.toString())}')
            .join('&');
        request.headers.putIfAbsent(
          'Content-Type',
          () => 'application/x-www-form-urlencoded',
        );
      } else if (body != null) {
        if (body is String) {
          request.body = body;
        } else {
          if (!request.headers.containsKey('Content-Type')) {
            request.headers['Content-Type'] = 'application/json';
          }
          request.body = jsonEncode(body);
        }
      }

      final response = await client.send(request).timeout(timeout);
      final bytes = await response.stream.toBytes();
      final raw = utf8.decode(bytes, allowMalformed: true);
      dynamic parsed = raw;
      if (raw.trim().isNotEmpty) {
        try {
          parsed = jsonDecode(raw);
        } catch (_) {
          // 保留原始文本
        }
      }

      _deliver(<String, dynamic>{
        'type': 'httpResult',
        'reqId': reqId,
        'error': null,
        'response': {
          'statusCode': response.statusCode,
          'statusMessage': response.reasonPhrase ?? '',
          'headers': response.headers,
        },
        'raw': raw,
        'body': _jsonSafe(parsed),
      });
    } on TimeoutException {
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
      _httpClients.remove(reqId);
      client.close();
    }
  }

  void _deliver(Map<String, dynamic> message) {
    final runtime = _runtime;
    if (runtime == null) return;
    try {
      final result = runtime.evaluate(
        '__lxDeliver(${_jsonToJs(message)})',
        sourceUrl: 'lx_deliver.js',
      );
      if (result.isError) {
        _log('error', 'deliver failed: ${result.stringResult}');
      }
    } catch (e) {
      _log('error', '执行音源脚本失败: $e');
    }
    _pumpJobs();
  }

  void _failInit(String error) {
    if (_initFailed) return;
    _initFailed = true;
    _mainPort.send(<String, dynamic>{'type': 'initFailed', 'error': error});
    _shutdown();
  }

  void _log(String level, String message) {
    _mainPort.send(<String, dynamic>{
      'type': 'log',
      'level': level,
      'message': message,
    });
  }

  void _shutdown() {
    _pumpTimer?.cancel();
    _pumpTimer = null;
    for (final client in _httpClients.values) {
      client.close();
    }
    _httpClients.clear();
    try {
      _runtime?.dispose();
    } catch (_) {}
    _runtime = null;
    _commandPort?.close();
    _commandPort = null;
    // 由主 isolate 调用 kill 终止本 isolate
  }
}

/// 将 JSON 字符串转为可安全嵌入 JS 源码的文本。
String _jsonToJs(dynamic value) {
  return jsonEncode(_jsonSafe(value))
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
}

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
