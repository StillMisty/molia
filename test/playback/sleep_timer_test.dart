import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/sleep_timer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

Track _track(String id, {Duration duration = const Duration(seconds: 30)}) =>
    Track(
      id: TrackId('kw', id),
      title: 'Title $id',
      artists: const [Artist(name: 'Artist')],
      duration: duration,
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

BackendSnapshot _snapshot({
  Track? current,
  List<Track> queue = const [],
  int currentIndex = 0,
  bool isPlaying = true,
  Duration position = Duration.zero,
  Duration duration = Duration.zero,
}) =>
    BackendSnapshot(
      current: current,
      queue: queue,
      currentIndex: current == null ? -1 : currentIndex,
      isPlaying: isPlaying,
      position: position,
      duration: duration,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late DefaultPlaybackFacade facade;
  late SleepTimerController timer;
  late DateTime now;
  late int fired;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 1, 1, 22);
    fired = 0;
    backend = FakePlaybackBackend();
    facade = DefaultPlaybackFacade(backend: backend);
    timer = SleepTimerController(
      snapshot: facade.snapshot,
      position: facade.position,
      // 到点动作：与组合根一致（facade.pause），并记录次数便于断言。
      onFire: () async {
        fired++;
        await facade.pause();
      },
      now: () => now,
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
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    expect(timer.value.mode, SleepTimerMode.countdown);
    expect(timer.value.remaining, const Duration(minutes: 1));
    expect(timer.value.duration, const Duration(minutes: 1));

    await advance(tester, const Duration(seconds: 10));
    expect(timer.value.remaining, const Duration(seconds: 50));
    expect(timer.value.duration, const Duration(minutes: 1));

    // 暂停：倒计时冻结（走真实时间也不掉）。
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      isPlaying: false,
      position: const Duration(seconds: 10),
    ));
    await advance(tester, const Duration(minutes: 5));
    expect(timer.value.remaining, const Duration(seconds: 50));
    expect(fired, 0);

    // 恢复播放：继续走完剩余 50 秒。
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      position: const Duration(seconds: 10),
    ));
    await advance(tester, const Duration(seconds: 50));
    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
    expect(timer.value.duration, isNull);
    expect(backend.calls, contains('pause'));
  });

  testWidgets('倒计时：取消后不再触发', (tester) async {
    final a = _track('a');
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(seconds: 10));
    timer.cancel();
    expect(timer.value.mode, SleepTimerMode.off);
    expect(timer.value.remaining, isNull);
    expect(timer.value.duration, isNull);

    await advance(tester, const Duration(minutes: 2));
    expect(fired, 0);
  });

  testWidgets('播完当前歌曲：自然播完（切歌前已在曲末）→ 暂停', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emit(_snapshot(current: a, queue: [a, b], duration: a.duration!));

    timer.startAfterCurrentTrack();
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);
    expect(timer.value.duration, isNull);

    // 播到曲末 → 后端装载下一首（进度通道先对齐到新曲目）。
    backend.emit(_snapshot(
      current: a,
      queue: [a, b],
      duration: a.duration!,
      position: const Duration(seconds: 29),
    ));
    backend.emit(_snapshot(
      current: b,
      queue: [a, b],
      currentIndex: 1,
      duration: b.duration!,
      position: Duration.zero,
    ));
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
    expect(backend.calls, contains('pause'));
  });

  testWidgets('播完当前歌曲：手动切歌跟随新曲目继续等待', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emit(_snapshot(current: a, queue: [a, b], duration: a.duration!));

    timer.startAfterCurrentTrack();
    // 中途手动切歌（远未到曲末）：不暂停，跟随新曲目。
    backend.emit(_snapshot(
      current: b,
      queue: [a, b],
      currentIndex: 1,
      duration: b.duration!,
      position: Duration.zero,
    ));
    expect(fired, 0);
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);

    // 新曲目自然播完（队列末尾：播放停止）→ 无下一首可暂停，撤销定时。
    backend.emit(_snapshot(
      current: b,
      queue: [a, b],
      currentIndex: 1,
      duration: b.duration!,
      isPlaying: false,
      position: const Duration(seconds: 30),
    ));
    expect(fired, 0);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('播完当前歌曲：手动暂停保持武装，恢复后照常到点', (tester) async {
    final a = _track('a');
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      isPlaying: false,
      position: const Duration(seconds: 10),
    ));
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);

    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      position: const Duration(seconds: 29),
    ));
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      position: Duration.zero,
    ));
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('播完当前歌曲：单曲循环（曲目未换、位置回跳）→ 暂停', (tester) async {
    final a = _track('a');
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      position: const Duration(seconds: 29),
    ));
    // 单曲循环重播：曲目没变，位置从曲末回到 0。
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      position: Duration.zero,
    ));
    await tester.pump();

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('播完当前歌曲：队列被清空（停止播放）撤销定时', (tester) async {
    final a = _track('a');
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startAfterCurrentTrack();
    backend.emit(_snapshot(current: null, isPlaying: false));
    expect(timer.value.mode, SleepTimerMode.off);
    expect(fired, 0);
  });

  testWidgets('播完当前歌曲：无真实曲目时开启为无操作', (tester) async {
    backend.emit(_snapshot(isPlaying: false));
    timer.startAfterCurrentTrack();
    expect(timer.value.mode, SleepTimerMode.off);
  });

  test('stopLocalPlayback 撤销定时（定时不跨会话保留）', () async {
    final playback = buildTestPlaybackProvider(backend: FakePlaybackBackend());
    await playback.preferencesReady;
    playback.sleepTimer.startCountdown(const Duration(minutes: 30));
    expect(playback.sleepTimer.value.isActive, isTrue);

    await playback.stopLocalPlayback();

    expect(playback.sleepTimer.value.mode, SleepTimerMode.off);
    playback.dispose();
  });

  testWidgets('倒计时：tick 迟到（中途一个 tick 都没跑到）在首个 tick 立即到点', (tester) async {
    final a = _track('a');
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

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
    backend.emit(_snapshot(current: a, queue: [a, b], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    // 进程被冻结：时钟越过 deadline，期间无 tick；解冻后的第一个快照事件
    // （如自动切歌）就要到点，不等下一次 tick。
    now = now.add(const Duration(minutes: 5));
    backend.emit(_snapshot(
      current: b,
      queue: [a, b],
      currentIndex: 1,
      duration: b.duration!,
    ));

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('倒计时：暂停冻结精确到 now（半个 tick 也不漏计）', (tester) async {
    final a = _track('a');
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    await advance(tester, const Duration(milliseconds: 500));

    // 暂停：剩余 = deadline - now（未到第一个 tick 也精确扣减）。
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      isPlaying: false,
      position: const Duration(milliseconds: 500),
    ));
    expect(
        timer.value.remaining, const Duration(seconds: 59, milliseconds: 500));

    // 暂停期间不计时。
    await advance(tester, const Duration(hours: 2));
    expect(
        timer.value.remaining, const Duration(seconds: 59, milliseconds: 500));
    expect(fired, 0);

    // 恢复播放：按冻结的剩余时长走完即到点。
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      position: const Duration(milliseconds: 500),
    ));
    await advance(tester, const Duration(seconds: 59, milliseconds: 500));
    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
  });

  testWidgets('倒计时：熄屏跨过 deadline，回到前台（resumed）立即补触发', (tester) async {
    final a = _track('a');
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

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
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

    timer.startCountdown(const Duration(minutes: 1));
    now = now.add(const Duration(minutes: 2));

    // 解冻时已经是暂停态（如播放期间被来电打断）：播放时长已耗尽，
    // 定时结束并复位，不留下「恢复播放就立刻暂停」的残定时。
    backend.emit(_snapshot(
      current: a,
      queue: [a],
      duration: a.duration!,
      isPlaying: false,
      position: const Duration(seconds: 40),
    ));

    expect(fired, 1);
    expect(timer.value.mode, SleepTimerMode.off);
    expect(timer.value.remaining, isNull);
  });

  testWidgets('倒计时：重新武装覆盖旧 deadline（不按旧时刻立刻到点）', (tester) async {
    final a = _track('a');
    backend.emit(_snapshot(current: a, queue: [a], duration: a.duration!));

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
}
