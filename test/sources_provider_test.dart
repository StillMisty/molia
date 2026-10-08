import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/domain/models/source_script.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/lx/lx_engine.dart';
import 'package:molia/sources/lx/lx_engine_supervisor.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/sources/source_track.dart' show kLxQualityOrder;

/// SourcesProvider 委托回归：导入 / 激活 / 排序 / 音质 / 在线更新全部经由
/// fake 引擎 + 本地 mock HTTP 服务验证，不依赖真实 quickjs 桥接。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestScriptServer server;
  HttpOverrides? savedOverrides;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // flutter_test 默认把 HttpClient 请求短路为 400；恢复真实网络以访问
    // 127.0.0.1 的本地 mock HttpServer（与 lx_script_update_test 一致）。
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    server = _TestScriptServer();
    await server.start();
  });

  tearDown(() async {
    await server.close();
    HttpOverrides.global = savedOverrides;
  });

  Future<_Fixture> fixture({Map<String, LxSourceDecl>? sources}) async {
    final engine = _FakeLxEngine()
      ..nextSources = sources ??
          {
            'test': const LxSourceDecl(
              key: 'test',
              name: '测试源',
              actions: ['musicUrl', 'search'],
              qualitys: ['128k', '320k'],
            ),
          };
    final supervisor = LxEngineSupervisor(
      engineFactory: () => engine,
      restartDelays: const [Duration(milliseconds: 10)],
    );
    final manager = SourceManager(engine: supervisor);
    await manager.init();
    final provider = SourcesProvider(manager);
    addTearDown(provider.dispose);
    addTearDown(manager.dispose);
    addTearDown(supervisor.close);
    return _Fixture(provider, manager);
  }

  test('导入并激活：scripts / activeScript / activeSourceEntries 领域转换', () async {
    final f = await fixture();
    final info = await f.provider.importScript(_script(), activate: true);

    expect(info.name, 'provider 测试音源');
    expect(f.provider.scripts, hasLength(1));
    expect(f.provider.activeScriptId, info.id);
    expect(f.provider.activeScript?.name, 'provider 测试音源');
    expect(f.provider.activeScript?.sources.keys, contains('test'));
    expect(f.provider.hasActiveSource, isTrue);

    expect(f.provider.activeSourceEntries, hasLength(1));
    final entry = f.provider.activeSourceEntries.single;
    expect(entry.key, 'test');
    expect(entry.name, '测试源');
    expect(entry.actions, containsAll(['musicUrl', 'search']));
    expect(entry.canSearch, isTrue);
  });

  test('deactivate / removeScript 委托', () async {
    final f = await fixture();
    await f.provider.importScript(_script(), activate: true);

    await f.provider.deactivate();
    expect(f.provider.activeScriptId, isNull);
    expect(f.provider.activeSourceEntries, isEmpty);

    final id = f.provider.scripts.single.id;
    await f.provider.removeScript(id);
    expect(f.provider.scripts, isEmpty);
    expect(f.manager.scripts, isEmpty);
  });

  test('channels / moveChannel / resetChannelOrder：含内置发现平台且可排序', () async {
    final f = await fixture(sources: {
      'a': const LxSourceDecl(
          key: 'a', name: 'A', actions: ['search'], qualitys: []),
      'b': const LxSourceDecl(
          key: 'b', name: 'B', actions: ['search'], qualitys: []),
    });
    await f.provider.importScript(_script(), activate: true);

    // 渠道 = 脚本搜索源 + 内置发现平台并集。
    expect(
      f.provider.channels.map((o) => o.key).toList(),
      ['a', 'b', 'wy', 'tx', 'kg', 'kw', 'mg'],
    );
    expect(
      f.provider.channels.where((o) => o.discoverable).map((o) => o.key),
      ['wy', 'tx', 'kg', 'kw', 'mg'],
    );
    expect(f.provider.searchableSources.map((o) => o.key).toList(), ['a', 'b']);

    await f.provider.moveChannel('b', -1);
    expect(f.provider.sourceOrder, ['b', 'a', 'wy', 'tx', 'kg', 'kw', 'mg']);
    expect(f.provider.searchableSources.map((o) => o.key).toList(), ['b', 'a']);

    await f.provider.resetChannelOrder();
    expect(f.provider.sourceOrder, isEmpty);
    expect(f.provider.searchableSources.map((o) => o.key).toList(), ['a', 'b']);
  });

  test('setChannelEnabled：停用后从可搜索列表消失，启用后恢复', () async {
    final f = await fixture(sources: {
      'a': const LxSourceDecl(
          key: 'a', name: 'A', actions: ['search'], qualitys: []),
    });
    await f.provider.importScript(_script(), activate: true);

    await f.provider.setChannelEnabled('a', false);
    expect(f.provider.searchableSources.map((o) => o.key).toList(), isEmpty);
    final disabled = f.provider.channels.firstWhere((o) => o.key == 'a');
    expect(disabled.enabled, isFalse);

    await f.provider.setChannelEnabled('a', true);
    expect(f.provider.searchableSources.map((o) => o.key).toList(), ['a']);
  });

  test('音质：qualityOptions 值/显示名 + setPreferredQuality 委托', () async {
    final f = await fixture();
    expect(
      f.provider.qualityOptions.map((o) => o.value).toList(),
      kLxQualityOrder,
    );
    expect(f.provider.qualityOptions.first.displayName, 'Hi-Res');
    expect(f.provider.qualityOptions.last.displayName, '128K');

    await f.provider.setPreferredQuality('flac');
    expect(f.provider.preferredQuality, 'flac');
    expect(f.manager.preferredQuality, 'flac');
  });

  test('checkScriptUpdate：脚本不存在 / 无更新地址 → 可读 SourceScriptException',
      () async {
    final f = await fixture();
    final info = await f.provider.importScript(_script());

    await expectLater(
      f.provider.checkScriptUpdate('missing'),
      throwsA(isA<SourceScriptException>()),
    );
    await expectLater(
      f.provider.checkScriptUpdate(info.id),
      throwsA(
        predicate((e) =>
            e is SourceScriptException && e.message.contains('更新地址')),
      ),
    );
  });

  test('check/applyScriptUpdate：委托成功且 apply 复用 check 的下载结果', () async {
    final f = await fixture();
    final url = server.url('/source.js');
    server.text('/source.js', _script(version: '2.0.0', updateUrl: url));
    final imported = await f.provider.importScript(_script(updateUrl: url));

    final check = await f.provider.checkScriptUpdate(imported.id);
    expect(check.hasUpdate, isTrue);
    expect(check.currentVersion, '1.0.0');
    expect(check.latestVersion, '2.0.0');

    final updated = await f.provider.applyScriptUpdate(imported.id);
    expect(updated.version, '2.0.0');
    expect(f.provider.scripts.single.version, '2.0.0');
    expect(server.hits('/source.js'), 1, reason: 'apply 应复用 check 的下载结果');
  });

  test('importFromUrl：下载 → 解析 → 导入并激活', () async {
    final f = await fixture();
    server.text('/source.js', _script());

    final info = await f.provider.importFromUrl(server.url('/source.js'));
    expect(info.name, 'provider 测试音源');
    expect(f.provider.activeScriptId, info.id);
    expect(f.provider.hasActiveSource, isTrue);
  });

  test('importFromUrl：非 HTTP(S) 地址 / 404 → 可读 SourceScriptException', () async {
    final f = await fixture();

    await expectLater(
      f.provider.importFromUrl('ftp://example.com/source.js'),
      throwsA(
        predicate((e) =>
            e is SourceScriptException && e.message.contains('HTTP(S)')),
      ),
    );
    await expectLater(
      f.provider.importFromUrl(server.url('/missing.js')),
      throwsA(
        predicate((e) =>
            e is SourceScriptException && e.message.contains('404')),
      ),
    );
  });
}

