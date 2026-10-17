import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/lx/lx_engine.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/lx/lx_script_info.dart';

/// 真实 QuickJS 引擎桥的回归测试（需要本机 quickjs_engine 原生库）。
///
/// 单独一个文件是刻意的：它跑真引擎（isolate + FFI + prelude），比集成测试快、
/// 比纯 Dart 单测真，覆盖「Dart↔JS 投递 / 任务泵 / invoke 超时 / 探活重启」这些
/// 只在真引擎上才成立的行为。原生库缺失时整组跳过：
///
///   LIBQUICKJSC_TEST_PATH=$PWD/build/linux/x64/debug/bundle/lib/libquickjs_c_bridge_plugin.so \
///     flutter test test/lx_engine_native_test.dart
///
/// （`build/linux/x64/debug/bundle/lib/` 由 `flutter build linux --debug` 或
/// `tool/agent/test.sh linux` 产出。）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final skip = _resolveNativeLib() == null
      ? '未找到 quickjs_engine 原生库（LIBQUICKJSC_TEST_PATH），跳过真引擎用例'
      : null;

  group('LxEngine · 真实 QuickJS', () {
    late HttpServer server;
    late int port;
    late LxEngine engine;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen(_handleRequest);
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    setUp(() {
      engine = LxEngine();
    });

    tearDown(() async {
      await engine.close();
    });

    test('start 声明源；lx.request 回原文 raw，body 由 prelude 还原', () async {
      final sources = await engine.start(_scriptInfo(_probeScript(port)));
      expect(sources.keys, contains('mock'));

      final logs = <String>[];
      engine.logs.listen((entry) => logs.add('${entry.level}:${entry.message}'));

      final data = await _probe(engine) as Map;
      expect(data['statusCode'], 200);
      // raw 必须是响应原文（换行、空格、键序原样）
      expect(data['raw'], _jsonBody);
      // body 是解析后的对象（脚本读 resp.body 与回调第三参数都拿到它）
      expect((data['body'] as Map)['url'], 'http://cdn.example.com/9.mp3');
      expect((data['third'] as Map)['url'], 'http://cdn.example.com/9.mp3');
      expect(data['sameObject'], isTrue, reason: '第三参数必须与 resp.body 同一对象');
      // 脚本声明的请求头原样到达服务端，响应头原样回给脚本
      expect(data['echoHeader'], 'molia-test');
      expect(data['headers'] as Map, contains('x-echo'));
      expect(logs, contains('log:probe probe'));
    }, skip: skip);

    test('非 JSON 响应：body 退化为原文', () async {
      await engine.start(_scriptInfo(_probeScript(port)));
      final data = await _probe(engine, action: 'text') as Map;
      expect(data['raw'], _textBody);
      expect(data['body'], _textBody);
    }, skip: skip);

    test('invoke 超时只失败该请求，不重启引擎', () async {
      await engine.start(_scriptInfo(_probeScript(port)));

      await expectLater(
        engine.search(
          source: 'mock',
          action: 'hang',
          keyword: 'x',
          timeout: const Duration(milliseconds: 400),
        ),
        throwsA(isA<LxEngineTimeoutException>()),
      );
      expect(engine.isRunning, isTrue, reason: '脚本没卡死，引擎不该被重启');

      // 后续请求照常执行：单个请求超时不得影响同一引擎的其他请求
      final data = await _probe(engine) as Map;
      expect((data['body'] as Map)['url'], 'http://cdn.example.com/9.mp3');
    }, skip: skip);

    test('invoke 预算随脚本声明的在途 HTTP 超时自适应延长', () async {
      await engine.start(_scriptInfo(_probeScript(port)));

      // 服务端延迟 900ms、脚本声明请求超时 3s：invoke 默认预算 300ms 会在
      // 探活后按脚本声明延长，请求最终成功而不是被判超时。
      final data = await engine.search(
        source: 'mock',
        action: 'slow',
        keyword: 'x',
        timeout: const Duration(milliseconds: 300),
      );
      expect(data, 'http://cdn.example.com/slow.mp3');
      expect(engine.isRunning, isTrue);

      // 延长只发生在有在途 HTTP 时：空闲后同一引擎的请求仍按默认预算走
      final probe = await _probe(engine) as Map;
      expect(probe['statusCode'], 200);
    }, skip: skip);

    test('大响应（约 1MB JSON）经 FFI 投递不撑爆 JS 堆', () async {
      await engine.start(_scriptInfo(_probeScript(port)));
      final data = await _probe(engine, action: 'big') as Map;
      expect(data['count'], 4000);
      expect(data['first'], 'name-0');
      expect(data['rawLength'], greaterThan(100000));
      expect(engine.isRunning, isTrue);
    }, skip: skip);

    test('Promise 微任务链与 setTimeout 回调都能推进到响应', () async {
      await engine.start(_scriptInfo(_probeScript(port)));

      // 纯微任务链：没有网络、没有定时器，只靠交付后的任务泵推进
      expect(await _probe(engine, action: 'micro'), 'micro-ok');
      // 定时器回调：由运行时的 Dart Timer 触发后，回调里排入的微任务要靠泵推进
      expect(await _probe(engine, action: 'timer'), 'timer-ok');
    }, skip: skip);

    test('脚本卡死事件循环：探活失败 → 引擎被重启', () async {
      await engine.start(_scriptInfo(_probeScript(port)));

      await expectLater(
        engine.search(
          source: 'mock',
          action: 'spin',
          keyword: 'x',
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<LxEngineException>().having(
          (e) => e.message,
          'message',
          contains('引擎无响应'),
        )),
      );
      expect(engine.isRunning, isFalse, reason: '死循环必须走重启路径');

      // 重新 start 后引擎可用（监督者据此自愈）
      final sources = await engine.start(_scriptInfo(_probeScript(port)));
      expect(sources.keys, contains('mock'));
      expect(engine.isRunning, isTrue);
    }, skip: skip);
  });
}

