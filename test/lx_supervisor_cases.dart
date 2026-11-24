import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/lx/lx_engine.dart';
import 'package:molia/sources/lx/lx_engine_supervisor.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settings_test_support.dart';

/// 可编程 fake 引擎：模拟 start 失败、invoke 超时（kill isolate）与重启。
class _FakeLxEngine implements LxEngine {
  bool running = false;
  bool failStart = false;
  bool failInvoke = false;

  /// 模拟「脚本活着但请求不回响应」：抛 [LxEngineTimeoutException] 且不退出。
  bool timeoutInvoke = false;

  /// 每次 start 返回的源声明（测试可在重启前替换，验证 refresh）。
  Map<String, LxSourceDecl> nextSources = {};

  /// 挂起 start（并发 / single-flight 测试用；不设则不等待）。
  Completer<void>? startGate;

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
    if (startGate != null) await startGate!.future;
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
    if (timeoutInvoke) {
      // 引擎侧新语义：请求超时但引擎仍存活（isolate 探活有应答）
      throw const LxEngineTimeoutException('音源请求超时（fake）');
    }
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

/// 把 supervisor 打进 failed（连续超时熔断，阈值 1）：最省时的失败入口。
Future<void> _failByTimeout(
  LxEngineSupervisor supervisor,
  _FakeLxEngine engine,
) async {
  engine.timeoutInvoke = true;
  await expectLater(
    _musicUrl(supervisor),
    throwsA(isA<LxEngineTimeoutException>()),
  );
  engine.timeoutInvoke = false;
  expect(supervisor.state, LxEngineState.failed);
}

/// 让可注入的短冷却到期（不用真实 60s）。
Future<void> _elapseCooldown() =>
    Future<void>.delayed(const Duration(milliseconds: 60));

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

    test('未 start / 未运行时 invoke 抛 LxEngineUnavailableException', () async {
      final engine = _FakeLxEngine();
      final supervisor = LxEngineSupervisor(engineFactory: () => engine);
      addTearDown(supervisor.close);

      await expectLater(
        _musicUrl(supervisor),
        throwsA(isA<LxEngineUnavailableException>()),
      );
      expect(engine.musicUrlCalls, 0, reason: '请求根本没被执行');
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
      expect(engine.startedScripts.last.id, 'script-1', reason: '必须重放同一脚本');
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
        expect(
          supervisor.state,
          LxEngineState.ready,
          reason: '第 ${i + 1} 次重启成功',
        );
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
      expect(
        states,
        containsAllInOrder([LxEngineState.restarting, LxEngineState.failed]),
      );

      final gaps = [
        for (var i = 1; i < engine.startTimes.length; i++)
          engine.startTimes[i].difference(engine.startTimes[i - 1]),
      ];
      expect(
        gaps[0].inMilliseconds,
        greaterThanOrEqualTo(30),
        reason: '第 1 次退避 40ms',
      );
      expect(
        gaps[1].inMilliseconds,
        greaterThanOrEqualTo(60),
        reason: '第 2 次退避 80ms',
      );
      expect(
        gaps[2].inMilliseconds,
        greaterThanOrEqualTo(90),
        reason: '第 3 次退避 120ms',
      );

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

    test('连续超时熔断：引擎存活但连续 3 次超时 → failed 并上报原因', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 3,
      );
      addTearDown(supervisor.close);
      final states = <LxEngineState>[];
      supervisor.onStateChanged = states.add;
      await supervisor.start(_scriptInfo());

      engine.timeoutInvoke = true;
      for (var i = 1; i <= 3; i++) {
        await expectLater(
          _musicUrl(supervisor),
          throwsA(isA<LxEngineTimeoutException>()),
        );
        expect(supervisor.consecutiveTimeouts, i);
        expect(
          supervisor.state,
          i < 3 ? LxEngineState.ready : LxEngineState.failed,
        );
      }

      expect(engine.startCalls, 1, reason: '超时不重启引擎');
      expect(supervisor.failureReason, contains('连续 3 次请求超时'));
      expect(states, contains(LxEngineState.failed));
      expect(engine.disposeCalls, 1, reason: '进入 failed 时释放 isolate');

      // failed 终态：后续 invoke 立即失败，不再重试（也可由外部再次 start 恢复）
      await expectLater(
        _musicUrl(supervisor),
        throwsA(isA<LxEngineException>()),
      );
      expect(supervisor.consecutiveTimeouts, 3);

      engine.timeoutInvoke = false;
      await supervisor.start(_scriptInfo());
      expect(supervisor.state, LxEngineState.ready);
      expect(supervisor.consecutiveTimeouts, 0);
      expect(supervisor.failureReason, isNull);
      expect(await _musicUrl(supervisor), isNotEmpty);
    });

    test('超时计数被成功请求清零：不会误判熔断', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 2,
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());

