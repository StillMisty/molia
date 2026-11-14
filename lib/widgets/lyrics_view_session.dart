/// 歌词页视图会话（lyrics view session）。
///
/// 收拢歌词页「跟随 / 操作栏 / 复制模式 / 可见性」的协作状态机：自动跟随开关、
/// 手动滚动后的暂停窗口与延迟恢复、目标行未布局时的按帧重试、快捷操作栏的
/// 手动可见窗口、复制模式与播放模式保存 / 恢复，以及隐藏页对滚动工作的门控。
/// 会话只决定「什么时候」，滚动几何（`lyrics_scroll_policy`）、行 key、
/// 控制器与换源 / 选择页导航仍在 widget（宿主）一侧。
///
/// 播放事实经 [LyricsViewHost] 索取：会话不 import `PlaybackProvider`，也不
/// 依赖 Flutter 组件（只依赖 foundation 的 [ChangeNotifier]）。定时窗口同样
/// 由宿主注入（[LyricsViewScheduler]），测试手动推进，不真实等待 3 秒。
///
/// 只在离散状态迁移（跟随 / 复制模式 / 操作栏 / 可滚性）时
/// [LyricsViewSession.notifyListeners]；逐帧播放进度与 350ms 抑制窗口结束
/// 不通知——抑制只影响下一次滚动通知是否被采纳，不改变任何像素。
library;

import 'package:flutter/foundation.dart';

import '../models/lyric_line.dart';
import '../models/play_mode.dart';
import '../services/lyrics_display/lyric_timing_policy.dart';

/// 会话的定时能力。
///
/// 生产实现接真实 `Timer` 与 post-frame；测试注入手动推进的实现，把 3 秒
/// 恢复窗口、3 秒操作栏窗口变成同步断言。
abstract interface class LyricsViewScheduler {
  /// 下一帧回调（目标行未布局时的重试节奏）。
  void scheduleFrame(VoidCallback callback);

  /// 启动延迟任务；调用方只通过返回句柄取消（重复启动前先取消旧的）。
  LyricsTimerHandle startTimer(Duration duration, VoidCallback callback);
}

/// 可取消的延迟任务句柄（不暴露 `Timer`：测试实现无需真实计时器）。
abstract interface class LyricsTimerHandle {
  void cancel();
}

/// 会话时长口径（测试可整体缩短；生产取默认值）。
@immutable
class LyricsViewTiming {
  const LyricsViewTiming({
    this.userScrollResume = const Duration(seconds: 3),
    this.quickActionsHide = const Duration(seconds: 3),
    this.userScrollSuppression = const Duration(milliseconds: 350),
    this.seekSuppression = const Duration(milliseconds: 250),
  });

  /// 手动滚动后恢复自动跟随的静置时长（连续滚动会不断重置）。
  final Duration userScrollResume;

  /// 手动唤出的快捷操作栏停留时长。
  final Duration quickActionsHide;

  /// 开启跟随 / 退出复制模式后忽略用户滚动通知的窗口（跟随动画自身也会
  /// 产生滚动通知，不设窗口会立刻把自己暂停）。
  final Duration userScrollSuppression;

  /// 点行 seek 后恢复跟随的抑制窗口：比常规更短，点行要立即响应。
  final Duration seekSuppression;
}

/// 会话向宿主索取的播放事实与效果。
///
/// 宿主是歌词页 widget（唯一生产实现），测试用记录型假宿主验证调用序列——
/// 会话的时机语义因此可以脱离 widget 树断言。
abstract interface class LyricsViewHost {
  /// 当前播放位置（一次性读取，不建立订阅）。
  Duration get position;

  /// 是否正在播放（恢复跟随是否立刻滚回当前行）。
  bool get isPlaying;

  /// 当前歌词行（空 = 无歌词）。
  List<LyricLine> get lines;

  /// 当前歌词是否有时间轴。
  bool get isSynced;

  /// 是否有当前曲目（无曲目时快捷操作栏隐藏）。
  bool get hasTrack;

  /// 宿主是否允许展示快捷操作栏（播放页收起态才展开）。
  bool get quickActionsEnabled;

