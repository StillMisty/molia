import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/widgets/lyrics_view_session.dart';

/// 手动推进的调度器：替代真实 Timer / post-frame，3 秒窗口可同步断言。
class _ManualScheduler implements LyricsViewScheduler {
  final List<VoidCallback> _frames = [];
  final List<_ManualTimer> _timers = [];
  Duration _now = Duration.zero;

  int get pendingFrameCount => _frames.length;

  @override
  void scheduleFrame(VoidCallback callback) => _frames.add(callback);

  @override
  LyricsTimerHandle startTimer(Duration duration, VoidCallback callback) {
    final timer = _ManualTimer(_now + duration, callback);
    _timers.add(timer);
    return timer;
  }

  /// 执行所有已排队的帧（含执行过程中新排的帧），用于把按帧重试跑到头。
  void runFrames() {
    var rounds = 0;
    while (_frames.isNotEmpty) {
      final batch = List<VoidCallback>.of(_frames);
      _frames.clear();
      for (final callback in batch) {
        callback();
      }
      rounds++;
      if (rounds > 1000) throw StateError('帧回调未收敛');
    }
  }

  /// 推进虚拟时间并按到期顺序执行延迟任务。
  void elapse(Duration duration) {
    final target = _now + duration;
    _timers.removeWhere((timer) => timer.cancelled);
    while (true) {
      _timers.sort((a, b) => a.fireAt.compareTo(b.fireAt));
      final due = _timers
          .where((timer) => !timer.cancelled && timer.fireAt <= target)
          .toList();
      if (due.isEmpty) break;
      final timer = due.first;
      _timers.remove(timer);
      _now = timer.fireAt;
      timer.callback();
      _timers.removeWhere((timer) => timer.cancelled);
    }
    _now = target;
  }
}

class _ManualTimer implements LyricsTimerHandle {
  _ManualTimer(this.fireAt, this.callback);

  final Duration fireAt;
  final VoidCallback callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

/// 记录型宿主：播放事实可变，滚动 / 播放模式 / 触感调用按序记录。
class _RecordingHost implements LyricsViewHost {
  _RecordingHost(this.scheduler);

  @override
  final LyricsViewScheduler scheduler;

  @override
  Duration position = Duration.zero;

  @override
  bool isPlaying = true;

  @override
  List<LyricLine> lines = const [];

  @override
  bool isSynced = true;

  @override
  bool hasTrack = true;

  @override
  bool quickActionsEnabled = true;

  @override
  bool active = true;

  @override
  bool canScroll = true;

  bool scrollSucceeds = true;
  PlayMode playMode = PlayMode.listLoop;

  final List<int> scrollCalls = [];
  final List<int> jumpCalls = [];
  final List<PlayMode> playModeCalls = [];
  int hapticCount = 0;

  void setLyrics({required bool synced, int count = 5}) {
    isSynced = synced;
    lines = [
      for (var i = 0; i < count; i++)
        LyricLine(Duration(seconds: i * 10), '第 $i 行'),
    ];
  }

  @override
  bool scrollToLine(int index) {
    scrollCalls.add(index);
    return scrollSucceeds;
  }

  @override
  void jumpTowardLine(int index) => jumpCalls.add(index);

  @override
  void lightImpact() => hapticCount++;

  @override
  PlayMode get currentPlayMode => playMode;

