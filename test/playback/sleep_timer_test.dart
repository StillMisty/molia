import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/sleep_timer.dart';
import 'package:molia/services/sleep_timer_alarm.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 记录 arm/cancel 的可注入假原生定时器。
class _FakeSleepTimerAlarm implements SleepTimerAlarm {
  SleepTimerFired? _onFired;
  final List<(Duration, int, bool)> arms = [];
  int cancels = 0;
  bool disposed = false;

  @override
  set onFired(SleepTimerFired? callback) => _onFired = callback;

  @override
  void arm(Duration delay, int token, {bool keepAwake = true}) =>
      arms.add((delay, token, keepAwake));

  @override
  void cancel() => cancels++;

  @override
  void dispose() => disposed = true;

  void fire(int token) => _onFired?.call(token);
}

Track _track(String id, {Duration duration = const Duration(seconds: 30)}) =>
    Track(
      id: TrackId('kw', id),
      title: 'Title $id',
      artists: const [Artist(name: 'Artist')],
      duration: duration,
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

TestPlaybackFrame _snapshot({
  Track? current,
  List<Track> queue = const [],
  int currentIndex = 0,
  bool isPlaying = true,
  Duration position = Duration.zero,
  Duration duration = Duration.zero,
}) => (
  snapshot: PlaybackSnapshot(
    current: current,
    queue: queue,
    currentIndex: current == null ? -1 : currentIndex,
    isPlaying: isPlaying,
    duration: duration,
  ),
  position: position,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackFacade backend;
  late FakePlaybackFacade facade;
  late SleepTimerController timer;
  late DateTime now;
  late int fired;
  late int exited;
  late List<String> events;
  late _FakeSleepTimerAlarm alarm;
  late List<Duration> fades;
  late List<bool> fadeCancels;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 1, 1, 22);
    fired = 0;
    exited = 0;
    events = [];
    fades = [];
    fadeCancels = [];
    backend = FakePlaybackFacade();
    facade = backend;
    alarm = _FakeSleepTimerAlarm();
    timer = SleepTimerController(
      snapshot: facade.snapshot,
      position: facade.position,
      // 与组合根一致：完成事件 + 停止标志都走 facade。
      trackCompletions: facade.trackCompletions,
      setStopAfterCurrentTrack: facade.setStopAfterCurrentTrack,
      // 到点动作：本文件只测定时判定，直接用 facade.pause 记录触发次数；
      // 命令面路由与提交由 playback_session_test 覆盖。
      onFire: () async {
        fired++;
        events.add('pause');
        await facade.pause();
      },
      onExit: () async {
        exited++;
        events.add('exit');
      },
      // 淡出动作只记录：定时器不碰播放器，音频结果由服务测试覆盖。
      onFadeStart: fades.add,
      onFadeCancel: ({required bool restore}) => fadeCancels.add(restore),
      now: () => now,
      alarm: alarm,
    );
  });

  tearDown(() {
    timer.dispose();
    facade.dispose();
  });

  /// 推进注入时钟并让内部 ticker 触发（两者必须同步，剩余时间按 now 差值算）。
  Future<void> advance(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
  }

  testWidgets('倒计时：仅播放时计时，暂停冻结、恢复继续、到点暂停并复位', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    expect(timer.value.mode, SleepTimerMode.countdown);
    expect(timer.value.remaining, const Duration(minutes: 1));
    expect(timer.value.duration, const Duration(minutes: 1));

    await advance(tester, const Duration(seconds: 10));
    expect(timer.value.remaining, const Duration(seconds: 50));
    expect(timer.value.duration, const Duration(minutes: 1));

    // 暂停：倒计时冻结（走真实时间也不掉）。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        isPlaying: false,
        position: const Duration(seconds: 10),
      ),
    );
    await advance(tester, const Duration(minutes: 5));
    expect(timer.value.remaining, const Duration(seconds: 50));
    expect(fired, 0);

    // 恢复播放：继续走完剩余 50 秒。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 10),
      ),
    );
    await advance(tester, const Duration(seconds: 50));
    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
    expect(timer.value.duration, isNull);
    expect(backend.calls, contains('pause'));
  });

  testWidgets('倒计时到点：勾选退出应用 → 先暂停再退出', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.setExitApp(true);
    expect(timer.exitApp.value, isTrue);
    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(minutes: 1));
    await tester.pump();

    expect(fired, 1);
    expect(exited, 1);
    expect(events, ['pause', 'exit']);
  });

  testWidgets('倒计时到点：未勾选退出应用 → 只暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.setExitApp(false);
    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(minutes: 1));
    await tester.pump();

    expect(fired, 1);
    expect(exited, 0);
  });

  testWidgets('倒计时：取消后不再触发', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(seconds: 10));
    timer.cancel();
    expect(timer.value.mode, SleepTimerMode.off);
    expect(timer.value.remaining, isNull);
    expect(timer.value.duration, isNull);

    await advance(tester, const Duration(minutes: 2));
    expect(fired, 0);
  });

  testWidgets('倒计时：勾选退出后取消 → 不到点退出', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.setExitApp(true);
    timer.startCountdown(const Duration(minutes: 1));
    timer.cancel();
    await advance(tester, const Duration(minutes: 2));

    expect(fired, 0);
    expect(exited, 0);
  });

  testWidgets('播完当前歌曲：自然播完（切歌前已在曲末）→ 暂停', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emitFrame(
      _snapshot(current: a, queue: [a, b], duration: a.duration!),
    );

    timer.startAfterCurrentTrack();
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);
    expect(timer.value.duration, isNull);

    // 播到曲末 → 后端装载下一首（进度通道先对齐到新曲目）。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a, b],
        duration: a.duration!,
        position: const Duration(seconds: 29),
      ),
    );
    backend.emitFrame(
      _snapshot(
        current: b,
        queue: [a, b],
        currentIndex: 1,
        duration: b.duration!,
        position: Duration.zero,
      ),
    );
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
    expect(backend.calls, contains('pause'));
  });

  testWidgets('播完当前歌曲：勾选退出应用 → 暂停后退出', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emitFrame(
      _snapshot(current: a, queue: [a, b], duration: a.duration!),
    );

    timer.setExitApp(true);
    timer.startAfterCurrentTrack();
    backend.emitTrackCompletion(a);
    backend.emitFrame(
      _snapshot(
        current: b,
        queue: [a, b],
        currentIndex: 1,
        duration: b.duration!,
        position: Duration.zero,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );

    expect(fired, 1);
    expect(exited, 1);
    expect(events, ['pause', 'exit']);
  });

  testWidgets('播完当前歌曲：队列末尾自然结束且勾选退出 → 退出', (tester) async {
    final a = _track('a');
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: a.duration!,
      ),
    );

    timer.setExitApp(true);
    timer.startAfterCurrentTrack();
    // 没有完成事件（旧后端 / 位置回退路径）：曲末后播放停止。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        isPlaying: false,
        position: a.duration!,
      ),
    );
    await tester.pump();
    await tester.idle();

    expect(fired, 1);
    expect(exited, 1);
  });

  testWidgets('播完当前歌曲：熄屏后位置 tick 停在半途，仍按完成事件暂停', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a, b],
        duration: a.duration!,
        position: const Duration(seconds: 10),
      ),
    );

    timer.startAfterCurrentTrack();
    expect(backend.stopAfterCurrentTrack, isTrue);

    // 熄屏 / 后台：位置流没有继续 tick，_maxPosition 停在 10s；播放器原生
    // 完成当前曲目并准备自动切下一首。完成事件必须先于「曲目变了」判定。
    backend.emitTrackCompletion(a);
    backend.emitFrame(
      _snapshot(
        current: b,
        queue: [a, b],
        currentIndex: 1,
        duration: b.duration!,
      ),
    );
    await tester.pump();

    expect(fired, 1, reason: '不能把自然播完误判成手动切歌');
    expect(timer.value.mode, SleepTimerMode.off);
    expect(backend.calls, contains('pause'));
    expect(backend.stopAfterCurrentTrack, isFalse, reason: '一次性标志应撤销');
  });

  testWidgets('播完当前歌曲：手动切歌跟随新曲目继续等待', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emitFrame(
      _snapshot(current: a, queue: [a, b], duration: a.duration!),
    );

    timer.startAfterCurrentTrack();
    // 中途手动切歌（远未到曲末）：不暂停，跟随新曲目。
    backend.emitFrame(
      _snapshot(
        current: b,
        queue: [a, b],
        currentIndex: 1,
        duration: b.duration!,
        position: Duration.zero,
      ),
    );
    expect(fired, 0);
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);
    expect(backend.stopAfterCurrentTrack, isTrue, reason: '手动切歌应继续等待新曲目');

    // 新曲目自然播完（队列末尾：播放停止）→ 无下一首可暂停，撤销定时。
    backend.emitFrame(
      _snapshot(
        current: b,
        queue: [a, b],
        currentIndex: 1,
        duration: b.duration!,
        isPlaying: false,
        position: const Duration(seconds: 30),
      ),
    );
    expect(fired, 0);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('播完当前歌曲：切到倒计时会撤销后端的停止标志', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    expect(backend.stopAfterCurrentTrack, isTrue);

    timer.startCountdown(const Duration(minutes: 1));
    expect(timer.value.mode, SleepTimerMode.countdown);
    expect(backend.stopAfterCurrentTrack, isFalse);

    timer.cancel();
  });

  testWidgets('播完当前歌曲：手动暂停保持武装，恢复后照常到点', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        isPlaying: false,
        position: const Duration(seconds: 10),
      ),
    );
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);

    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 29),
      ),
    );
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: Duration.zero,
      ),
    );
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('播完当前歌曲：单曲循环（曲目未换、位置回跳）→ 暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 29),
      ),
    );
    // 单曲循环重播：曲目没变，位置从曲末回到 0。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: Duration.zero,
      ),
    );
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('播完当前歌曲：队列被清空（停止播放）撤销定时', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    backend.emitFrame(_snapshot(current: null, isPlaying: false));
    expect(timer.value.mode, SleepTimerMode.off);
    expect(fired, 0);
  });

  testWidgets('播完当前歌曲：无真实曲目时开启为无操作', (tester) async {
    backend.emitFrame(_snapshot(isPlaying: false));
    timer.startAfterCurrentTrack();
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('倒计时到点：勾选本曲播完再停 → 曲目播完才暂停', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emitFrame(
      _snapshot(current: a, queue: [a, b], duration: a.duration!),
    );

    timer.setWaitForTrackEnd(true);
    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(minutes: 1));

    expect(fired, 0, reason: '到点后还在等本曲播完，不应立即暂停');
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);
    expect(timer.value.duration, const Duration(minutes: 1));
    expect(backend.stopAfterCurrentTrack, isTrue);

    backend.emitTrackCompletion(a);
    backend.emitFrame(
      _snapshot(
        current: b,
        queue: [a, b],
        currentIndex: 1,
        duration: b.duration!,
        position: Duration.zero,
      ),
    );
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('倒计时到点：等本曲播完 + 退出应用 → 曲末暂停后退出', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emitFrame(
      _snapshot(current: a, queue: [a, b], duration: a.duration!),
    );

    timer.setWaitForTrackEnd(true);
    timer.setExitApp(true);
    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(minutes: 1));

    expect(fired, 0);
    expect(exited, 0);
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);

    backend.emitTrackCompletion(a);
    backend.emitFrame(
      _snapshot(
        current: b,
        queue: [a, b],
        currentIndex: 1,
        duration: b.duration!,
        position: Duration.zero,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );

    expect(fired, 1);
    expect(exited, 1);
    expect(events, ['pause', 'exit']);
  });

  testWidgets('倒计时到点：未勾选等待 → 立即暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.setWaitForTrackEnd(false);
    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(minutes: 1));

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('倒计时到点：无真实曲目时等待勾选退化为立即暂停', (tester) async {
    backend.emitFrame(_snapshot(isPlaying: true));

    timer.setWaitForTrackEnd(true);
    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(minutes: 1));

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('等待阶段取消本曲播完再停 → 立即暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.setWaitForTrackEnd(true);
    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(minutes: 1));
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);
    expect(fired, 0);

    timer.setWaitForTrackEnd(false);
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('等待阶段取消定时 → 不再暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.setWaitForTrackEnd(true);
    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(minutes: 1));
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);

    timer.cancel();
    backend.emitTrackCompletion(a);
    await tester.pump();

    expect(fired, 0);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  test('生产 provider：退出应用 / 本曲播完再停默认勾选（仅本次运行）', () async {
    final playback = buildTestPlaybackProvider(facade: FakePlaybackFacade());
    await playback.preferencesReady;

    expect(playback.sleepTimer.exitApp.value, isTrue);
    expect(playback.sleepTimer.waitForTrackEnd.value, isTrue);
    playback.sleepTimer.setExitApp(false);
    playback.sleepTimer.setWaitForTrackEnd(false);
    expect(playback.sleepTimer.exitApp.value, isFalse);
    expect(playback.sleepTimer.waitForTrackEnd.value, isFalse);

    playback.dispose();
  });

  test('stopLocalPlayback 撤销定时（定时不跨会话保留）', () async {
    final playback = buildTestPlaybackProvider(facade: FakePlaybackFacade());
    await playback.preferencesReady;
    playback.sleepTimer.startCountdown(const Duration(minutes: 30));
    expect(playback.sleepTimer.value.isActive, isTrue);

    await playback.stopLocalPlayback();

    expect(playback.sleepTimer.value.mode, SleepTimerMode.off);
    playback.dispose();
  });

  testWidgets('倒计时：tick 迟到（中途一个 tick 都没跑到）在首个 tick 立即到点', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    // 熄屏 / 后台：真实时间跨过 deadline，但定时器一个 tick 都没被调度到。
    now = now.add(const Duration(minutes: 3));

    await tester.pump(const Duration(seconds: 1));
    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
    expect(backend.calls, contains('pause'));
  });

  testWidgets('倒计时：整段冻结后，非 tick 信号（快照）也补触发', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emitFrame(
      _snapshot(current: a, queue: [a, b], duration: a.duration!),
    );

    timer.startCountdown(const Duration(minutes: 1));
    // 进程被冻结：时钟越过 deadline，期间无 tick；解冻后的第一个快照事件
    // （如自动切歌）就要到点，不等下一次 tick。
    now = now.add(const Duration(minutes: 5));
    backend.emitFrame(
      _snapshot(
        current: b,
        queue: [a, b],
        currentIndex: 1,
        duration: b.duration!,
      ),
    );

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('倒计时：暂停冻结精确到 now（半个 tick 也不漏计）', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(milliseconds: 500));

    // 暂停：剩余 = deadline - now（未到第一个 tick 也精确扣减）。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        isPlaying: false,
        position: const Duration(milliseconds: 500),
      ),
    );
    expect(
      timer.value.remaining,
      const Duration(seconds: 59, milliseconds: 500),
    );

    // 暂停期间不计时。
    await advance(tester, const Duration(hours: 2));
    expect(
      timer.value.remaining,
      const Duration(seconds: 59, milliseconds: 500),
    );
    expect(fired, 0);

    // 恢复播放：按冻结的剩余时长走完即到点。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(milliseconds: 500),
      ),
    );
    await advance(tester, const Duration(seconds: 59, milliseconds: 500));
    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('倒计时：熄屏跨过 deadline，回到前台（resumed）立即补触发', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    final recheck = SleepTimerLifecycleRecheck(timer);
    addTearDown(recheck.detach);
    recheck.attach();

    timer.startCountdown(const Duration(minutes: 1));
    // 熄屏期间冻结：时钟越过 deadline，但没有任何 tick / 快照事件。
    now = now.add(const Duration(minutes: 10));
    expect(fired, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
    expect(backend.calls, contains('pause'));
  });

  testWidgets('倒计时：播放中 deadline 越过而此刻已暂停 → 直接复位', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    now = now.add(const Duration(minutes: 2));

    // 解冻时已经是暂停态（如播放期间被来电打断）：播放时长已耗尽，
    // 定时结束并复位，不留下「恢复播放就立刻暂停」的残定时。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        isPlaying: false,
        position: const Duration(seconds: 40),
      ),
    );

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
    expect(timer.value.remaining, isNull);
  });

  testWidgets('倒计时：重新武装覆盖旧 deadline（不按旧时刻立刻到点）', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(seconds: 30));
    timer.startCountdown(const Duration(minutes: 2));

    // 走到旧 deadline 之后：新定时不受旧时刻影响。
    await advance(tester, const Duration(seconds: 31));
    expect(fired, 0);
    expect(timer.value.remaining, const Duration(minutes: 1, seconds: 29));

    // 走完新时长才到点。
    await advance(tester, const Duration(minutes: 1, seconds: 29));
    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('倒计时：原生定时器随播放/暂停武装与撤销（恢复后按剩余重排）', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    expect(alarm.arms, isNotEmpty);
    expect(alarm.arms.last.$1, const Duration(minutes: 1));
    final firstToken = alarm.arms.last.$2;
    final armedBeforePause = alarm.arms.length;
    await advance(tester, const Duration(seconds: 10));

    // 暂停：撤销原生定时器（避免熄屏时原生到点误暂停）。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        isPlaying: false,
        position: const Duration(seconds: 10),
      ),
    );
    expect(alarm.cancels, greaterThan(0));
    expect(alarm.arms.length, armedBeforePause);

    // 恢复播放：按冻结后的剩余时长重排（token 变化，旧回调失效）。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 10),
      ),
    );
    expect(alarm.arms.length, greaterThan(armedBeforePause));
    expect(alarm.arms.last.$1, lessThanOrEqualTo(const Duration(seconds: 50)));
    expect(alarm.arms.last.$2, isNot(firstToken));

    timer.cancel();
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('wake lock 只在后台持有：前台 arm 不持锁，退后台重排持锁', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    var foreground = true;
    final localAlarm = _FakeSleepTimerAlarm();
    final localTimer = SleepTimerController(
      snapshot: facade.snapshot,
      position: facade.position,
      trackCompletions: facade.trackCompletions,
      setStopAfterCurrentTrack: facade.setStopAfterCurrentTrack,
      alarm: localAlarm,
      isForeground: () => foreground,
      now: () => now,
      onFire: () async {
        fired++;
        await facade.pause();
      },
    );
    addTearDown(localTimer.dispose);

    localTimer.startCountdown(const Duration(minutes: 30));
    expect(localAlarm.arms, isNotEmpty);
    expect(
      localAlarm.arms.last.$3,
      isFalse,
      reason: '屏幕亮着时 Handler 正常调度，不需要 partial wake lock',
    );

    // 息屏 / 切后台：生命周期补检重新 arm，本次必须持锁（显式传当时事实，
    // 不等组合根的策略监听更新）。
    foreground = false;
    localTimer.recheckDeadline(foreground: false);
    expect(localAlarm.arms.last.$3, isTrue);
    expect(
      localAlarm.arms.last.$1,
      lessThanOrEqualTo(const Duration(minutes: 30)),
    );

    // 回到前台：恢复为不持锁。
    foreground = true;
    localTimer.recheckDeadline(foreground: true);
    expect(localAlarm.arms.last.$3, isFalse);

    localTimer.cancel();
  });

  testWidgets('生命周期 onPause 立即按后台重排 wake lock（不等策略先更新）', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    // isForeground 默认恒 true，模拟「策略监听还没跑到」的同一事件栈。
    timer.startCountdown(const Duration(minutes: 30));
    expect(alarm.arms.last.$3, isFalse);

    final recheck = SleepTimerLifecycleRecheck(timer);
    addTearDown(recheck.detach);
    recheck.attach();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(alarm.arms.last.$3, isTrue, reason: '进入后台必须立刻重新 arm 并持锁');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(alarm.arms.last.$3, isFalse);

    timer.cancel();
  });

  testWidgets('倒计时：原生回调到点暂停；过期 token 无效', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    final token = alarm.arms.last.$2;
    // 时钟跨过 deadline 后原生回调：立即暂停并复位。
    now = now.add(const Duration(minutes: 1));
    alarm.fire(token);
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);

    // 过期 token 在已复位状态下不再触发。
    alarm.fire(token);
    await tester.pump();
    expect(fired, 1);
  });

  testWidgets('倒计时：最后 5 秒只启动一次淡出，到点暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(seconds: 8));
    await advance(tester, const Duration(seconds: 3));
    expect(fades, [const Duration(seconds: 5)], reason: '进入 5 秒窗口启动一次淡出');

    await advance(tester, const Duration(seconds: 4));
    expect(fades, hasLength(1), reason: '窗口内不重复启动');
    expect(timer.value.mode, SleepTimerMode.countdown);

    await advance(tester, const Duration(seconds: 1));
    expect(fired, 1);
    expect(fadeCancels, [false], reason: '到点直接落静音（restore=false），暂停不再补第二次淡出');
  });

  testWidgets('倒计时：越过 deadline 的回调立即暂停，不补淡', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(seconds: 10));
    now = now.add(const Duration(seconds: 11));
    timer.recheckDeadline();
    await tester.pump();

    expect(fired, 1);
    expect(fades, isEmpty, reason: '冻结越过后不做 catch-up fade');
  });

  testWidgets('倒计时：冻结后恢复，按真实剩余时间淡出', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(seconds: 10));
    await advance(tester, const Duration(seconds: 3));
    now = now.add(const Duration(seconds: 5));
    timer.recheckDeadline();
    await tester.pump();

    expect(fades, [const Duration(seconds: 2)], reason: '淡出按实际剩余时间');
    await advance(tester, const Duration(seconds: 2));
    expect(fired, 1);
  });

  testWidgets('倒计时：剩余不足可听窗口时直接暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(seconds: 10));
    now = now.add(const Duration(milliseconds: 9800));
    timer.recheckDeadline();
    await tester.pump();
    expect(fades, isEmpty);

    // ticker 在 t0 建表，手动跳时钟后补一次 deadline 判定。
    now = now.add(const Duration(milliseconds: 200));
    timer.recheckDeadline();
    await tester.pump();
    expect(fired, 1);
    expect(fades, isEmpty);
  });

  testWidgets('倒计时：淡出中手动暂停 → 撤销淡出并冻结，恢复后可再次淡出', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(seconds: 6));
    await advance(tester, const Duration(seconds: 2));
    expect(fades, hasLength(1));

    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        isPlaying: false,
      ),
    );
    expect(fadeCancels, [true], reason: '用户暂停撤销淡出、恢复音量');
    expect(fired, 0);
    final frozen = timer.value.remaining;

    await advance(tester, const Duration(seconds: 10));
    expect(fired, 0);
    expect(timer.value.remaining, frozen, reason: '暂停期间冻结');

    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));
    expect(fades, hasLength(2), reason: '恢复后按剩余时间重新淡出');
    await advance(tester, frozen!);
    expect(fired, 1);
  });

  testWidgets('倒计时：淡出中取消 → 恢复音量且不暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(seconds: 6));
    await advance(tester, const Duration(seconds: 2));
    expect(fades, hasLength(1));

    timer.cancel();
    expect(fadeCancels, [true]);
    expect(fired, 0);
    expect(timer.value.mode, SleepTimerMode.off);

    await advance(tester, const Duration(seconds: 20));
    expect(fired, 0);
  });

  testWidgets('倒计时：勾选等本曲播完时，deadline 不淡出，进入等待阶段', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.setWaitForTrackEnd(true);
    timer.startCountdown(const Duration(seconds: 5));
    await advance(tester, const Duration(seconds: 5));

    expect(fades, isEmpty, reason: '还要继续听，不能静音等下一首');
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);

    // 进入等待后，曲末前 3 秒照常启用专用淡出。
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 29),
      ),
    );
    expect(fades, [const Duration(seconds: 1)]);
  });

  testWidgets('播完当前歌曲：位置不新鲜时不用旧进度淡出', (tester) async {
    final a = _track('a', duration: const Duration(seconds: 100));
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    await tester.pump();
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 96),
      ),
    );
    expect(fades, isEmpty, reason: '离曲末还远，不淡出');

    // 时钟前进但位置没再更新：旧位置不再可信。
    now = now.add(const Duration(seconds: 5));
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 96),
      ),
    );
    expect(fades, isEmpty);

    backend.emitTrackCompletion(a);
    await tester.pump();
    expect(fired, 1, reason: '位置不可靠时退回完成事件立即停');
  });

  testWidgets('播完当前歌曲：3 秒淡出中后退 seek → 撤销并等新的曲末', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 28),
      ),
    );
    expect(fades, [const Duration(seconds: 2)]);

    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 5),
      ),
    );
    expect(fadeCancels, [true]);
    expect(fired, 0);
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);
  });

  testWidgets('播完当前歌曲：淡出未完成就收到完成事件 → 撤销并立即暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    backend.emitFrame(
      _snapshot(
        current: a,
        queue: [a],
        duration: a.duration!,
        position: const Duration(seconds: 28),
      ),
    );
    expect(fades, hasLength(1));

    backend.emitTrackCompletion(a);
    await tester.pump();

    expect(fadeCancels, [false], reason: '保持当前电平，让暂停立即落地');
    expect(fired, 1);
  });

  testWidgets('倒计时：原生回调早到（deadline 未到）重新武装，不提前暂停', (tester) async {
    final a = _track('a');
    backend.emitFrame(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    final token = alarm.arms.last.$2;
    final armsBefore = alarm.arms.length;

    // 时钟未动，原生提前回调：不得暂停，按剩余时长重排。
    alarm.fire(token);
    expect(fired, 0);
    expect(alarm.arms.length, greaterThan(armsBefore));
    expect(timer.value.mode, SleepTimerMode.countdown);

    // 收尾取消 ticker，避免挂起的 periodic timer 影响测试清理。
    timer.cancel();
  });
}