      for (var i = 0; i < 4; i++) {
        engine.timeoutInvoke = true;
        await expectLater(
          _musicUrl(supervisor),
          throwsA(isA<LxEngineTimeoutException>()),
        );
        engine.timeoutInvoke = false;
        expect(await _musicUrl(supervisor), isNotEmpty);
        expect(supervisor.consecutiveTimeouts, 0, reason: '成功请求后清零');
        expect(supervisor.state, LxEngineState.ready);
      }
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
      final pending = _musicUrl(supervisor)
          .then<String?>((v) => v, onError: (Object _) => null);
      await _waitUntil(() => supervisor.state == LxEngineState.restarting);

      await supervisor.dispose();
      await pending;
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(supervisor.state, LxEngineState.stopped);
      expect(engine.startCalls, 1, reason: 'dispose 后不应再执行重启');
      expect(engine.disposeCalls, 1);
    });
  });

  group('LxEngineSupervisor · failed 半开自愈', () {
    test('冷却未到：直接抛 LxEngineUnavailableException，不重跑脚本', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 1,
        recoveryCooldown: const Duration(seconds: 30),
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());
      await _failByTimeout(supervisor, engine);

      await expectLater(
        _musicUrl(supervisor),
        throwsA(
          predicate(
            (e) =>
                e is LxEngineUnavailableException &&
                e.message.contains('连续 1 次请求超时'),
          ),
        ),
      );
      expect(engine.startCalls, 1, reason: '冷却期不重跑脚本');
      expect(engine.musicUrlCalls, 1, reason: '请求根本没被执行');
      expect(supervisor.state, LxEngineState.failed);
    });

    test('冷却已到：下一次请求半开恢复成功（重放同一脚本）', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 1,
        recoveryCooldown: const Duration(milliseconds: 40),
      );
      addTearDown(supervisor.close);
      final states = <LxEngineState>[];
      supervisor.onStateChanged = states.add;
      await supervisor.start(_scriptInfo());
      await _failByTimeout(supervisor, engine);

      await _elapseCooldown();
      final url = await _musicUrl(supervisor);

      expect(url, 'https://example.com/test/320k');
      expect(engine.startCalls, 2, reason: '1 次初始 + 1 次半开恢复');
      expect(engine.startedScripts.last.id, 'script-1');
      expect(supervisor.state, LxEngineState.ready);
      expect(supervisor.failureReason, isNull);
      expect(
        states,
        containsAllInOrder([LxEngineState.starting, LxEngineState.ready]),
      );
    });

    test('半开失败：回到 failed 并重置冷却', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 1,
        recoveryCooldown: const Duration(milliseconds: 40),
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());
      await _failByTimeout(supervisor, engine);

      engine.failStart = true; // 半开恢复必然失败
      await _elapseCooldown();
      await expectLater(
        _musicUrl(supervisor),
        throwsA(isA<LxEngineUnavailableException>()),
      );
      expect(engine.startCalls, 2);
      expect(supervisor.state, LxEngineState.failed);
      expect(supervisor.failureReason, contains('自动恢复失败'));

      // 冷却从这次失败重新计时：立刻再请求不会再启动脚本。
      await expectLater(
        _musicUrl(supervisor),
        throwsA(isA<LxEngineUnavailableException>()),
      );
      expect(engine.startCalls, 2, reason: '半开失败后重新进入冷却');
    });

    test('retryNow：绕过冷却立即尝试，失败保持 failed', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 1,
        recoveryCooldown: const Duration(seconds: 30),
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());
      await _failByTimeout(supervisor, engine);

      expect(await supervisor.retryNow(), isTrue);
      expect(engine.startCalls, 2, reason: '冷却期内也可立即重试');
      expect(supervisor.state, LxEngineState.ready);
      expect(supervisor.isFailed, isFalse);
      expect(await _musicUrl(supervisor), isNotEmpty);

      // 无脚本 / 已 ready：没有可做的事，按成功返回。
      expect(await supervisor.retryNow(), isTrue);
      await supervisor.dispose();
      expect(await supervisor.retryNow(), isTrue, reason: '无脚本可恢复');
    });

    test('retryNow 失败：返回 false 并保持 failed', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 1,
        recoveryCooldown: const Duration(seconds: 30),
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());
      await _failByTimeout(supervisor, engine);

      engine.failStart = true;
      expect(await supervisor.retryNow(), isFalse);
      expect(supervisor.state, LxEngineState.failed);
      expect(engine.startCalls, 2);
    });

    test('并发请求只触发一次半开恢复', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 1,
        recoveryCooldown: const Duration(milliseconds: 20),
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());
      await _failByTimeout(supervisor, engine);
      await _elapseCooldown();

      // 让恢复中的 start 挂住，三个请求同时等它。
      engine.startGate = Completer<void>();
      final pending = [
        _musicUrl(supervisor),
        _musicUrl(supervisor),
        _musicUrl(supervisor),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(engine.startCalls, 2, reason: '半开恢复只启动一次');
      engine.startGate!.complete();
      final urls = await Future.wait(pending);

      expect(urls, everyElement('https://example.com/test/320k'));
      expect(engine.startCalls, 2);
      expect(supervisor.state, LxEngineState.ready);
    });

    test('dispose 取消半开等待：等待者立即醒来而不是挂到超时', () async {
      final engine = _FakeLxEngine()..nextSources = {'test': _decl('test')};
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
        maxConsecutiveTimeouts: 1,
        recoveryCooldown: const Duration(milliseconds: 20),
      );
      addTearDown(supervisor.close);
      await supervisor.start(_scriptInfo());
      await _failByTimeout(supervisor, engine);
      await _elapseCooldown();

      engine.startGate = Completer<void>();
      final pending = _musicUrl(supervisor)
          .then<String?>((v) => v, onError: (Object _) => null);
      await Future<void>.delayed(Duration.zero);
      await supervisor.dispose();
      engine.startGate!.complete();
      await pending;

      expect(supervisor.state, LxEngineState.stopped);
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
      final manager = SourceManager(
        engine: supervisor,
        settings: testSettingsRegistry(),
      );
      addTearDown(manager.dispose);
      await manager.init();

      var notifications = 0;
      manager.changes.addListener(() => notifications++);

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
      final tracks = (await manager.searchWithMeta('test', 'hello')).tracks;

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

  group('SourceManager · 激活自愈', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    /// 预置一个「已保存为激活态」的脚本再 init；[failStart] 模拟激活失败。
    Future<({SourceManager manager, _FakeLxEngine engine})> seededManager({
      required bool failStart,
      List<Duration> retryDelays = const [],
      Duration lazyCooldown = Duration.zero,
    }) async {
      final engine = _FakeLxEngine()
        ..nextSources = {'test': _decl('test')}
        ..failStart = failStart;
      final supervisor = LxEngineSupervisor(
        engineFactory: () => engine,
        restartDelays: const [Duration(milliseconds: 10)],
      );
      final manager = SourceManager(
        engine: supervisor,
        settings: testSettingsRegistry(),
        activationRetryDelays: retryDelays,
        lazyActivationCooldown: lazyCooldown,
      );
      addTearDown(manager.dispose);
      addTearDown(supervisor.close);
      // 测试里脚本仓库不落盘（path_provider 不可用），直接写内存态。
      await manager.repository.add(_scriptInfo());
      await manager.repository.setActive('script-1');
      await manager.init();
      return (manager: manager, engine: engine);
    }

    test('init 激活失败：按注入间隔延迟重试并恢复', () async {
      final f = await seededManager(
        failStart: true,
        retryDelays: const [Duration(milliseconds: 50)],
      );
      expect(f.manager.activeSources, isEmpty);
      expect(f.manager.activeError, isNotNull);
      expect(f.engine.startCalls, 1);

      f.engine.failStart = false;
      await _waitUntil(() => f.manager.activeSources.isNotEmpty);

      expect(f.engine.startCalls, 2);
      expect(f.manager.activeError, isNull);
      expect(f.manager.hasActiveSource, isTrue);
      expect(f.manager.repository.activeId, 'script-1');
    });

    test('惰性首次使用：脚本源搜索入口补一次激活', () async {
      final f = await seededManager(failStart: true);
      expect(f.manager.activeSources, isEmpty);

      f.engine.failStart = false;
      final result = await f.manager.searchWithMeta('test', 'hello');

      expect(result.tracks, isNotEmpty);
      expect(f.engine.startCalls, 2, reason: '首次使用时补激活，不依赖启动重试');
      expect(f.manager.activeError, isNull);
    });

    test('用户主动停用：脚本源直接不可用，绝不自动激活', () async {
      final f = await seededManager(failStart: true);
      await f.manager.deactivate();
      expect(f.manager.repository.activeId, isNull);

      f.engine.failStart = false;
      final callsBefore = f.engine.startCalls;
      await expectLater(
        f.manager.searchWithMeta('test', 'hello'),
        throwsA(isA<LxEngineException>()),
      );

      expect(f.engine.startCalls, callsBefore, reason: '停用后不再拉起引擎');
      expect(f.manager.activeError, isNull, reason: '停用不是错误状态');
    });

    test('retryEngine：恢复成功后刷新 activeSources 并清错误', () async {
      final f = await seededManager(failStart: true);
      expect(f.manager.activeError, isNotNull);

      f.engine.failStart = false;
      expect(await f.manager.retryEngine(), isTrue);

      expect(f.manager.activeSources.keys, ['test']);
      expect(f.manager.hasActiveSource, isTrue);
      expect(f.manager.activeError, isNull);
      expect(f.manager.engineFailed, isFalse);
    });

    test('retryEngine：失败写回 activeError 并保持 failed', () async {
      final f = await seededManager(failStart: true);

      expect(await f.manager.retryEngine(), isFalse);

      expect(f.manager.activeError, isNotNull);
      expect(f.manager.activeSources, isEmpty);
      expect(f.manager.engineFailed, isTrue);
    });
  });
}
