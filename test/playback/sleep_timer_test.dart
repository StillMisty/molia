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

    await advance(tester, const Duration(seconds: 10));
    expect(timer.value.remaining, const Duration(seconds: 50));

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

    await advance(tester, const Duration(minutes: 2));
    expect(fired, 0);
  });

  testWidgets('播完当前歌曲：自然播完（切歌前已在曲末）→ 暂停', (tester) async {
    final a = _track('a');
    final b = _track('b');
    backend.emit(_snapshot(current: a, queue: [a, b], duration: a.duration!));

    timer.startAfterCurrentTrack();
    expect(timer.value.mode, SleepTimerMode.afterCurrentTrack);

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
}
