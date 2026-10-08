import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/lx/lx_engine.dart';
import 'package:molia/sources/lx/lx_engine_supervisor.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/lx/lx_script_repository.dart';
import 'package:molia/sources/lx/lx_script_update.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可编程 fake 引擎：记录 start 重放并支持手动发出 updateAlert。
class _FakeLxEngine implements LxEngine {
  bool running = false;
  Map<String, LxSourceDecl> nextSources = {};
  int startCalls = 0;
  final List<LxScriptInfo> startedScripts = [];

  final StreamController<LxLogEntry> _logs =
      StreamController<LxLogEntry>.broadcast();
  final StreamController<LxUpdateAlert> _alerts =
      StreamController<LxUpdateAlert>.broadcast();
  Map<String, LxSourceDecl> _sources = {};
  LxScriptInfo? _script;

  void emitAlert(LxUpdateAlert alert) => _alerts.add(alert);

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
    startCalls++;
    startedScripts.add(script);
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

/// 本地 HTTP 服务器：为每个 path 注册处理器，模拟脚本下载/重定向/错误页。
class _TestScriptServer {
  late final HttpServer _server;
  final Map<String, Future<void> Function(HttpRequest)> _routes = {};

  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  String url(String path) => '$baseUrl$path';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) {
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

  void redirect(String path, String location) {
    _routes[path] = (request) async {
      request.response.statusCode = HttpStatus.movedTemporarily;
      request.response.headers.set(HttpHeaders.locationHeader, location);
      await request.response.close();
    };
  }

  Future<void> close() => _server.close(force: true);
}

LxSourceDecl _decl(String key) => LxSourceDecl(
      key: key,
      name: key,
      actions: const ['musicUrl', 'search'],
      qualitys: const ['128k', '320k'],
    );

/// 构造一个带合法元信息 + lx 用法的测试脚本。
String _script({
  String? updateUrl,
  String version = '1.0.0',
  String description = 'v1',
  String body = '',
}) {
  final header = StringBuffer()
    ..writeln('/**')
    ..writeln(' * @name 更新测试音源')
    ..writeln(' * @description $description')
    ..writeln(' * @version $version')
    ..writeln(' * @author tester');
  if (updateUrl != null) {
    header.writeln(' * @updateUrl $updateUrl');
  }
  header.writeln(' */');
  return '$header'
      "globalThis.lx.on('request', () => {});\n"
      "globalThis.lx.send({ source: 'test', action: 'musicUrl' });\n"
      '$body\n';
}

class _Fixture {
  final SourceManager manager;
  final _FakeLxEngine engine;
  final LxEngineSupervisor supervisor;