  /// 页面当前是否可见（壳层可见且播放页停在歌词 tab）。
  bool get active;

  /// 滚动控制器是否已具备滚动能力（有 clients；几何仍由宿主测量）。
  bool get canScroll;

  /// 精确滚动到指定行。目标行尚未布局时返回 false，会话据此重试。
  bool scrollToLine(int index);

  /// 目标行未布局时的粗定位（按时间戳比例），把目标带进构建范围。
  void jumpTowardLine(int index);

  /// 轻触反馈。
  void lightImpact();

  /// 当前播放模式（进入复制模式前保存）。
  PlayMode get currentPlayMode;

  /// 切换播放模式（复制模式锁定单曲循环 / 退出恢复）。
  void setPlayMode(PlayMode mode);

  /// 会话的定时能力。
  LyricsViewScheduler get scheduler;
}

/// 歌词页视图状态机。
class LyricsViewSession extends ChangeNotifier {
  LyricsViewSession({
    required this.host,
    this.timing = const LyricsViewTiming(),
  });

  /// 目标行未布局时的重试上限：按帧重试，超过后放弃（行号再变化会重新触发）。
  static const int maxPendingScrollRetries = 8;

  final LyricsViewHost host;
  final LyricsViewTiming timing;

  /// 自动跟随（true = 行号变化时滚回当前行）。
  bool _following = true;

  /// 复制模式：禁用自动跟随并锁定单曲循环。
  bool _copyMode = false;

  /// 进入复制模式前的播放模式；退出时恢复（null = 不在复制模式）。
  PlayMode? _previousPlayMode;

  /// 快捷操作栏的手动可见窗口（未同步 / 不可滚动时才有意义）。
  bool _manualQuickActionsVisible = false;

  /// 歌词内容当前是否可滚动（宿主测量后经 [setScrollable] 写入）。
  bool _scrollable = true;

  /// 跟随刚开启的抑制窗口：窗口内的用户滚动通知不暂停跟随。
  bool _suppressUserScroll = false;

  /// 等待精确滚动的目标行（目标未布局时按帧重试）。
  int? _pendingScrollIndex;

  /// 未布局重试次数：始终构建不出来时停止重试，避免每帧空转。
  int _pendingScrollRetries = 0;

  /// 上一次已请求滚动的行号（同一行号且无排队目标时不重复调度）。
  int _previousLineIndex = -1;

  bool _disposed = false;

  LyricsTimerHandle? _suppressionTimer;
  LyricsTimerHandle? _resumeTimer;
  LyricsTimerHandle? _quickActionsHideTimer;

  /// 是否自动跟随当前行。
  bool get following => _following;

  /// 是否处于复制模式。
  bool get copyMode => _copyMode;

  /// 操作栏是否处于手动可见窗口内。
  bool get manualQuickActionsVisible => _manualQuickActionsVisible;

  /// 歌词内容是否可滚动（宿主测量结果）。
  bool get scrollable => _scrollable;

  /// 当前是否有歌词。
  bool get hasLines => host.lines.isNotEmpty;

  /// 当前歌词是否有时间轴。
  bool get isSynced => host.isSynced;

  /// 是否只有在用户手动滚动后才需要展示操作栏：
  /// 未同步歌词没有可跟随目标；同步但内容不可滚动时也只在手动滚动后出现。
  bool get requiresManualQuickActions =>
      hasLines && (!isSynced || !_scrollable);

  /// 快捷操作栏当前是否应展示（FAB 显隐与底栏锚点共用同一口径）。
  bool get quickActionsBarVisible {
    // 复制模式下必须保留出口（否则收起播放器后无法退出复制模式）。
    if (!host.quickActionsEnabled && !_copyMode) return false;
    if (!host.hasTrack) return false;
    if (_copyMode || !hasLines) return true;
    if (isSynced && _scrollable) {
      // 同步 + 可滚动：手动暂停跟随时才需要「居中当前行」。
      return !_following;
    }
    return requiresManualQuickActions && _manualQuickActionsVisible;
  }

