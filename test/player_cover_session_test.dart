/// 切歌会话状态机（[CoverSwapSession]）的契约测试。
///
/// 会话与封面堆叠模块之间只有 [CoverSwapHost] 意图接口：这里用记录型假宿主
/// 断言「时机」——阶段迁移、方向判定、对账延后、兜底与两条非视觉路径都能
/// 脱离 widget 树验证（旧实现只能靠 pump deck 观测中间帧）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/services/covers/cover_resolution.dart';
import 'package:molia/widgets/player_cover_session.dart';
import 'package:molia/widgets/player_cover_swap.dart';

import 'support/fake_cover_index.dart';

Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

/// 记录型假宿主：只记录意图调用序列；弹簧是否在动画由测试拨动。
class _RecordingHost implements CoverSwapHost {
  final List<String> calls = [];

  /// 进度弹簧是否在动画（空闲缓存门控与对账延后的输入）。
  bool animating = false;

  void clear() => calls.clear();

  @override
  bool get progressAnimating => animating;

  @override
  void previewProgress(double progress) =>
      calls.add('previewProgress(${progress.toStringAsFixed(2)})');

  @override
  void land({required double progressVelocity}) =>
      calls.add('land(${progressVelocity.toStringAsFixed(2)})');

  @override
  void releasePreview({double progressVelocity = 0}) =>
      calls.add('releasePreview(${progressVelocity.toStringAsFixed(2)})');

  @override
  void startSettle() => calls.add('startSettle');

  @override
  void settleDuringDrag() => calls.add('settleDuringDrag');

  @override
  void settleCommit() => calls.add('settleCommit');

  @override
  void crossfadeCorrection() => calls.add('crossfadeCorrection');

  @override
  void adoptSteadySlots() => calls.add('adoptSteadySlots');

  @override
  void hardReset({Track? adoptTrack}) => calls.add(
      'hardReset(${adoptTrack == null ? '-' : adoptTrack.id.uri})');

  @override
  void requestSkip(int direction) => calls.add('requestSkip($direction)');

  @override
  void notifySwapped(bool duringDrag) =>
      calls.add('notifySwapped($duringDrag)');

  @override
  void armTimeout(Duration duration) =>
      calls.add('armTimeout(${duration.inSeconds}s)');

  @override
  void disarmTimeout() => calls.add('disarmTimeout');
}