  _Fixture(this.manager, this.engine, this.supervisor);
}

Future<_Fixture> _fixture() async {
  final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
  final supervisor = LxEngineSupervisor(
    engineFactory: () => engine,
    restartDelays: const [Duration(milliseconds: 10)],
  );
  final manager = SourceManager(engine: supervisor);
  await manager.init();
  addTearDown(manager.dispose);
  addTearDown(supervisor.close);
  return _Fixture(manager, engine, supervisor);
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestScriptServer server;
  HttpOverrides? savedOverrides;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // flutter_test 的 TestWidgetsFlutterBinding 会把所有 HttpClient 请求替换为
    // 返回 400 的 mock；这里临时恢复真实网络以访问本地 HttpServer。
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    server = _TestScriptServer();
    await server.start();
  });

  tearDown(() async {
    await server.close();
    HttpOverrides.global = savedOverrides;
  });

  group('LxScriptInfo · updateUrl', () {
    test('parse 解析 @updateUrl；toJson/fromJson 往返保留', () {
      final info =
          LxScriptInfo.parse(_script(updateUrl: 'https://example.com/u.js'));
      expect(info, isNotNull);
      expect(info!.updateUrl, 'https://example.com/u.js');

      final restored = LxScriptInfo.fromJson(info.toJson());
      expect(restored.updateUrl, 'https://example.com/u.js');

      final noUrl = LxScriptInfo.parse(_script());
      expect(noUrl!.updateUrl, isNull);
      expect(LxScriptInfo.fromJson(noUrl.toJson()).updateUrl, isNull);
    });
  });

  group('LxScriptRepository · replace', () {
    test('替换内容并保留 id / importedAt / 激活态', () async {
      final repository = LxScriptRepository();
      await repository.init();
      const original = LxScriptInfo(
        id: 'script-a',
        name: '旧脚本',
        description: '旧',
        version: '1.0.0',
        author: 'tester',
        homepage: '',
        script: 'old',
        importedAt: 111,
      );
      await repository.add(original);
      await repository.setActive('script-a');

      final replaced = await repository.replace(
        'script-a',
        const LxScriptInfo(
          id: 'ignored-id',
          name: '新脚本',
          description: '新',
          version: '2.0.0',
          author: 'tester',
          homepage: 'https://example.com',
          script: 'new',
          importedAt: 999,
          updateUrl: 'https://example.com/u.js',
        ),
      );

      expect(replaced.id, 'script-a', reason: 'id 必须保留原值');
      expect(replaced.importedAt, 111, reason: '导入时间必须保留');
      expect(replaced.name, '新脚本');
      expect(replaced.version, '2.0.0');
      expect(replaced.script, 'new');
      expect(replaced.updateUrl, 'https://example.com/u.js');
      expect(repository.activeId, 'script-a', reason: '激活态不受影响');
      expect(repository.scripts.single.script, 'new');
    });

    test('updated 未带 updateUrl 时保留原 updateUrl', () async {
      final repository = LxScriptRepository();
      await repository.init();
      await repository.add(const LxScriptInfo(
        id: 'script-a',
        name: '旧',
        description: '',
        version: '1',
        author: '',
        homepage: '',
        script: 'old',
        importedAt: 1,
        updateUrl: 'https://example.com/keep.js',
      ));

      final replaced = await repository.replace(
        'script-a',
        const LxScriptInfo(
          id: 'script-a',
          name: '新',
          description: '',
          version: '2',
          author: '',
          homepage: '',
          script: 'new',
          importedAt: 2,
        ),
      );
      expect(replaced.updateUrl, 'https://example.com/keep.js');
    });

    test('找不到 id 时抛 StateError', () async {
      final repository = LxScriptRepository();
      await repository.init();
      await expectLater(
        repository.replace(
          'missing',
          const LxScriptInfo(
            id: 'missing',
            name: 'x',
            description: '',
            version: '',
            author: '',
            homepage: '',
            script: '',
            importedAt: 0,
          ),
        ),
        throwsStateError,
      );
    });
  });

  group('SourceManager · checkScriptUpdate', () {
    test('版本不同 → hasUpdate=true，latestScript 携带新内容', () async {
      final fixture = await _fixture();
      final url = server.url('/source.js');
      server.text(
          '/source.js',
          _script(updateUrl: url, version: '2.0.0', description: 'v2'));
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url));

      final check = await fixture.manager.checkScriptUpdate(imported.id);

      expect(check.hasUpdate, isTrue);
      expect(check.currentVersion, '1.0.0');
      expect(check.latestVersion, '2.0.0');
      expect(check.latestScript.id, imported.id);
      expect(check.latestScript.script, contains('@version 2.0.0'));
    });

    test('版本相同且内容相同 → hasUpdate=false', () async {
      final fixture = await _fixture();
      final url = server.url('/source.js');
      final v1 = _script(updateUrl: url);
      server.text('/source.js', v1);
      final imported = await fixture.manager.importScript(v1);

      final check = await fixture.manager.checkScriptUpdate(imported.id);

      expect(check.hasUpdate, isFalse);
      expect(check.latestVersion, '1.0.0');
    });

    test('版本相同但内容变化 → hasUpdate=true（hash 对比）', () async {
      final fixture = await _fixture();
      final url = server.url('/source.js');
      server.text('/source.js', _script(updateUrl: url, body: '// patched'));
      final imported = await fixture.manager.importScript(_script(updateUrl: url));

      final check = await fixture.manager.checkScriptUpdate(imported.id);

      expect(check.hasUpdate, isTrue);
      expect(check.latestVersion, check.currentVersion);
    });

    test('跟随重定向后仍能检查更新', () async {
      final fixture = await _fixture();
      final url = server.url('/redirect.js');
      server.text('/source.js',
          _script(updateUrl: url, version: '3.0.0', description: 'v3'));
      server.redirect('/redirect.js', '/source.js');
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url));

      final check = await fixture.manager.checkScriptUpdate(imported.id);

      expect(check.hasUpdate, isTrue);
      expect(check.latestVersion, '3.0.0');
    });

    test('无 updateUrl → noUpdateUrl', () async {
      final fixture = await _fixture();
      final imported = await fixture.manager.importScript(_script());

      await expectLater(
        fixture.manager.checkScriptUpdate(imported.id),
        throwsA(isA<ScriptUpdateException>().having(
            (e) => e.kind, 'kind', ScriptUpdateError.noUpdateUrl)),
      );
    });

    test('下载失败（HTTP 500）→ downloadFailed', () async {
      final fixture = await _fixture();
      final url = server.url('/fail.js');
      server.text('/fail.js', 'boom', status: 500);
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url));

      await expectLater(
        fixture.manager.checkScriptUpdate(imported.id),
        throwsA(isA<ScriptUpdateException>().having(
            (e) => e.kind, 'kind', ScriptUpdateError.downloadFailed)),
      );
    });

    test('更新地址返回 HTML → htmlPage（提示手动导入）', () async {
      final fixture = await _fixture();
      final url = server.url('/page');
      server.text(
        '/page',
        '<!DOCTYPE html><html><head><title>repo</title></head>'
        '<body>not a script</body></html>',
        contentType: 'text/html',
      );
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url));

      await expectLater(
        fixture.manager.checkScriptUpdate(imported.id),
        throwsA(isA<ScriptUpdateException>()
            .having((e) => e.kind, 'kind', ScriptUpdateError.htmlPage)
            .having((e) => e.message, 'message', contains('手动导入'))),
      );
    });

    test('普通 JS 但无元信息 → notAScript', () async {
      final fixture = await _fixture();
      final url = server.url('/plain.js');
      server.text('/plain.js', "console.log('hello');\n");
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url));

      await expectLater(
        fixture.manager.checkScriptUpdate(imported.id),
        throwsA(isA<ScriptUpdateException>().having(
            (e) => e.kind, 'kind', ScriptUpdateError.notAScript)),
      );
    });

    test('超过 1MB 上限 → tooLarge', () async {
      final fixture = await _fixture();
      final url = server.url('/big.js');
      server.text('/big.js', 'a' * (kLxScriptMaxBytes + 16));
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url));

      await expectLater(
        fixture.manager.checkScriptUpdate(imported.id),
        throwsA(isA<ScriptUpdateException>()
            .having((e) => e.kind, 'kind', ScriptUpdateError.tooLarge)),
      );
    });
  });

  group('SourceManager · applyScriptUpdate', () {
    test('替换内容并保留 id + 激活态，激活中脚本重新激活（重放新脚本）', () async {
      final fixture = await _fixture();
      final url = server.url('/source.js');
      server.text(
          '/source.js',
          _script(updateUrl: url, version: '2.0.0', description: 'v2'));
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url),
              activate: true);
      expect(fixture.engine.startCalls, 1);

      // 新版本声明了额外的源：重放后 activeSources 应刷新。
      fixture.engine.nextSources = {
        'test': _decl('test'),
        'extra': _decl('extra'),
      };
      final updated = await fixture.manager.applyScriptUpdate(imported.id);

      expect(updated.id, imported.id);
      expect(updated.importedAt, imported.importedAt);
      expect(updated.version, '2.0.0');
      expect(updated.script, contains('@version 2.0.0'));
      expect(fixture.manager.repository.activeId, imported.id);
      expect(fixture.engine.startCalls, 2, reason: '激活中的脚本必须重放一次');
      expect(fixture.engine.startedScripts.last.script,
          contains('@version 2.0.0'));
      expect(fixture.manager.activeSources.keys, containsAll(['test', 'extra']));
    });

    test('未激活脚本更新时不触碰引擎', () async {
      final fixture = await _fixture();
      final url = server.url('/source.js');
      server.text(
          '/source.js',
          _script(updateUrl: url, version: '2.0.0', description: 'v2'));
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url),
              activate: true);
      await fixture.manager.deactivate();
      final startsBefore = fixture.engine.startCalls;

      final updated = await fixture.manager.applyScriptUpdate(imported.id);

      expect(updated.version, '2.0.0');
      expect(fixture.engine.startCalls, startsBefore);
      expect(fixture.manager.repository.activeId, isNull);
    });

    test('复用 check 结果时不重复下载（服务器路由已移除仍成功）', () async {
      final fixture = await _fixture();
      final url = server.url('/source.js');
      server.text(
          '/source.js',
          _script(updateUrl: url, version: '2.0.0', description: 'v2'));
      final imported =
          await fixture.manager.importScript(_script(updateUrl: url));
      final check = await fixture.manager.checkScriptUpdate(imported.id);

      // 模拟“下载后地址失效”：再次下载会 404，但复用 check 不应再请求。
      server.text('/source.js', 'gone', status: 404);
      final updated = await fixture.manager.applyScriptUpdate(
        imported.id,
        check: check,
      );

      expect(updated.version, '2.0.0');
    });
  });

  group('SourceManager · updateAlert', () {
    test('updateUrl 记入当前激活脚本，供一键更新使用', () async {
      final fixture = await _fixture();
      final imported = await fixture.manager.importScript(_script(),
          activate: true);
      expect(fixture.manager.activeScript?.updateUrl, isNull);

      const alertUrl = 'https://example.com/update/source.js';
      fixture.engine.emitAlert(const LxUpdateAlert(
        log: '发现新版本 2.0.0',
        updateUrl: alertUrl,
      ));

      await _waitUntil(
          () => fixture.manager.activeScript?.updateUrl == alertUrl);
      expect(fixture.manager.lastUpdateAlert?.log, '发现新版本 2.0.0');
      expect(fixture.manager.repository.scripts.single.id, imported.id);

      fixture.manager.clearUpdateAlert();
      expect(fixture.manager.lastUpdateAlert, isNull);
    });

    test('无 updateUrl 的 alert 不修改脚本', () async {
      final fixture = await _fixture();
      await fixture.manager.importScript(_script(), activate: true);

      fixture.engine.emitAlert(const LxUpdateAlert(log: '有新版本'));
      await _waitUntil(() => fixture.manager.lastUpdateAlert != null);

      expect(fixture.manager.activeScript?.updateUrl, isNull);
    });
  });
}