  /// 歌词会话内容变化（换曲 / 换词 / 同曲补翻译）后的重置。
  ///
  /// 只重置跟随与滚动簿记；抑制 / 恢复计时器保持原样（与内容无关）。
  void resetForLyrics() {
    if (_disposed) return;
    _cancelHideTimer();
    _following = host.isSynced;
    _previousLineIndex = -1;
    _pendingScrollIndex = null;
    _pendingScrollRetries = 0;
    _manualQuickActionsVisible = false;
    notifyListeners();
  }

  /// 页面重新可见：隐藏期间进度通道被放弃，行号可能已经过期，重置簿记让
  /// 下一次 build 重新请求滚动（否则行号没变就永远不会触发）。
  void onPageBecameActive() {
    _previousLineIndex = -1;
  }

  /// 宿主测量到歌词内容可滚性变化。
  ///
  /// 只在可滚性 / 手动操作栏需求变化时通知；转为「不需要手动唤出」时
  /// 立刻收起手动操作栏（与显隐条件保持一致）。
  void setScrollable(bool canScroll) {
    if (_disposed) return;
    final bool wasRequiresManual = requiresManualQuickActions;
    final bool nextRequiresManual = hasLines && (!isSynced || !canScroll);
    if (_scrollable == canScroll && wasRequiresManual == nextRequiresManual) {
      return;
    }
    _scrollable = canScroll;
    if (!nextRequiresManual) {
      _manualQuickActionsVisible = false;
      _cancelHideTimer();
    }
    notifyListeners();
  }

  /// 开启自动跟随；[suppression] 为忽略用户滚动通知的窗口。
  ///
  /// 未同步歌词没有可跟随目标：只关闭跟随，不排延迟恢复。
  void enableFollow({Duration? suppression}) {
    if (_disposed) return;
    final Duration window = suppression ?? timing.userScrollSuppression;
    // 无论走哪条分支，排队的「延迟恢复」都已不需要。
    _cancelResume();
    if (!isSynced) {
      final bool changed = _following || _suppressUserScroll;
      _following = false;
      _suppressUserScroll = false;
      _cancelSuppressionTimer();
      if (changed) notifyListeners();
      return;
    }
    final bool changed = !_following;
    _following = true;
    _suppressUserScroll = window > Duration.zero;
    _cancelSuppressionTimer();
    if (window > Duration.zero) {
      _suppressionTimer = host.scheduler.startTimer(window, () {
        if (_disposed) return;
        _suppressUserScroll = false;
      });
    }
    if (changed) notifyListeners();
  }

  /// 取消排队的「手动滚动后恢复自动跟随」。
  void cancelResume() {
    _cancelResume();
  }

  /// 「居中当前行」：开启跟随并立即滚回当前行（FAB 动作）。
  void centerCurrentLine() {
    if (_disposed) return;
    host.lightImpact();
    enableFollow();
    _scheduleFrame(() {
      if (!_following) return;
      final int index = _currentLineIndex;
      _scrollToLine(index);
      _previousLineIndex = index;
    });
  }

  /// 用户滚动通知（滚动方向非 idle）：暂停跟随并重置恢复计时。
  ///
  /// 刚开启跟随的抑制窗口内忽略整条通知：跟随自身的平滑滚动也会发通知，
  /// 不忽略会立刻把自己暂停。
  void onUserScrollStarted() {
    if (_disposed || _suppressUserScroll) return;
    if (_following) {
      _following = false;
      _suppressUserScroll = false;
      _cancelSuppressionTimer();
      notifyListeners();
    }
    _scheduleResume();
    if (requiresManualQuickActions) _showManualQuickActions();
  }

  /// 拖拽 / 滚轮 / 惯性滑行（ScrollStart / ScrollUpdate / Overscroll）。
  ///
  /// 即使当前仍在跟随也重置恢复计时：用户停手静置后若已被暂停，计时从
  /// 最后一次滚动动作起算。
  void onUserScrollActivity() {
    if (_disposed) return;
    _scheduleResume();
    if (requiresManualQuickActions) _showManualQuickActions();
  }