void main() {
  final a = _track('a');
  final b = _track('b');
  final c = _track('c');
  final d = _track('d');
  final order = [a, b, c, d];

  /// 按队列下标构造快照（next / previous 与队列一致，与后端语义对齐）。
  PlaybackSnapshot snapshotAt(
    int index, {
    List<Track>? queue,
    PlayMode mode = PlayMode.sequential,
  }) {
    final list = queue ?? order;
    return PlaybackSnapshot(
      current: list[index],
      queue: list,
      currentIndex: index,
      next: index + 1 < list.length ? list[index + 1] : null,
      previous: index > 0 ? list[index - 1] : null,
      isPlaying: true,
      mode: mode,
    );
  }

  late _RecordingHost host;
  late CoverSwapSession session;

  setUp(() {
    host = _RecordingHost();
    session = CoverSwapSession(
      host: host,
      covers: CoverResolver(FakeCoverIndex()),
    );
  });

  tearDown(() => session.dispose());

  /// 建立身份并走完首帧入场动画。
  void settleAt(int index) {
    session.observe(snapshot: snapshotAt(index), displayTrack: order[index]);
    session.progressCompleted();
    expect(session.phase, CoverSwapPhase.idle);
  }

  group('首帧与身份', () {
    test('首次 observe：以展示曲目建立身份、起播入场，落位后回 idle', () {
      final changed = session.observe(
        snapshot: snapshotAt(0),
        displayTrack: a,
      );
      expect(changed, isTrue);
      expect(session.phase, CoverSwapPhase.settling);
      expect(session.to, a);
      expect(session.from, isNull, reason: '无旧曲时只播入场，不产生滑出身份');
      expect(host.calls, ['startSettle', 'disarmTimeout']);

      session.progressCompleted();
      expect(session.phase, CoverSwapPhase.idle);
      expect(session.to, isNull);
      expect(host.calls.last, 'adoptSteadySlots');
    });

    test('adoptInitial：挂载时已有曲目按稳态接管，不播入场', () {
      final adopted = session.adoptInitial(snapshotAt(1));

      expect(adopted, isTrue);
      expect(session.phase, CoverSwapPhase.idle);
      expect(host.calls, isEmpty, reason: '初始身份不是切歌，不产生任何效果意图');
      expect(session.animatedTrackId, b.id.uri);
      expect(session.previous, a, reason: '左槽身份首帧就该是队列里的上一首');

      // 紧接着的首个快照通知只回填空闲缓存，不重新开会话。
      expect(
        session.observe(snapshot: snapshotAt(1), displayTrack: b),
        isFalse,
      );
      expect(session.phase, CoverSwapPhase.idle);
      expect(host.calls, isEmpty);
    });

    test('adoptInitial 后首次真正换曲：仍走入场，滑出身份是初始曲目', () {
      session.adoptInitial(snapshotAt(1));
      host.clear();

      final changed = session.observe(
        snapshot: snapshotAt(2),
        displayTrack: c,
      );

      expect(changed, isTrue);
      expect(session.phase, CoverSwapPhase.settling);
      expect(session.from, b);
      expect(host.calls, ['startSettle', 'disarmTimeout']);
    });

    test('adoptInitial：空快照 / 已有身份时不接管', () {
      expect(session.adoptInitial(PlaybackSnapshot.empty), isFalse);
      expect(session.phase, CoverSwapPhase.idle);

      expect(session.adoptInitial(snapshotAt(1)), isTrue);
      expect(session.adoptInitial(snapshotAt(2)), isFalse,
          reason: '已有身份时后续变化必须走 observe 的切歌路径');
      expect(session.animatedTrackId, b.id.uri);
    });

    test('同 id 的重复通知：不开启新会话，只回填空闲缓存', () {
      settleAt(0);
      host.clear();

      final changed = session.observe(
        snapshot: snapshotAt(0),
        displayTrack: a,
      );
      expect(changed, isFalse);
      expect(session.phase, CoverSwapPhase.idle);
      expect(host.calls, isEmpty, reason: '稳态回填不应产生任何效果意图');
      expect(session.previous, isNull);
    });

    test('current 为 null：身份不改变（清空不播切歌）', () {
      settleAt(1);
      host.clear();

      final changed = session.observe(
        snapshot: PlaybackSnapshot.empty,
        displayTrack: b,
      );
      expect(changed, isFalse);
      expect(session.phase, CoverSwapPhase.idle);
      expect(host.calls, isEmpty);
    });
  });

  group('方向判定', () {
    test('命中「变化前」的上一首提示 → 向后，旧邻位取空闲缓存的下一首', () {
      settleAt(2); // previous = b（提示），next = d
      host.clear();

      session.observe(snapshot: snapshotAt(1), displayTrack: b);
      expect(session.direction, coverSwapBackward);
      expect(session.from, c, reason: '滑出的是变化前的当前曲目');
      expect(session.oldNeighbor, d, reason: '向后入场时让位的是原右侧邻位');
    });

    test('提示都命中不了时按队列下标判定：向后跨位 → 左侧入场', () {
      settleAt(0);
      session.observe(snapshot: snapshotAt(2), displayTrack: c);
      expect(session.direction, coverSwapForward);

      // 从 c 直接点选 a：a 不在提示里，按队列下标（2 → 0）判向后。
      session.progressCompleted();
      settleAt(2);
      session.observe(snapshot: snapshotAt(0), displayTrack: a);
      expect(session.direction, coverSwapBackward);
    });
  });

  group('拖动跟手', () {
    test('首帧进 preview 并写进度；反向拖动换旧邻位；松手回弹', () {
      settleAt(2); // previous = b，lastNext = d
      expect(session.dragStart(), isTrue);

      session.dragUpdate(delta: -20, progress: 0.2);
      expect(session.phase, CoverSwapPhase.preview);
      expect(session.direction, coverSwapForward);
      expect(session.to, d);
      expect(session.from, c);
      expect(session.oldNeighbor, b);
      expect(host.calls.last, 'previewProgress(0.20)');

      session.dragUpdate(delta: 20, progress: 0.2);
      expect(session.direction, coverSwapBackward);
      expect(session.to, b);
      expect(session.oldNeighbor, d, reason: '反向时让位的是原右侧邻位');

      session.releasePreview(progressVelocity: 0.5);
      expect(session.phase, CoverSwapPhase.returning);
      expect(session.to, b, reason: '回退期间保留预览目标（否则目标槽位闪成当前封面）');
      expect(session.showingPreviewTarget, isTrue);
      expect(host.calls, contains('releasePreview(0.50)'));
      expect(host.calls.sublist(host.calls.length - 2),
          ['disarmTimeout', 'releasePreview(0.50)']);

      // 回退弹簧落位（宿主回调）：预览撤下，回 idle。
      session.returnCompleted();
      expect(session.phase, CoverSwapPhase.idle);
      expect(session.to, isNull);
      expect(session.from, isNull);
      expect(host.calls.last, 'adoptSteadySlots');
    });

    test('回退落位只在 returning 生效：阶段被接管后重复回调无副作用', () {
      settleAt(2);
      session.dragStart();
      session.dragUpdate(delta: 20, progress: 0.3);
      host.clear();

      session.releasePreview();
      expect(session.phase, CoverSwapPhase.returning);
      session.returnCompleted();
      expect(host.calls,
          ['disarmTimeout', 'releasePreview(0.00)', 'adoptSteadySlots']);

      // 新会话已接管（这里用切歌入场模拟）时，迟到的回退完成回调必须忽略。
      session.observe(snapshot: snapshotAt(3), displayTrack: d);
      expect(session.phase, CoverSwapPhase.settling);
      host.clear();
      session.returnCompleted();
      expect(session.phase, CoverSwapPhase.settling,
          reason: '非 returning 阶段忽略');
      expect(host.calls, isEmpty);
    });

    test('边界拖动（无预览目标）：不进 preview、不提交', () {
      settleAt(0); // 队首：previous 与 next 都没有可回退/前进的目标？next = b 存在
      // 队首向左滑（上一首）没有目标：不进预览。
      expect(session.dragStart(), isTrue);
      session.dragUpdate(delta: 20, progress: 0.3);
      expect(session.phase, CoverSwapPhase.idle);
      expect(session.previewActive, isFalse);
    });

    test('提交等待期间不接受新手势', () {
      settleAt(2);
      session.dragStart();
      session.dragUpdate(delta: -20, progress: 0.2);
      session.dragEnd();
      session.commit(progressVelocity: -1);
      expect(session.phase, CoverSwapPhase.committed);
      expect(session.dragStart(), isFalse);
    });

    test('跟手帧不逐帧通知；空闲刷新只在左槽身份改变时通知', () {
      settleAt(2);
      var notifications = 0;
      session.addListener(() => notifications++);

      session.dragStart();
      session.dragUpdate(delta: -5, progress: 0.05);
      expect(session.phase, CoverSwapPhase.preview);
      expect(notifications, 1);
      session.dragUpdate(delta: -12, progress: 0.12);
      session.dragUpdate(delta: -30, progress: 0.3);
      expect(notifications, 1, reason: '进度条只走宿主控制器，不该逐帧通知');

      // 回弹收尾到 idle，再验证空闲刷新：同 id 且左槽身份未变 → 静默；
      // 左槽身份（previous 缓存）改变 → 通知一次。
      session.releasePreview();
      session.returnCompleted();
      final int settled = notifications;
      session.observe(snapshot: snapshotAt(2), displayTrack: c);
      expect(notifications, settled);

      session.observe(
        snapshot: snapshotAt(2, queue: [b, d, c]),
        displayTrack: c,
      );
      expect(notifications, settled + 1);
    });
  });

  group('提交与对账', () {
    test('松手达标：续走落位 + 武装 6 秒兜底 + 请求切歌', () {
      settleAt(2);
      session.dragStart();
      session.dragUpdate(delta: -20, progress: 0.2);
      host.clear();

      session.commit(progressVelocity: -1.5);
      expect(session.phase, CoverSwapPhase.committed);
      expect(session.awaitingReconcile, isTrue);
      expect(host.calls, [
        'land(-1.50)',
        'armTimeout(6s)',
        'requestSkip(1)',
      ]);
    });

    test('兜底超时：撤下预览回退（不切歌）', () {
      settleAt(2);
      session.dragStart();
      session.dragUpdate(delta: -20, progress: 0.2);
      session.commit(progressVelocity: -1);
      host.clear();

      session.timeoutFired();
      expect(session.phase, CoverSwapPhase.returning);
      expect(session.showingPreviewTarget, isTrue);
      expect(host.calls, ['disarmTimeout', 'releasePreview(0.00)']);

      session.returnCompleted();
      expect(session.phase, CoverSwapPhase.idle);
      expect(session.to, isNull);
    });

    test('非提交等待期间超时：无副作用', () {
      settleAt(2);
      host.clear();
      session.timeoutFired();
      expect(host.calls, isEmpty);
    });

    test('到位曲目 == 预览目标：无缝落位（settleCommit）', () {
      settleAt(2);
      session.dragStart();
      session.dragUpdate(delta: -20, progress: 0.2);
      session.commit(progressVelocity: -1);
      host.clear();

      session.observe(snapshot: snapshotAt(3), displayTrack: d);
      expect(session.phase, CoverSwapPhase.idle);
      expect(session.to, isNull);
      expect(host.calls, ['disarmTimeout', 'adoptSteadySlots', 'settleCommit']);
    });

    test('到位曲目 != 预览目标：过渡在动画则延后校正，已停则立即校正', () {
      settleAt(2);
      session.dragStart();
      session.dragUpdate(delta: -20, progress: 0.2);
      session.commit(progressVelocity: -1);
      host.clear();
      host.animating = true;

      session.observe(snapshot: snapshotAt(1), displayTrack: b);
      expect(session.phase, CoverSwapPhase.committed, reason: '校正从稳态起步');
      expect(host.calls, ['disarmTimeout']);
      expect(host.calls, isNot(contains('crossfadeCorrection')));

      host.animating = false;
      session.progressCompleted();
      expect(session.phase, CoverSwapPhase.correcting);
      expect(host.calls, containsAllInOrder([
        'adoptSteadySlots',
        'crossfadeCorrection',
      ]));

      session.correctionCompleted();
      expect(session.phase, CoverSwapPhase.idle);
      expect(session.to, isNull);

      // 过渡已停：同一场景不等待 progressCompleted，立即校正。
      settleAt(2);
      session.dragStart();
      session.dragUpdate(delta: -20, progress: 0.2);
      session.commit(progressVelocity: -1);
      host.clear();

      session.observe(snapshot: snapshotAt(1), displayTrack: b);
      expect(session.phase, CoverSwapPhase.correcting);
      expect(host.calls, contains('crossfadeCorrection'));
    });

    test('校正完成只在 correcting 阶段收尾', () {
      settleAt(0);
      session.observe(snapshot: snapshotAt(1), displayTrack: b);
      expect(session.phase, CoverSwapPhase.settling);
      session.correctionCompleted();
      expect(session.phase, CoverSwapPhase.settling, reason: '其它阶段的 completed 忽略');
    });
  });

  group('空闲缓存（唯一写入者）', () {
    test('进度动画进行中不刷新左槽身份与方向提示', () {
      settleAt(1); // previous = a
      expect(session.previous, a);

      // 队列被替换（上一首换人），但弹簧仍在动画：门控拦截，不刷新。
      host.animating = true;
      session.observe(
        snapshot: snapshotAt(1, queue: [d, b, c]),
        displayTrack: b,
      );
      expect(session.previous, a, reason: '动画中不得回填空闲缓存');

      host.animating = false;
      session.observe(
        snapshot: snapshotAt(1, queue: [d, b, c]),
        displayTrack: b,
      );
      expect(session.previous, d, reason: '稳态帧才对齐新身份');
    });

    test('settling 检测帧保留滑出身份（from 不在空闲刷新里被清掉）', () {
      settleAt(0);
      session.observe(snapshot: snapshotAt(1), displayTrack: b);
      expect(session.phase, CoverSwapPhase.settling);
      expect(session.from, a);

      // 同一批快照再通知一次（同 id）：空闲刷新不得清掉滑出身份。
      session.observe(snapshot: snapshotAt(1), displayTrack: b);
      expect(session.from, a);
    });
  });

  group('非视觉路径（可见性与隐藏切歌）', () {
    test('可见性翻转：任一方向都落位到稳态', () {
      settleAt(0);
      host.clear();

      session.setVisible(false);
      expect(session.visible, isFalse);
      expect(session.phase, CoverSwapPhase.idle);
      expect(host.calls, ['disarmTimeout', 'hardReset(-)', 'adoptSteadySlots']);

      host.clear();
      session.setVisible(true);
      expect(host.calls, ['disarmTimeout', 'hardReset(-)', 'adoptSteadySlots']);
    });

    test('不可见时切歌：无动画落位、中心身份接管新曲目、通知父级', () {
      settleAt(0);
      session.setVisible(false);
      host.clear();

      final changed = session.observe(
        snapshot: snapshotAt(1),
        displayTrack: b,
      );
      expect(changed, isTrue);
      expect(session.phase, CoverSwapPhase.idle);
      expect(session.from, isNull);
      expect(session.to, isNull);
      expect(session.animatedTrackId, isNotNull);
      expect(host.calls, [
        'disarmTimeout',
        'hardReset(fake:b)',
        'adoptSteadySlots',
        'notifySwapped(false)',
      ]);
      expect(
        host.calls,
        isNot(contains('startSettle')),
        reason: '隐藏态不播入场动画（回到播放页时锚点必须已是稳态）',
      );
    });
  });
}