  @override
  void setPlayMode(PlayMode mode) {
    playMode = mode;
    playModeCalls.add(mode);
  }
}

void main() {
  group('歌词视图会话', () {
    late _ManualScheduler scheduler;
    late _RecordingHost host;
    late LyricsViewSession session;

    setUp(() {
      scheduler = _ManualScheduler();
      host = _RecordingHost(scheduler);
      session = LyricsViewSession(host: host);
    });

    tearDown(() => session.dispose());

    test('手动滚动暂停跟随，静置后按延迟恢复并滚回当前行', () {
      host.setLyrics(synced: true);
      host.position = const Duration(seconds: 21);
      session.resetForLyrics();
      expect(session.following, isTrue);

      session.onUserScrollStarted();
      expect(session.following, isFalse);
      expect(
        session.quickActionsBarVisible,
        isTrue,
        reason: '同步 + 可滚动：手动暂停后操作栏必须可见（居中当前行入口）',
      );

      scheduler.elapse(const Duration(seconds: 2));
      expect(session.following, isFalse, reason: '恢复窗口未到');
      scheduler.elapse(const Duration(seconds: 1));
      expect(session.following, isTrue);
      scheduler.runFrames();
      expect(host.scrollCalls, [2], reason: '恢复后滚回当前行（21s → 第 2 行）');

      session.onUserScrollStarted();
      expect(
        session.following,
        isTrue,
        reason: '恢复后的 350ms 窗口内忽略用户滚动通知（跟随动画自身会发通知）',
      );
      scheduler.elapse(const Duration(milliseconds: 400));
      session.onUserScrollStarted();
      expect(session.following, isFalse);
    });

    test('复制模式禁用跟随并锁定单曲循环，退出恢复原播放模式', () {
      host.setLyrics(synced: true);
      host.playMode = PlayMode.shuffle;
      session.resetForLyrics();

      expect(session.toggleCopyMode(), isTrue);
      expect(session.copyMode, isTrue);
      expect(session.following, isFalse);
      expect(host.playModeCalls, [PlayMode.singleRepeat]);

      expect(session.toggleCopyMode(), isFalse);
      expect(session.copyMode, isFalse);
      expect(session.following, isTrue);
      expect(host.playModeCalls, [PlayMode.singleRepeat, PlayMode.shuffle]);
    });

    test('收起态隐藏操作栏时，复制模式仍保留退出入口', () {
      host.setLyrics(synced: true);
      host.quickActionsEnabled = false;
      session.resetForLyrics();
      expect(session.quickActionsBarVisible, isFalse);

      session.toggleCopyMode();
      expect(
        session.quickActionsBarVisible,
        isTrue,
        reason: '复制模式必须保留出口，否则收起播放器后无法退出',
      );
      session.toggleCopyMode();
      expect(session.quickActionsBarVisible, isFalse);
    });

    test('手动操作栏到点自动收起，手动请求可再次唤出', () {
      host.setLyrics(synced: false);
      session.resetForLyrics();
      expect(session.following, isFalse, reason: '未同步歌词不跟随');
      expect(session.quickActionsBarVisible, isFalse);

      session.onUserScrollActivity();
      expect(session.manualQuickActionsVisible, isTrue);
      expect(session.quickActionsBarVisible, isTrue);

      scheduler.elapse(const Duration(seconds: 2));
      expect(session.manualQuickActionsVisible, isTrue, reason: '停留窗口未到');
      scheduler.elapse(const Duration(seconds: 1));
      expect(session.manualQuickActionsVisible, isFalse);
      expect(session.quickActionsBarVisible, isFalse);

      session.showManualQuickActionsTemporarily();
      expect(session.manualQuickActionsVisible, isTrue);
      scheduler.elapse(const Duration(seconds: 3));
      expect(session.manualQuickActionsVisible, isFalse);
    });

    test('目标行未布局时按帧重试，到达上限后停止', () {
      host.setLyrics(synced: true);
      host.position = const Duration(seconds: 21);
      host.scrollSucceeds = false;
      session.resetForLyrics();

      session.reportLineIndex(2);
      scheduler.runFrames();
      expect(
        host.scrollCalls.length,
        LyricsViewSession.maxPendingScrollRetries + 1,
        reason: '首次尝试 + 8 次按帧重试',
      );
      expect(host.jumpCalls.length, host.scrollCalls.length);
      expect(scheduler.pendingFrameCount, 0, reason: '上限后不再排帧');

      host.scrollSucceeds = true;
      host.position = const Duration(seconds: 31);
      session.reportLineIndex(3);
      scheduler.runFrames();
      expect(host.scrollCalls.last, 3);
      expect(scheduler.pendingFrameCount, 0);
    });

    test('控制器未就绪时不粗定位也不排重试', () {
      host.setLyrics(synced: true);
      host.position = const Duration(seconds: 21);
      host.canScroll = false;
      session.resetForLyrics();

      session.reportLineIndex(2);
      scheduler.runFrames();
      expect(host.scrollCalls, isEmpty);
      expect(host.jumpCalls, isEmpty);
      expect(scheduler.pendingFrameCount, 0);
    });

    test('未同步 / 空歌词不会恢复跟随', () {
      host.setLyrics(synced: false, count: 4);
      session.resetForLyrics();
      expect(session.following, isFalse);
      session.centerCurrentLine();
      expect(host.hapticCount, 1, reason: '居中动作仍有反馈');
      scheduler.runFrames();
      expect(host.scrollCalls, isEmpty);

      host.setLyrics(synced: true, count: 0);
      session.resetForLyrics();
      session.onUserScrollStarted();
      expect(session.following, isFalse);
      scheduler.elapse(const Duration(seconds: 3));
      expect(session.following, isFalse, reason: '空歌词永远没有可跟随目标');

      session.showManualQuickActionsTemporarily();
      expect(session.manualQuickActionsVisible, isFalse);
    });

    test('隐藏页不排滚动，重新可见后按最新行号补一次', () {
      host.setLyrics(synced: true);
      host.position = const Duration(seconds: 11);
      session.resetForLyrics();

      host.active = false;
      session.reportLineIndex(1);
      expect(scheduler.pendingFrameCount, 0);
      expect(host.scrollCalls, isEmpty);

      host.active = true;
      session.onPageBecameActive();
      session.reportLineIndex(1);
      scheduler.runFrames();
      expect(host.scrollCalls, [1]);

      // 帧末回调执行前页面又隐藏：已排队的滚动也必须放弃。
      session.reportLineIndex(3);
      host.active = false;
      scheduler.runFrames();
      expect(host.scrollCalls, [1]);
    });

    test('换源页导航：离页暂停跟随，返回按原状态恢复', () {
      host.setLyrics(synced: true);
      host.position = const Duration(seconds: 11);
      session.resetForLyrics();

      session.suspendFollow();
      expect(session.following, isFalse);
      session.restoreFollow(wasFollowing: true);
      expect(session.following, isTrue);
      scheduler.runFrames();
      expect(host.scrollCalls, [1]);

      session.suspendFollow();
      session.restoreFollow(wasFollowing: false);
      expect(session.following, isFalse);
      scheduler.elapse(const Duration(seconds: 3));
      expect(session.following, isFalse, reason: '换源前没有跟随，不替用户恢复');
    });
  });
}