  /// 非用户发起的滚动（自动跟随动画 / 用户通知的 idle 回调）。
  ///
  /// 只在「已暂停跟随」时重置恢复计时：暂停期间的惯性滑行同样算用户动作。
  void onAutomaticScrollActivity() {
    if (_disposed || _following) return;
    _scheduleResume();
  }

  /// 手动唤出快捷操作栏（用户滚动时调用）；到点自动收起。
  void showManualQuickActionsTemporarily() {
    _showManualQuickActions();
  }

  /// 切换复制模式；返回切换后是否处于复制模式。
  ///
  /// 进入：保存当前播放模式并锁单曲循环（复制歌词时不错过下一首）；
  /// 退出：恢复保存的模式、恢复跟随并按 350ms 窗口压制滚动通知。
  bool toggleCopyMode() {
    if (_disposed) return _copyMode;
    if (_copyMode) {
      _copyMode = false;
      _following = isSynced;
      // 恢复跟随的滚动动画会发用户滚动通知，先压一个窗口。
      _suppressUserScroll = true;
      _cancelHideTimer();
      _manualQuickActionsVisible = false;
      final PlayMode? previous = _previousPlayMode;
      _previousPlayMode = null;
      if (previous != null) host.setPlayMode(previous);
      _cancelSuppressionTimer();
      if (timing.userScrollSuppression > Duration.zero) {
        _suppressionTimer = host.scheduler.startTimer(
          timing.userScrollSuppression,
          () {
            if (_disposed) return;
            _suppressUserScroll = false;
          },
        );
      }
      _scheduleRevealCurrentLine();
      notifyListeners();
      return false;
    }

    _copyMode = true;
    _following = false;
    _suppressUserScroll = false;
    _cancelSuppressionTimer();
    _cancelResume();
    _cancelHideTimer();
    _previousPlayMode = host.currentPlayMode;
    host.setPlayMode(PlayMode.singleRepeat);
    notifyListeners();
    return true;
  }

  /// 点行 seek 之后的跟随 / 滚动收尾。
  ///
  /// 复制模式退出、手动暂停恢复（短抑制窗口）或已在跟随，都要立即把目标行
  /// 滚到锚点——seek 之后行号可能仍是同一行，不能只靠行号变化触发。
  void revealAfterLineTap(int index) {
    if (_disposed) return;
    if (_copyMode) {
      toggleCopyMode();
    } else if (!_following) {
      enableFollow(suppression: timing.seekSuppression);
    }
    _scheduleFrame(() {
      if (!_following) return;
      _scrollToLine(index);
      _previousLineIndex = index;
    });
  }

  /// 打开换源 / 选择页面前暂停跟随（离页期间不跑滚动工作）。
  void suspendFollow() {
    if (_disposed) return;
    _cancelResume();
    if (!_following) return;
    _following = false;
    _suppressUserScroll = false;
    _cancelSuppressionTimer();
    notifyListeners();
  }

  /// 换源页返回新歌词后的跟随恢复。
  ///
  /// [restoreFollow] 是打开页面前的跟随状态：换源前跟随就按 350ms 窗口
  /// 恢复并滚回当前行；否则保持暂停（新歌词不替用户做决定）。
  void adoptReplacementLyrics({required bool restoreFollow}) {
    if (_disposed) return;
    _cancelHideTimer();
    _manualQuickActionsVisible = false;
    _previousLineIndex = -1;
    if (restoreFollow && isSynced) {
      _following = true;
      _suppressUserScroll = true;
      _cancelSuppressionTimer();
      if (timing.userScrollSuppression > Duration.zero) {
        _suppressionTimer = host.scheduler.startTimer(
          timing.userScrollSuppression,
          () {
            if (_disposed) return;
            _suppressUserScroll = false;
          },
        );
      }
      _scheduleRevealCurrentLine();
    } else {
      _following = false;
      _suppressUserScroll = false;
      _cancelSuppressionTimer();
    }
    notifyListeners();
  }

  /// 换源 / 选择页取消或未返回歌词：按打开前的状态恢复跟随。
  void restoreFollow({required bool wasFollowing}) {
    if (_disposed || !wasFollowing || _following) return;
    enableFollow();
    _scheduleRevealCurrentLine();
  }

