import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/lx/lx_engine.dart';
import 'package:molia/sources/lx/lx_engine_supervisor.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可编程 fake 引擎：模拟 start 失败、invoke 超时（kill isolate）与重启。
class _FakeLxEngine implements LxEngine {
  bool running = false;
  bool failStart = false;
  bool failInvoke = false;

  /// 每次 start 返回的源声明（测试可在重启前替换，验证 refresh）。
  Map<String, LxSourceDecl> nextSources = {};

  int startCalls = 0;
  int musicUrlCalls = 0;
  int lyricCalls = 0;
  int picCalls = 0;
  int searchCalls = 0;
  int disposeCalls = 0;
  final List<LxScriptInfo> startedScripts = [];
  final List<DateTime> startTimes = [];

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
    startCalls++;
    startedScripts.add(script);
    startTimes.add(DateTime.now());
    if (failStart) {
      running = false;
      throw const LxEngineException('脚本初始化失败（fake）');
    }
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
  }) async {
    musicUrlCalls++;
    _simulateInvoke();
    return 'https://example.com/$source/$quality';
  }

  @override
  Future<LxLyricResult> getLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    lyricCalls++;
    _simulateInvoke();
    return const LxLyricResult(lyric: '[00:00.00]fake');
  }

  @override
  Future<String> getPic({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    picCalls++;
    _simulateInvoke();
    return 'https://example.com/pic.jpg';
  }

  @override
  Future<dynamic> search({
    required String source,
    required String action,
    required String keyword,
    int page = 1,
    int limit = 20,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    searchCalls++;
    _simulateInvoke();
    return [
      {'name': 'fake-$keyword', 'id': '1'},
    ];
  }

  /// invoke 超时（脚本死循环）语义：isolate 退出且抛错。
  void _simulateInvoke() {
    if (failInvoke) {
      running = false;
      throw const LxEngineException('音源请求超时（fake），引擎已重启');
    }
    if (!running) {
      throw const LxEngineException('音源引擎未运行');
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    running = false;
  }

  @override
  Future<void> close() async {
    running = false;
    if (!_logs.isClosed) await _logs.close();
    if (!_alerts.isClosed) await _alerts.close();
  }
}

LxScriptInfo _scriptInfo() => const LxScriptInfo(
      id: 'script-1',
      name: '测试脚本',
      description: '',
      version: '1.0.0',
      author: 'tester',
      homepage: '',
      script: '/** @name 测试脚本 */',
      importedAt: 0,
    );

LxSourceDecl _decl(String key) => LxSourceDecl(
      key: key,
      name: key,
      actions: const ['musicUrl', 'search', 'lyric', 'pic'],
      qualitys: const ['128k', '320k'],
    );

const _musicInfo = <String, dynamic>{'id': '1'};

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<String> _musicUrl(LxEngineSupervisor supervisor) => supervisor
    .getMusicUrl(source: 'test', musicInfo: _musicInfo, quality: '320k');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LxEngineSupervisor · 状态机', () {
    test('start：stopped → starting → ready，invoke 透传', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration.zero],
      );
      addTearDown(supervisor.close);
      final states = <LxEngineState>[];
      supervisor.onStateChanged = states.add;

      final sources = await supervisor.start(_scriptInfo());

      expect(sources.keys, ['test']);
      expect(supervisor.state, LxEngineState.ready);
      expect(supervisor.isRunning, isTrue);
      expect(supervisor.sources.keys, ['test']);
      expect(states, [LxEngineState.starting, LxEngineState.ready]);

      final url = await _musicUrl(supervisor);
      expect(url, 'https://example.com/test/320k');
      expect(engine.musicUrlCalls, 1);
    });

    test('start 失败：状态回 stopped，不进入自动重启', () async {
      final engine = _FakeLxEngine()..failStart = true;
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
      );
      addTearDown(supervisor.close);

      await expectLater(
        supervisor.start(_scriptInfo()),
        throwsA(isA<LxEngineException>()),
      );
      expect(supervisor.state, LxEngineState.stopped);
      expect(supervisor.isRunning, isFalse);
      expect(engine.startCalls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.startCalls, 1, reason: 'start 失败不应触发自动重启');
    });

    test('invoke 超时 kill 后自动重启，用同一脚本重放并恢复', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());

      engine.failInvoke = true; // 脚本死循环：invoke 超时 + isolate 退出
      await expectLater(
        _musicUrl(supervisor),
        throwsA(isA<LxEngineException>()),
      );
      expect(supervisor.state, isNot(LxEngineState.stopped));

      engine.failInvoke = false;
      await _waitUntil(() => supervisor.state == LxEngineState.ready);
      expect(engine.startCalls, 2, reason: '崩溃后应自动重启一次');
      expect(engine.startedScripts.last.id, 'script-1',
          reason: '必须重放同一脚本');
      expect(await _musicUrl(supervisor), 'https://example.com/test/320k');
      expect(engine.musicUrlCalls, 2);
      expect(supervisor.restartAttempts, 0, reason: '成功 invoke 后计数清零');
    });

    test('重启成功但每次 invoke 都崩溃：累计 3 次后进入 failed', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 10),
          Duration(milliseconds: 10),
        ],
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());
      engine.failInvoke = true;

      for (var i = 0; i < 3; i++) {
        await expectLater(
          _musicUrl(supervisor),
          throwsA(isA<LxEngineException>()),
        );
        await _waitUntil(() => supervisor.state != LxEngineState.restarting);
        expect(supervisor.state, LxEngineState.ready,
            reason: '第 ${i + 1} 次重启成功');
      }

      // 第 4 次崩溃：连续计数已达上限 → failed（不再无限重启）。
      await expectLater(
        _musicUrl(supervisor),
        throwsA(isA<LxEngineException>()),
      );
      expect(supervisor.state, LxEngineState.failed);
      expect(engine.startCalls, 4, reason: '1 次初始 + 3 次重启');
      expect(supervisor.restartAttempts, 3);
    });

    test('重启期间到达的请求等待 ready 后在新引擎上执行', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 30)],
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());

      engine.running = false; // isolate 静默退出，尚无 invoke 失败
      final url = await _musicUrl(supervisor); // 等待重启完成后执行
      expect(url, 'https://example.com/test/320k');
      expect(engine.startCalls, 2);
      expect(supervisor.state, LxEngineState.ready);
    });

    test('退避顺序 0.5s/2s/8s（注入缩短间隔）；连续 3 次失败 → failed', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [
          Duration(milliseconds: 40),
          Duration(milliseconds: 80),
          Duration(milliseconds: 120),
        ],
      );
      addTearDown(supervisor.close);
      final states = <LxEngineState>[];
      supervisor.onStateChanged = states.add;
      await supervisor.start(_scriptInfo());

      engine.failStart = true; // 重启必然失败
      engine.running = false;
      await expectLater(
        _musicUrl(supervisor),
        throwsA(isA<LxEngineException>()),
      );
      await _waitUntil(() => supervisor.state == LxEngineState.failed);

      expect(engine.startCalls, 4, reason: '1 次初始 + 3 次重启尝试');
      expect(supervisor.restartAttempts, 3);
      expect(states, containsAllInOrder([
        LxEngineState.restarting,
        LxEngineState.failed,
      ]));

      final gaps = [
        for (var i = 1; i < engine.startTimes.length; i++)
          engine.startTimes[i].difference(engine.startTimes[i - 1]),
      ];
      expect(gaps[0].inMilliseconds, greaterThanOrEqualTo(30),
          reason: '第 1 次退避 40ms');
      expect(gaps[1].inMilliseconds, greaterThanOrEqualTo(60),
          reason: '第 2 次退避 80ms');
      expect(gaps[2].inMilliseconds, greaterThanOrEqualTo(90),
          reason: '第 3 次退避 120ms');

      // failed 终态：invoke 立即失败，不再自动重启。
      await expectLater(
        _musicUrl(supervisor),
        throwsA(isA<LxEngineException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(engine.startCalls, 4, reason: 'failed 后停止自动重启');

      // 外部再次 start：恢复 ready 并重置失败计数。
      engine.failStart = false;
      await supervisor.start(_scriptInfo());
      expect(supervisor.state, LxEngineState.ready);
      expect(supervisor.restartAttempts, 0);
      expect(await _musicUrl(supervisor), isNotEmpty);
    });

    test('dispose 取消待执行的重启并回到 stopped', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 200)],
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());

      engine.running = false;
      final pending = _musicUrl(supervisor).then<String?>((v) => v,
          onError: (Object _) => null);
      await _waitUntil(() => supervisor.state == LxEngineState.restarting);

      await supervisor.dispose();
      await pending;
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(supervisor.state, LxEngineState.stopped);
      expect(engine.startCalls, 1, reason: 'dispose 后不应再执行重启');
      expect(engine.disposeCalls, 1);
    });
  });

  group('SourceManager · supervisor 接入', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('重启成功后用 supervisor.sources 刷新 activeSources 并通知', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
      );
      addTearDown(supervisor.close);
      final manager = SourceManager(engine: supervisor);
      addTearDown(manager.dispose);
      await manager.init();

      var notifications = 0;
      manager.addListener(() => notifications++);

      await manager.importScript('''
/**
 * @name 测试脚本
 * @description fake
 * @version 1.0.0
 */
const noop = 1;
''', activate: true);

      expect(manager.activeSources.keys, ['test']);
      expect(manager.hasActiveSource, isTrue);

      // 重启后脚本声明了新的源：search 触发崩溃检测 → 等待重启 → 刷新列表。
      engine.nextSources = {'test': _decl('test'), 'extra': _decl('extra')};
      engine.running = false;
      final tracks = await manager.search('test', 'hello');

      expect(tracks, isNotEmpty);
      expect(engine.startCalls, 2);
      expect(manager.activeSources.keys, containsAll(['test', 'extra']));
      expect(manager.hasActiveSource, isTrue);
      expect(notifications, greaterThan(0));

      await manager.deactivate();
      expect(supervisor.state, LxEngineState.stopped);
      expect(manager.activeSources, isEmpty);
      expect(manager.hasActiveSource, isFalse);
    });
  });
}