const _jsonBody =
    '{ "url": "http://cdn.example.com/9.mp3",\n "list": [1, 2, 3] }';
const _textBody = '<html>not json</html>';

/// 约 1MB 的 JSON（4000 条 × 约 250B），用来确认大 payload 走 FFI 投递不炸。
final String _bigBody = _buildBigBody();

String _buildBigBody() {
  final filler = 'x' * 200;
  final items = [
    for (var i = 0; i < 4000; i++)
      '{"name":"name-$i","id":"id-$i","description":"$filler"}',
  ];
  return '{"list":[${items.join(',')}]}';
}

/// 测试脚本：把 HTTP 桥的行为原样回报给宿主，另有 hang / spin / slow 探针。
String _probeScript(int port) => '''
const { EVENT_NAMES, request, on, send } = globalThis.lx
const base = 'http://127.0.0.1:$port'
const get = (url, options) => new Promise((resolve, reject) => {
  request(url, options, (err, resp, body) => {
    if (err) return reject(err)
    resolve({ resp: resp, body: body })
  })
})
on(EVENT_NAMES.request, ({ source, action, info }) => {
  console.log('probe ' + action)
  switch (action) {
    case 'probe':
      return get(base + '/json', { method: 'GET', headers: { 'x-molia': 'molia-test' } })
        .then(({ resp, body }) => ({
          statusCode: resp.statusCode,
          raw: resp.raw,
          body: resp.body,
          third: body,
          sameObject: resp.body === body,
          headers: resp.headers,
          echoHeader: resp.headers['x-echo'],
        }))
    case 'text':
      return get(base + '/text', { method: 'GET' }).then(({ resp, body }) => ({
        raw: resp.raw,
        body: resp.body,
      }))
    case 'big':
      return get(base + '/big', { method: 'GET' }).then(({ resp, body }) => ({
        count: body.list.length,
        first: body.list[0].name,
        rawLength: resp.raw.length,
      }))
    case 'slow':
      return get(base + '/slow', { method: 'GET', timeout: 3000 })
        .then(({ body }) => body.url)
    case 'hang':
      return new Promise(() => {})
    case 'micro':
      return Promise.resolve().then(() => Promise.resolve('micro-ok'))
    case 'timer':
      return new Promise((resolve) => { setTimeout(() => resolve('timer-ok'), 50) })
    case 'spin':
      {
        const t = Date.now()
        while (Date.now() - t < 3000) {}
        return 'never'
      }
    default:
      return Promise.reject(new Error('unknown action: ' + action))
  }
})
console.log('probe script ready')
send(EVENT_NAMES.inited, {
  sources: { mock: { name: 'Mock', type: 'music', actions: ['musicUrl', 'probe', 'text', 'big', 'slow', 'hang', 'spin', 'micro', 'timer'], qualitys: ['128k'] } },
})
''';

Future<dynamic> _probe(LxEngine engine, {String action = 'probe'}) =>
    engine.search(source: 'mock', action: action, keyword: 'x');

LxScriptInfo _scriptInfo(String script) => LxScriptInfo(
      id: 'mock-script',
      name: 'Mock 音源',
      description: '测试用',
      version: '1.0.0',
      author: 'test',
      homepage: '',
      script: script,
      importedAt: 0,
    );

Future<void> _handleRequest(HttpRequest request) async {
  final path = request.uri.path;
  if (path == '/slow') {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    _write(request, '{"url":"http://cdn.example.com/slow.mp3"}');
    return;
  }
  if (path == '/text') {
    _write(request, _textBody, contentType: 'text/html');
    return;
  }
  if (path == '/big') {
    _write(request, _bigBody);
    return;
  }
  _write(request, _jsonBody);
}

void _write(
  HttpRequest request,
  String body, {
  String contentType = 'application/json; charset=utf-8',
}) {
  final response = request.response
    ..statusCode = 200
    ..headers.contentType = ContentType.parse(contentType)
    ..headers.set('x-echo', request.headers.value('x-molia') ?? '')
    ..write(body);
  unawaited(response.close());
}

/// 复刻 quickjs_engine 的测试库解析：`flutter test` 下它只看
/// LIBQUICKJSC_TEST_PATH 与包内 native/build 目录。
/// 返回可加载的库路径；解析不到时整组跳过。
String? _resolveNativeLib() {
  if (Platform.isWindows || Platform.isMacOS) return null;
  final override = Platform.environment['LIBQUICKJSC_TEST_PATH'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return override;
  }
  const candidates = [
    'packages/quickjs_engine/native/build/libquickjs_c_bridge_plugin.so',
    '../packages/quickjs_engine/native/build/libquickjs_c_bridge_plugin.so',
    'native/build/libquickjs_c_bridge_plugin.so',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}