  /// 页面返回后若仍处于手动暂停，继续排延迟恢复。
  void scheduleResumeIfPaused() {
    if (_disposed || _following) return;
    _scheduleResume();
  }

  /// 宿主 build 时报告当前行号：行号变化（或仍有排队目标）时请求滚动。
  ///
  /// 隐藏页 / 未跟随 / 无歌词 / 无当前行都不调度；帧末回调再做一次门控。
  void reportLineIndex(int index) {
    if (_disposed || !host.active || !_following || !hasLines || index < 0) {
      return;
    }
    if (_previousLineIndex == index && _pendingScrollIndex == null) return;
    _previousLineIndex = index;
    _pendingScrollIndex = index;
    _scheduleFrame(() {
      if (!host.active || !_following || _pendingScrollIndex != index) return;
      _scrollToLine(index);
    });
  }

  /// 执行一次目标行滚动；目标未布局时粗定位并按帧重试（上限后放弃）。
  void _scrollToLine(int index) {
    if (_disposed || !host.active || !_following || !isSynced) return;
    if (!host.canScroll || index < 0 || index >= host.lines.length) return;
    if (host.scrollToLine(index)) {
      _pendingScrollIndex = null;
      _pendingScrollRetries = 0;
      return;
    }
    _pendingScrollIndex = index;
    host.jumpTowardLine(index);
    if (_pendingScrollRetries < maxPendingScrollRetries) {
      _pendingScrollRetries++;
      _scheduleFrame(() {
        if (!host.active || !_following || _pendingScrollIndex != index) return;
        _scrollToLine(index);
      });
    }
  }

  int get _currentLineIndex => LyricTimingPolicy.page.lineIndexAt(
    host.lines,
    host.position,
    isSynced: host.isSynced,
  );

  void _scheduleRevealCurrentLine() {
    _scheduleFrame(() {
      if (!_following) return;
      final int index = _currentLineIndex;
      if (index < 0) return;
      _scrollToLine(index);
      _previousLineIndex = index;
    });
  }

  /// 手动滚动后延迟恢复自动跟随：连续滚动不断重置，停手静置后滚回当前行。
  ///
  /// 复制模式刻意禁用自动滚动、无时间戳 / 空歌词没有可跟随目标：都不排恢复。
  void _scheduleResume() {
    if (_copyMode || !isSynced || !hasLines) return;
    _cancelResume();
    _resumeTimer = host.scheduler.startTimer(timing.userScrollResume, () {
      _resumeTimer = null;
      _resumeAfterUserScroll();
    });
  }

  void _resumeAfterUserScroll() {
    if (_disposed || _copyMode || !isSynced || _following || !hasLines) return;
    enableFollow();
    if (!host.isPlaying) {
      // 暂停中：只恢复跟随状态，不把视图从用户停留处拽回；
      // 恢复播放后行号变化会自然滚回当前行。
      return;
    }
    _scheduleRevealCurrentLine();
  }

  void _showManualQuickActions() {
    if (_disposed || !requiresManualQuickActions || _copyMode || !hasLines) {
      return;
    }
    if (!_manualQuickActionsVisible) {
      _manualQuickActionsVisible = true;
      notifyListeners();
    }
    _cancelHideTimer();
    _quickActionsHideTimer = host.scheduler.startTimer(
      timing.quickActionsHide,
      () {
        if (_disposed ||
            !requiresManualQuickActions ||
            _copyMode ||
            !hasLines) {
          return;
        }
        if (!_manualQuickActionsVisible) return;
        _manualQuickActionsVisible = false;
        notifyListeners();
      },
    );
  }

  void _cancelSuppressionTimer() {
    _suppressionTimer?.cancel();
    _suppressionTimer = null;
  }

  void _cancelResume() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  void _cancelHideTimer() {
    _quickActionsHideTimer?.cancel();
    _quickActionsHideTimer = null;
  }

  void _scheduleFrame(VoidCallback callback) {
    host.scheduler.scheduleFrame(() {
      if (_disposed) return;
      callback();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelSuppressionTimer();
    _cancelResume();
    _cancelHideTimer();
    super.dispose();
  }
}