class _Fixture {
  final SourcesProvider provider;
  final SourceManager manager;

  const _Fixture(this.provider, this.manager);
}

/// 可编程 fake 引擎：记录 start 重放并返回预设源声明。
class _FakeLxEngine implements LxEngine {
  bool running = false;
  Map<String, LxSourceDecl> nextSources = {};

  final StreamController<LxLogEntry> _logs =
      StreamController<LxLogEntry>.broadcast();
  final StreamController<LxUpdateAlert> _alerts =
      StreamController<LxUpdateAlert>.broadcast();
  Map<String, LxSourceDecl> _sources = {};
  LxScriptInfo? _script;

  @override
  bool get isRunning => running;

  @override
  Stream<LxLogEntry> get logs => _logs.stream;

  @override
  Stream<LxUpdateAlert> get updateAlerts => _alerts.stream;

  @override
  Map<String, LxSourceDecl> get sources => Map.unmodifiable(_sources);

  @override
  LxScriptInfo? get script => _script;

  @override
  Future<Map<String, LxSourceDecl>> start(
    LxScriptInfo script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _script = script;
    _sources = Map<String, LxSourceDecl>.from(nextSources);
    running = true;
    return Map<String, LxSourceDecl>.from(_sources);
  }

  @override
  Future<String> getMusicUrl({
    required String source,
    required Map<String, dynamic> musicInfo,
    required String quality,
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      'https://example.com/$source/$quality';

  @override
  Future<LxLyricResult> getLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      const LxLyricResult(lyric: '[00:00.00]fake');

  @override
  Future<String> getPic({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      'https://example.com/pic.jpg';

  @override
  Future<dynamic> search({
    required String source,
    required String action,
    required String keyword,
    int page = 1,
    int limit = 20,
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      const [];

  @override
  Future<void> dispose() async {
    running = false;
  }

  @override
  Future<void> close() async {
    running = false;
    if (!_logs.isClosed) await _logs.close();
    if (!_alerts.isClosed) await _alerts.close();
  }
}

/// 本地 HTTP 服务器：注册 path 处理器并统计请求次数（验证下载复用）。
class _TestScriptServer {
  late final HttpServer _server;
  final Map<String, Future<void> Function(HttpRequest)> _routes = {};
  final Map<String, int> _hits = {};

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';

  int hits(String path) => _hits[path] ?? 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) {
      _hits[request.uri.path] = hits(request.uri.path) + 1;
      final handler = _routes[request.uri.path];
      if (handler == null) {
        request.response.statusCode = HttpStatus.notFound;
        unawaited(request.response.close().catchError((_) {}));
        return;
      }
      unawaited(handler(request).catchError((_) {}));
    });
  }

  void text(
    String path,
    String body, {
    String contentType = 'application/javascript',
    int status = 200,
  }) {
    _routes[path] = (request) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.parse(contentType);
      // 脚本含中文元信息：直接写 UTF-8 字节，避免 latin1 编码报错。
      request.response.add(utf8.encode(body));
      await request.response.close();
    };
  }

  Future<void> close() => _server.close(force: true);
}

/// 构造带合法元信息的测试脚本（fake 引擎不执行 JS，仅用于解析元信息）。
String _script({
  String version = '1.0.0',
  String? updateUrl,
}) {
  final header = StringBuffer()
    ..writeln('/**')
    ..writeln(' * @name provider 测试音源')
    ..writeln(' * @description v1')
    ..writeln(' * @version $version')
    ..writeln(' * @author tester');
  if (updateUrl != null) header.writeln(' * @updateUrl $updateUrl');
  header.writeln(' */');
  return '$header'
      "globalThis.lx.on('request', () => {});\n"
      "globalThis.lx.send({ source: 'test', action: 'musicUrl' });\n";
}
