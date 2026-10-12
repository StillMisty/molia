import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../domain/models/track.dart';
import '../models/lyric_line.dart';
import '../models/play_mode.dart';
import '../pages/source_swap_page.dart';
import '../providers/lyrics_provider.dart';
import '../providers/playback_provider.dart';
import '../services/lyrics_display/lyrics_display_settings.dart';
import '../services/notification_service.dart';
import '../utils/responsive.dart';
import 'lyric_karaoke_text.dart';
import 'lyrics_selection_page.dart';
import 'lyrics_source_search_view.dart';
import 'playback_selectors.dart';

class LyricsWidget extends StatefulWidget {
  const LyricsWidget({
    super.key,
    this.quickActionsEnabled = true,
    this.controller,
  });

  /// 是否显示歌词快捷操作栏：播放页收起态（歌词区展开）传 true；
  /// 展开态操作栏会与底部控制区重叠，传 false 隐藏。
  final bool quickActionsEnabled;

  /// 外部滚动控制器：宿主用来判断歌词是否已滚到顶部（「到顶继续下拉」
  /// 切换播放器）。为空时自建并自行释放。
  final ScrollController? controller;

  @override
  State<LyricsWidget> createState() => _LyricsWidgetState();
}

class _LyricsWidgetState extends State<LyricsWidget>
    with
        AutomaticKeepAliveClientMixin<LyricsWidget>,
        SingleTickerProviderStateMixin {
  /// 手动滚动后恢复自动跟随的延迟：太短会打断读词，太长像「不跟了」。
  static const Duration _userScrollResumeDelay = Duration(seconds: 3);

  /// 快捷操作栏：M3EToolbar 浮动胶囊的屏边距（工具栏默认 screenOffset）。
  static const double _quickActionsScreenOffset = 16;

  /// 快捷操作栏胶囊高度：M3EToolbar.containerSize。
  static const double _quickActionsContainerSize =
      M3EToolbarTokens.containerSize;

  /// 激活行锚点相对「可见区域中线」的上移比例（占视口高度）。
  ///
  /// 顶栏（顶部渐隐带 + 圆点带）比底栏高，只按可见区域居中会让激活行
  /// 视觉偏下；上移一点后上下留白更平衡，也接近主流歌词页的中上排版。
  static const double _activeLineUpwardBias = 0.10;

  List<LyricLine> _lyrics = [];

  /// 歌词会话模块（同一份状态源）：监听外部替换（换源页手动保存）以同步展示。
  LyricsProvider? _lyricsProvider;

  /// 与 [_lyrics] 等索引的翻译 / 罗马音（'' = 该行无扩展文本）。
  /// 来自 [LyricsState] 的同一份时间戳对齐结果，与各输出共用数据源。
  List<String> _translations = const [];
  List<String> _romas = const [];
  String? _lastTrackId;
  late final ScrollController _scrollController =
      widget.controller ?? ScrollController();
  final GlobalKey _listViewKey = GlobalKey();
  bool _autoScroll = true;
  bool _isCopyLyricsMode = false;
  PlayMode? _previousPlayMode;
  int _previousLineIndex = -1;
  final List<GlobalKey> _lineKeys = [];
  int? _pendingScrollIndex;
  int? _lastFallbackIndexAttempted;
  int _fallbackAttemptsForCurrentIndex = 0;
  int? _currentTrackDurationMs;
  bool _temporarilyIgnoreUserScroll = false;
  Timer? _userScrollSuppressionTimer;

  /// 用户手动滚动后延迟恢复自动跟随的计时器（连续滚动会不断重置）。
  Timer? _userScrollResumeTimer;
  Timer? _quickActionsHideTimer;
  bool _manualQuickActionsVisible = false;
  bool _lyricsContentScrollable = true;
  bool _scrollabilityCheckScheduled = false;
  bool _lyricsAreSynced = true;
  bool _isLyricsLoading = false;

  /// 快捷操作栏显隐弹簧：0 = 完全隐藏、1 = 完全展开。
  ///
  /// 直接用 motor（M3E 包内部同一驱动）：`MaterialSpringMotion.expressiveSpatialFast`
  /// 就是 expressive 的 fast spatial token（800 / 0.6，与
  /// [M3EMotion.expressiveSpatialFast] 一致）；`snapToEnd` 让弹簧落定精确吸附目标，
  /// 省掉容差收尾补丁。透明度同源并截断到 0..1（M3E 规范：effects 不过冲）。
  late final SingleMotionController _quickActionsMotion;

  /// 快捷操作栏当前目标（true = 展开）；只在变化时起弹簧。
  bool _quickActionsExpanded = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    setState(() {
      _autoScroll = true;
    });
    // 快捷操作栏初始态与宿主传入的可见性一致（收起态歌词区才展开操作栏）。
    _quickActionsExpanded = widget.quickActionsEnabled;
    _quickActionsMotion = SingleMotionController(
      motion: const MaterialSpringMotion.expressiveSpatialFast(snapToEnd: true),
      vsync: this,
      initialValue: _quickActionsExpanded ? 1 : 0,
    );
    // 能取到当前曲目就立即加载歌词
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadLyrics();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<LyricsProvider>(context, listen: false);
    if (identical(provider, _lyricsProvider)) return;
    _lyricsProvider?.removeListener(_onLyricsProviderChanged);
    _lyricsProvider = provider;
    provider.addListener(_onLyricsProviderChanged);
  }

  /// 同一曲目的歌词被外部替换（换源页手动保存等）时同步到本地渲染状态。
  ///
  /// 与本地一致（自己发起加载的落地路径）时直接跳过，避免无谓 setState。
  void _onLyricsProviderChanged() {
    final provider = _lyricsProvider;
    if (!mounted || provider == null) return;
    final trackId = _lastTrackId;
    if (trackId == null) return;
    final state = provider.state;
    if (state.trackId != trackId || state.status != LyricsStatus.ready) return;
    if (listEquals(state.lines, _lyrics) &&
        listEquals(state.translations, _translations) &&
        listEquals(state.romas, _romas)) {
      return;
    }
    _quickActionsHideTimer?.cancel();
    setState(() {
      _lyricsAreSynced = state.isSynced;
      _lyrics = state.lines;
      _translations = state.translations;
      _romas = state.romas;
      _autoScroll = state.isSynced;
      _previousLineIndex = -1;
      _syncLineKeys(_lyrics.length);
      _pendingScrollIndex = null;
      _lastFallbackIndexAttempted = null;
      _fallbackAttemptsForCurrentIndex = 0;
      _manualQuickActionsVisible = false;
      _isLyricsLoading = false;
    });
  }

  @override
  void dispose() {
    _lyricsProvider?.removeListener(_onLyricsProviderChanged);
    _userScrollSuppressionTimer?.cancel();
    _userScrollResumeTimer?.cancel();
    _quickActionsHideTimer?.cancel();
    _quickActionsMotion.dispose();
    // 外部控制器由宿主释放。
    if (widget.controller == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  Future<void> _loadLyrics() async {
    if (!mounted) return;

    // 换曲/清空时取消待恢复的自动跟随（下方状态复位会重新建立）。
    _cancelUserScrollResume();

    final provider = Provider.of<PlaybackProvider>(context, listen: false);
    final lyricsProvider =
        Provider.of<LyricsProvider>(context, listen: false);
    final currentTrack = provider.snapshot.current;
    if (currentTrack == null) {
      lyricsProvider.reset();
      // 无曲目：清空歌词并复位状态
      if (_lyrics.isNotEmpty || _lastTrackId != null) {
        _quickActionsHideTimer?.cancel();
        setState(() {
          _lyrics = [];
          _translations = const [];
          _romas = const [];
          _lastTrackId = null;
          _autoScroll = true;
          _previousLineIndex = -1;
          _syncLineKeys(0);
          _currentTrackDurationMs = null;
          _lyricsAreSynced = true;
          _manualQuickActionsVisible = false;
        });
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      }
      return;
    }

    final trackId = currentTrack.id.uri;
    final trackDurationMs = currentTrack.duration?.inMilliseconds;
    // 仅当曲目 id 有效且变化时重新加载
    if (trackId.isEmpty || trackId == _lastTrackId) return;

    _lastTrackId = trackId;

    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _quickActionsHideTimer?.cancel();
    setState(() {
      _lyrics = [];
      _translations = const [];
      _romas = const [];
      _autoScroll = true;
      _previousLineIndex = -1;
      _syncLineKeys(0);
      _currentTrackDurationMs = trackDurationMs;
      _lyricsAreSynced = true;
      _manualQuickActionsVisible = false;
      _isLyricsLoading = true;
    });

    // 取词/缓存/解析统一走歌词会话模块；此处只把结果落到本地渲染状态。
    await lyricsProvider.load(currentTrack);

    if (!mounted) return;

    final latestTrackId = Provider.of<PlaybackProvider>(context, listen: false)
        .snapshot.current?.id.uri;
    // 更新状态前确认歌词仍属于当前曲目
    if (latestTrackId != trackId) {
      return;
    }

    final lyricsState = lyricsProvider.state;
    if (lyricsState.trackId != trackId ||
        lyricsState.status == LyricsStatus.loading) {
      return; // 另一轮加载已接管
    }

    if (lyricsState.status == LyricsStatus.ready) {
      final synced = lyricsState.isSynced;
      _quickActionsHideTimer?.cancel();
      setState(() {
        _lyricsAreSynced = synced;
        _lyrics = lyricsState.lines;
        _translations = lyricsState.translations;
        _romas = lyricsState.romas;
        _autoScroll = synced;
        _previousLineIndex = -1;
        _syncLineKeys(_lyrics.length);
        _currentTrackDurationMs = trackDurationMs;
        _pendingScrollIndex = null;
        _lastFallbackIndexAttempted = null;
        _fallbackAttemptsForCurrentIndex = 0;
        _manualQuickActionsVisible = false;
        _isLyricsLoading = false;
      });
      // 下一首歌词预载在组合根统一处理（不依赖本组件是否挂载）。
    } else {
      // 取词失败 / 空歌词：保持空歌词列表
      _quickActionsHideTimer?.cancel();
      setState(() {
        _lyrics = [];
        _translations = const [];
        _romas = const [];
        _syncLineKeys(0);
        _lyricsAreSynced = true;
        _manualQuickActionsVisible = false;
        _isLyricsLoading = false;
      });
    }
  }

  void _syncLineKeys(int targetLength) {
    if (_lineKeys.length == targetLength) return;
    if (_lineKeys.length < targetLength) {
      final difference = targetLength - _lineKeys.length;
      for (int i = 0; i < difference; i++) {
        _lineKeys.add(GlobalKey());
      }
    } else {
      _lineKeys.removeRange(targetLength, _lineKeys.length);
    }
  }

  String _extractArtistNames(Track track) {
    final names = track.artists
        .map((artist) => artist.name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (names.isNotEmpty) {
      return names.join(', ');
    }
    return 'Unknown Artist';
  }

  bool get _requiresManualQuickActions =>
      _lyrics.isNotEmpty && (!_lyricsAreSynced || !_lyricsContentScrollable);

  bool get _shouldShowQuickActionsBar {
    // 复制模式下必须保留出口（否则收起播放器后无法退出复制模式）。
    if (!widget.quickActionsEnabled && !_isCopyLyricsMode) {
      return false;
    }
    if (_isCopyLyricsMode || _lyrics.isEmpty) {
      return true;
    }
    if (_lyricsAreSynced && _lyricsContentScrollable) {
      return !_autoScroll;
    }
    return _requiresManualQuickActions && _manualQuickActionsVisible;
  }

  void _scheduleScrollabilityCheck() {
    if (_scrollabilityCheckScheduled) {
      return;
    }
    _scrollabilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollabilityCheckScheduled = false;
      if (!mounted) {
        return;
      }
      if (!_scrollController.hasClients) {
        _scheduleScrollabilityCheck();
        return;
      }
      final position = _scrollController.position;
      final bool canScroll =
          (position.maxScrollExtent - position.minScrollExtent).abs() > 1.0;
      final bool nextRequiresManual =
          _lyrics.isNotEmpty && (!_lyricsAreSynced || !canScroll);
      final bool manualRequirementChanged =
          _requiresManualQuickActions != nextRequiresManual;
      if (_lyricsContentScrollable != canScroll || manualRequirementChanged) {
        setState(() {
          _lyricsContentScrollable = canScroll;
          if (!nextRequiresManual) {
            _manualQuickActionsVisible = false;
            _quickActionsHideTimer?.cancel();
          }
        });
      }
    });
  }

  void _showManualQuickActionsTemporarily() {
    if (!mounted ||
        !_requiresManualQuickActions ||
        _isCopyLyricsMode ||
        _lyrics.isEmpty) {
      return;
    }
    if (!_manualQuickActionsVisible) {
      setState(() {
        _manualQuickActionsVisible = true;
      });
    }
    _quickActionsHideTimer?.cancel();
    _quickActionsHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted ||
          !_requiresManualQuickActions ||
          _isCopyLyricsMode ||
          _lyrics.isEmpty) {
        return;
      }
      if (_manualQuickActionsVisible) {
        setState(() {
          _manualQuickActionsVisible = false;
        });
      }
    });
  }

  /// 激活行锚点：可见区域（去掉顶部渐隐带/底栏）的纵向中线，再整体上移
  /// `_activeLineUpwardBias` 个视口高度（顶栏比底栏高，居中会视觉偏下）。
  double _computeEffectiveAlignment() {
    if (!_scrollController.hasClients) {
      return 0.5 - _activeLineUpwardBias;
    }

    final mediaQuery = MediaQuery.of(context);
    final double viewport = _scrollController.position.viewportDimension;
    if (viewport <= 0) return 0.5 - _activeLineUpwardBias;

    final double topOverlay = 40.0 + mediaQuery.padding.top;

    final bool bottomBarVisible = _shouldShowQuickActionsBar;
    // 快捷操作栏（M3EToolbar 浮动胶囊）从内容底边算起的遮挡高度：
    // 屏边距（胶囊下沿）+ 胶囊高度 + 底部安全区。
    final double bottomOverlay = bottomBarVisible
        ? (mediaQuery.padding.bottom +
            _quickActionsScreenOffset +
            _quickActionsContainerSize)
        : 0.0;

    final double visibleCenter =
        (topOverlay + (viewport - bottomOverlay)) / 2.0;
    final double anchor = visibleCenter - viewport * _activeLineUpwardBias;
    return (anchor / viewport).clamp(0.0, 1.0);
  }

  double _tailSpace() {
    if (!_scrollController.hasClients) return 400.0;

    final mediaQuery = MediaQuery.of(context);
    final position = _scrollController.position;
    if (!position.hasPixels || position.viewportDimension <= 0) {
      return 400.0;
    }
    final double viewport = position.viewportDimension;

    final double topOverlay = 40.0 + mediaQuery.padding.top;

    final bool bottomBarVisible = _shouldShowQuickActionsBar;
    final double bottomOverlay = bottomBarVisible
        ? (mediaQuery.padding.bottom +
            _quickActionsScreenOffset +
            _quickActionsContainerSize)
        : 0.0;

    final double visibleHeight =
        (viewport - topOverlay - bottomOverlay).clamp(0.0, viewport);
    // 尾部留白按激活行锚点（可见区域中线再上移）反推，保证最后一行
    // 也能滚到锚点位置。
    return (visibleHeight / 2.0) +
        bottomOverlay +
        viewport * _activeLineUpwardBias +
        8.0;
  }

  /// 快捷操作栏显隐：条件变化才起弹簧（建期调用安全，弹簧在下一帧才改值）。
  ///
  /// [SingleMotionController.animateTo] 自动携带当前速度续跑（中途反向不跳变）。
  void _syncQuickActions(bool show) {
    if (_quickActionsExpanded == show) return;
    _quickActionsExpanded = show;
    _quickActionsMotion.animateTo(show ? 1.0 : 0.0);
  }

  /// 居中/恢复跟随：开启自动跟随并立即滚回当前行。
  void _centerCurrentLine() {
    HapticFeedback.lightImpact();
    if (!mounted) return;
    _enableAutoScrollWithSuppression();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _autoScroll) {
        final provider = Provider.of<PlaybackProvider>(context, listen: false);
        final latestCurrentIndex =
            _getCurrentLineIndex(provider.currentPosition);
        _scrollToCurrentLine(latestCurrentIndex);
        _previousLineIndex = latestCurrentIndex;
      }
    });
  }

  /// 快捷操作栏按钮：交给 [M3EToolbar] 统一呈现
  /// （禁用 / 选中高亮 / tooltip 走工具栏语义）。
  List<M3EToolbarItem> _buildQuickActions(AppLocalizations l10n) {
    final bool hasLyrics = _lyrics.isNotEmpty;
    return <M3EToolbarItem>[
      // 居中/恢复跟随：仅「手动滚动暂停 + 有同步歌词」时入列。
      if (!_autoScroll && hasLyrics && _lyricsAreSynced)
        M3EToolbarAction(
          icon: Icons.vertical_align_center_rounded,
          onPressed: _centerCurrentLine,
          tooltip: l10n.centerCurrentLine,
        ),
      M3EToolbarAction(
        icon: _isCopyLyricsMode
            ? Icons.playlist_play_rounded
            : Icons.edit_note_rounded,
        enabled: hasLyrics,
        // 复制模式 = 工具栏选中态（tonal 高亮），颜色交给工具栏。
        active: _isCopyLyricsMode,
        onPressed: () {
          HapticFeedback.lightImpact();
          _toggleCopyLyricsMode();
        },
        tooltip: _isCopyLyricsMode
            ? l10n.exitCopyModeResumeScroll
            : l10n.enterCopyLyricsMode,
      ),
      M3EToolbarAction(
        icon: Icons.swap_horiz_rounded,
        onPressed: _showSourceSwapPage,
        tooltip: l10n.sourceSwap,
      ),
      M3EToolbarAction(
        icon: Icons.checklist_rounded,
        enabled: hasLyrics,
        onPressed: _showLyricsSelectionPage,
        tooltip: l10n.selectLyricsTooltip,
      ),
    ];
  }

  void _scrollToCurrentLine(int currentLineIndex) {
    if (!mounted ||
        !_autoScroll ||
        !_lyricsAreSynced ||
        !_scrollController.hasClients ||
        currentLineIndex < 0 ||
        currentLineIndex >= _lineKeys.length) {
      return;
    }

    final key = _lineKeys[currentLineIndex];
    final context = key.currentContext;
    if (context == null) {
      if (_lastFallbackIndexAttempted != currentLineIndex) {
        _fallbackAttemptsForCurrentIndex = 0;
      }
      _pendingScrollIndex = currentLineIndex;
      _lastFallbackIndexAttempted = currentLineIndex;
      _fallbackAttemptsForCurrentIndex++;

      final position = _scrollController.position;
      if (position.hasPixels &&
          position.hasContentDimensions &&
          position.viewportDimension > 0 &&
          _lyrics.isNotEmpty) {
        final line = _lyrics[currentLineIndex];
        double ratio;
        if (_currentTrackDurationMs != null &&
            _currentTrackDurationMs! > 0 &&
            line.timestamp.inMilliseconds >= 0) {
          final double totalMs = _currentTrackDurationMs!.toDouble();
          ratio = line.timestamp.inMilliseconds / totalMs;
        } else if (_lyrics.length <= 1) {
          ratio = 0.0;
        } else {
          ratio = currentLineIndex / (_lyrics.length - 1);
        }

        if (!ratio.isFinite) {
          ratio = 0.0;
        } else if (ratio < 0.0) {
          ratio = 0.0;
        } else if (ratio > 1.0) {
          ratio = 1.0;
        }

        final double alignment = _computeEffectiveAlignment();
        final double viewportDim = position.viewportDimension;
        final double viewportHalf = viewportDim * 0.5;
        double targetOffset =
            (ratio * position.maxScrollExtent) - (viewportDim * alignment);

        if (_fallbackAttemptsForCurrentIndex > 1) {
          final double direction =
              (targetOffset >= position.pixels) ? 1.0 : -1.0;
          final double fallbackMagnitude =
              (_fallbackAttemptsForCurrentIndex - 1).clamp(1, 4).toDouble();
          final double extraOffset = viewportHalf * 0.6 * fallbackMagnitude;
          targetOffset += direction * extraOffset;
        }

        if (targetOffset < position.minScrollExtent) {
          targetOffset = position.minScrollExtent;
        } else if (targetOffset > position.maxScrollExtent) {
          targetOffset = position.maxScrollExtent;
        }

        try {
          if ((position.pixels - targetOffset).abs() > 1.0) {
            _scrollController.jumpTo(targetOffset);
          }
        } catch (_) {
          // 跳转失败可忽略：下一帧会重试
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _autoScroll && _pendingScrollIndex == currentLineIndex) {
          _scrollToCurrentLine(currentLineIndex);
        }
      });
      return;
    }

    _pendingScrollIndex = null;
    _lastFallbackIndexAttempted = null;
    _fallbackAttemptsForCurrentIndex = 0;

    try {
      final renderObject = context.findRenderObject();
      if (renderObject == null) return;

      final viewport = RenderAbstractViewport.of(renderObject);
      final double alignment = _computeEffectiveAlignment();
      final reveal = viewport.getOffsetToReveal(renderObject, alignment);
      final position = _scrollController.position;
      final targetOffset = reveal.offset;
      final clampedOffset = targetOffset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );

      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 600),
        curve: Curves.fastOutSlowIn,
      );
    } catch (_) {
      // 滚动失败可忽略：下一 tick 会重试
    }
  }

  void _enableAutoScrollWithSuppression(
      {Duration duration = const Duration(milliseconds: 350)}) {
    if (!mounted) {
      return;
    }
    // 无论走哪条分支，排队的「延迟恢复」都已不需要。
    _cancelUserScrollResume();
    if (!_lyricsAreSynced) {
      setState(() {
        _autoScroll = false;
        _temporarilyIgnoreUserScroll = false;
      });
      return;
    }
    setState(() {
      _autoScroll = true;
      _temporarilyIgnoreUserScroll = duration > Duration.zero;
    });
    _userScrollSuppressionTimer?.cancel();
    if (duration > Duration.zero) {
      _userScrollSuppressionTimer = Timer(duration, () {
        if (!mounted) return;
        setState(() {
          _temporarilyIgnoreUserScroll = false;
        });
      });
    }
  }

  /// 取消排队的「手动滚动后恢复自动跟随」。
  void _cancelUserScrollResume() {
    _userScrollResumeTimer?.cancel();
    _userScrollResumeTimer = null;
  }

  /// 用户手动滚动后延迟恢复自动跟随。
  ///
  /// 手动滚动只暂停跟随：连续滚动会不断重置计时，停手静置
  /// [_userScrollResumeDelay] 后自动滚回当前行，避免「看过一次就再也不跟」。
  /// 复制模式刻意禁用自动滚动、无时间戳歌词没有可跟随目标，两者都不恢复。
  void _scheduleUserScrollResume() {
    if (_isCopyLyricsMode || !_lyricsAreSynced || _lyrics.isEmpty) {
      return;
    }
    _userScrollResumeTimer?.cancel();
    _userScrollResumeTimer = Timer(_userScrollResumeDelay, () {
      _userScrollResumeTimer = null;
      _resumeAutoScrollAfterUserScroll();
    });
  }

  /// 延迟到点：恢复自动跟随；播放中立即平滑滚回当前行。
  void _resumeAutoScrollAfterUserScroll() {
    if (!mounted ||
        _isCopyLyricsMode ||
        !_lyricsAreSynced ||
        _autoScroll ||
        _lyrics.isEmpty) {
      return;
    }
    _enableAutoScrollWithSuppression();
    final provider = Provider.of<PlaybackProvider>(context, listen: false);
    if (!provider.snapshot.isPlaying) {
      // 暂停中：只恢复跟随状态，不把视图从用户停留处拽回；
      // 恢复播放后行号变化会自然滚回当前行。
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_autoScroll || !_scrollController.hasClients) {
        return;
      }
      final currentIndex = _getCurrentLineIndex(provider.currentPosition);
      if (currentIndex >= 0) {
        _scrollToCurrentLine(currentIndex);
        _previousLineIndex = currentIndex;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    // 曲目变化走低频快照 Selector；行高亮订阅 position 独立通道，
    // 仅在行号变化时重建（PositionLineIndexBuilder 内部缓存行号）。
    return Selector<PlaybackProvider, String?>(
      selector: (_, provider) => provider.snapshot.current?.id.uri,
      builder: (context, currentTrackId, _) {
        return PositionLineIndexBuilder(
          position: playbackProvider.position,
          lineIndexFor: _getCurrentLineIndex,
          builder: (context, currentLineIndex) => _buildLyricsContent(
            context,
            l10n,
            currentTrackId,
            currentLineIndex,
          ),
        );
      },
    );
  }

  /// 构建歌词主体：低频触发（换曲/行号变化/滚动状态等）。
  Widget _buildLyricsContent(
    BuildContext context,
    AppLocalizations l10n,
    String? currentTrackId,
    int currentLineIndex,
  ) {
    final bool trackJustChanged = (currentTrackId != _lastTrackId);

    // 曲目变化：按新 id 加载歌词
    if (trackJustChanged) {
      // 换曲时退出复制模式
      if (_isCopyLyricsMode && mounted) {
        Future.microtask(() => _toggleCopyLyricsMode());
      }
      Future.microtask(() async {
        await _loadLyrics();
      });
    }

    _syncLineKeys(_lyrics.length);
    _scheduleScrollabilityCheck();

    // 歌词页扩展行开关：独立于输出侧（桌面 / 通知 / 蓝牙）的翻译·罗马音设置。
    final lyricsDisplaySettings = context.watch<LyricsDisplaySettings>();

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    if (_autoScroll &&
        _lyrics.isNotEmpty &&
        mounted &&
        currentLineIndex >= 0) {
      if (_previousLineIndex != currentLineIndex ||
          _pendingScrollIndex != null) {
        _previousLineIndex = currentLineIndex;
        _pendingScrollIndex = currentLineIndex;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _autoScroll &&
              _pendingScrollIndex == currentLineIndex) {
            _scrollToCurrentLine(currentLineIndex);
          }
        });
      }
    }

    final bool shouldShowQuickActions = _shouldShowQuickActionsBar;
    _syncQuickActions(shouldShowQuickActions);

    return Material(
      color: Colors.transparent,
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollNotification) {
          if (!mounted) return true;

          bool userInitiatedScroll = false;
          // 用户手动操作后暂停自动滚动（延迟恢复见 _scheduleUserScrollResume）
          if (scrollNotification is UserScrollNotification) {
            if (_temporarilyIgnoreUserScroll) {
              return true;
            }
            if (scrollNotification.direction != ScrollDirection.idle &&
                _autoScroll) {
              setState(() {
                _autoScroll = false;
                _temporarilyIgnoreUserScroll = false;
                _userScrollSuppressionTimer?.cancel();
              });
            }
            if (scrollNotification.direction != ScrollDirection.idle) {
              userInitiatedScroll = true;
            }
          } else if (scrollNotification is ScrollStartNotification) {
            userInitiatedScroll = scrollNotification.dragDetails != null;
          } else if (scrollNotification is ScrollUpdateNotification) {
            userInitiatedScroll = scrollNotification.dragDetails != null;
          } else if (scrollNotification is OverscrollNotification) {
            userInitiatedScroll = scrollNotification.dragDetails != null;
          }

          if (userInitiatedScroll || !_autoScroll) {
            // 拖拽/滚轮以及暂停期间的惯性滑行都重置计时：
            // 停手（含惯性结束）静置一段时间后才自动恢复跟随。
            _scheduleUserScrollResume();
          }
          if (_requiresManualQuickActions && userInitiatedScroll) {
            _showManualQuickActionsTemporarily();
          }
          return true;
        },
        child: Stack(
          children: [
            if (_lyrics.isEmpty && _isLyricsLoading)
              Positioned.fill(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: M3EProgressIndicator.circular(
                          size: 24,
                          strokeWidth: 2.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.lyricsLoading,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ListView.builder(
              key: _listViewKey,
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              scrollCacheExtent: const ScrollCacheExtent.pixels(
                  1000.0), // 预建附近行，减少兜底跳转
              padding: EdgeInsets.only(
                top: 80 + MediaQuery.of(context).padding.top,
                bottom: 40 +
                    MediaQuery.of(context)
                        .padding
                        .bottom,
              ),
              itemCount: _lyrics.length + 1,
              itemBuilder: (context, index) {
                if (index == _lyrics.length) {
                  return SizedBox(height: _tailSpace());
                }
                final theme = Theme.of(context);
                final bool isWideLyricLayout = context
                    .layoutType(ResponsivePageType.detail)
                    .preferTwoPane;
                final bool isWeb = kIsWeb;
                final line = _lyrics[index];
                final bool lyricsSynced = _lyricsAreSynced;
                final bool isCurrentLine =
                    lyricsSynced && index == currentLineIndex;
                final bool isPastLine =
                    lyricsSynced && index < currentLineIndex;
                // 歌词行角色契约：正文用 onSurface/onSurfaceVariant，
                // 仅当前行用 primary 强调（全页唯一强调色）。
                final Color baseTextColor;
                if (!lyricsSynced) {
                  baseTextColor = theme.colorScheme.onSurface;
                } else if (isPastLine) {
                  baseTextColor = theme.colorScheme.onSurfaceVariant;
                } else if (isCurrentLine) {
                  baseTextColor = theme.colorScheme.primary;
                } else {
                  baseTextColor = theme.colorScheme.onSurface;
                }
                final double lyricFontSize = isWideLyricLayout
                    ? (isWeb ? 30.0 : 24.0)
                    : (isWeb ? 36.0 : 22.0);
                final String lineTranslation =
                    index < _translations.length ? _translations[index] : '';
                final String lineRoma =
                    index < _romas.length ? _romas[index] : '';
                final bool showTranslation =
                    lyricsDisplaySettings.pageTranslationEnabled &&
                        lineTranslation.isNotEmpty;
                final bool showRoma = lyricsDisplaySettings.pageRomaEnabled &&
                    lineRoma.isNotEmpty;
                // 逐字渲染：仅当前行 + 有词时间轴 + 非复制模式；
                // 已唱/未唱用 primary/onSurface 双色，行级强调由词高亮表达。
                final List<LyricWord>? lineWords = line.words;
                final bool useKaraoke = isCurrentLine &&
                    !_isCopyLyricsMode &&
                    lineWords != null &&
                    lineWords.isNotEmpty;
                // 扩展行样式：字号对齐桌面歌词规格（主字号 × 0.8），
                // 颜色保持行角色契约的次要文本，不参与 primary 强调。
                final TextStyle extendedLineStyle = TextStyle(
                  fontSize: lyricFontSize * 0.8,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant,
                );

                return GestureDetector(
                  key: _lineKeys[index],
                  onTap: () {
                    HapticFeedback.lightImpact();
                    if (!mounted) return;

                    final tappedTimestamp = _lyrics[index].timestamp;
                    playbackProvider
                        .seekToPosition(tappedTimestamp.inMilliseconds);

                    bool needsScrollTrigger = false;
                    if (_isCopyLyricsMode) {
                      _toggleCopyLyricsMode();
                      needsScrollTrigger = true;
                    } else {
                      if (!_autoScroll) {
                        needsScrollTrigger = true;
                        _enableAutoScrollWithSuppression(
                          duration: const Duration(milliseconds: 250),
                        );
                      } else {
                        // 已在自动滚动时仅 seek 可能足够，
                        // 这里显式触发滚动以立即反馈。
                        needsScrollTrigger = true;
                      }
                    }

                    if (needsScrollTrigger) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _autoScroll) {
                          _scrollToCurrentLine(index);
                          _previousLineIndex = index;
                        }
                      });
                    }
                  },
                  child: AnimatedPadding(
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOutCubic,
                    padding: EdgeInsets.symmetric(
                      // Web端行间距增大30%
                      vertical: isWeb
                          ? (isCurrentLine ? 15.6 : 10.4)
                          : (isCurrentLine ? 12.0 : 8.0),
                      horizontal: isWideLyricLayout ? 24.0 : 40.0,
                    ),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutCubic,
                      style: TextStyle(
                        fontSize: lyricFontSize,
                        fontWeight: isCurrentLine
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: baseTextColor,
                        // Web端文字行高增大30%
                        height: isWeb ? 1.43 : 1.1,
                      ),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutCubic,
                        opacity: lyricsSynced
                            ? (isCurrentLine ? 1.0 : 0.8)
                            : 1.0,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (useKaraoke)
                              KaraokeLyricText(
                                words: lineWords,
                                position: playbackProvider.position,
                                playedColor: theme.colorScheme.primary,
                                unplayedColor: theme.colorScheme.onSurface,
                              )
                            else
                              Text(
                                line.text,
                                textAlign: TextAlign.left,
                              ),
                            // 翻译 / 罗马音：空文本不占位；顺序与
                            // LyricLineTracker 的扩展行拼接一致。
                            if (showTranslation) ...[
                              const SizedBox(height: 2),
                              Text(
                                lineTranslation,
                                textAlign: TextAlign.left,
                                style: extendedLineStyle,
                              ),
                            ],
                            if (showRoma) ...[
                              const SizedBox(height: 2),
                              Text(
                                lineRoma,
                                textAlign: TextAlign.left,
                                style: extendedLineStyle,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 40 + MediaQuery.of(context).padding.top,
              child: IgnorePointer(
                // 渐变层不接收手势。颜色统一取 colorScheme.surface
                //（ThemeData.scaffoldBackgroundColor 的取值来源），
                // 避免两处背景色来源漂移。
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Theme.of(context).colorScheme.surface,
                        Theme.of(context).colorScheme.surface,
                        Theme.of(context)
                            .colorScheme
                            .surface
                            .withValues(alpha: 0.8),
                        Theme.of(context)
                            .colorScheme
                            .surface
                            .withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.3, 0.6, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            // 底部快捷操作栏：M3EToolbar 浮动胶囊（底部左侧）。
            // 常驻挂载 + 弹性滑入淡出（进度 0..1）；隐藏态 IgnorePointer
            // 让手势穿透到歌词滚动，不与「到顶继续下拉」切换播放器竞争。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !shouldShowQuickActions,
                child: ExcludeSemantics(
                  excluding: !shouldShowQuickActions,
                  child: AnimatedBuilder(
                    animation: _quickActionsMotion,
                    builder: (context, child) {
                      // snapToEnd 保证落定即精确目标；位移保留弹簧过冲 = 弹性。
                      final double raw = _quickActionsMotion.value;
                      return Opacity(
                        // M3E 规范：effects（透明度）不过冲，位移保留过冲弹性。
                        opacity: raw.clamp(0.0, 1.0),
                        child: Transform.translate(
                          // 下滑完整高度（外层屏边距 + 胶囊 + 底部安全区）保证出画。
                          offset: Offset(
                            0,
                            (1 - raw) *
                                (2 * _quickActionsScreenOffset +
                                    _quickActionsContainerSize +
                                    MediaQuery.of(context).padding.bottom),
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: RepaintBoundary(
                      child: M3EToolbar(
                        key: const Key('lyricsQuickActions'),
                        alignment: AlignmentDirectional.bottomStart,
                        screenOffset: _quickActionsScreenOffset,
                        dockEdge: M3EToolbarDockEdge.bottom,
                        safeArea: true,
                        actions: _buildQuickActions(l10n),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _getCurrentLineIndex(Duration currentPosition) {
    if (!_lyricsAreSynced) return -1;
    return lyricLineIndexAt(_lyrics, currentPosition);
  }

  void _toggleCopyLyricsMode() {
    if (!mounted) return;

    final provider = Provider.of<PlaybackProvider>(context, listen: false);
    final wasCopyMode = _isCopyLyricsMode;

    setState(() {
      if (_isCopyLyricsMode) {
        _isCopyLyricsMode = false;
        _autoScroll = _lyricsAreSynced;
        _temporarilyIgnoreUserScroll = true;
        _quickActionsHideTimer?.cancel();
        _manualQuickActionsVisible = false;
        // 恢复保存的播放模式
        if (_previousPlayMode != null) {
          provider.setPlayMode(_previousPlayMode!);
          _previousPlayMode = null;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _autoScroll) {
            final currentPosition = provider.currentPosition;
            final latestCurrentIndex = _getCurrentLineIndex(currentPosition);
            if (latestCurrentIndex >= 0) {
              _scrollToCurrentLine(latestCurrentIndex);
              _previousLineIndex = latestCurrentIndex;
            }
          }
        });
      } else {
        _isCopyLyricsMode = true;
        _autoScroll = false;
        _temporarilyIgnoreUserScroll = false;
        _userScrollSuppressionTimer?.cancel();
        _cancelUserScrollResume();
        _quickActionsHideTimer?.cancel();
        // 记录当前模式并切到单曲循环
        _previousPlayMode = provider.currentMode;
        provider.setPlayMode(PlayMode.singleRepeat);

        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          Provider.of<NotificationService>(context, listen: false).showSnackBar(
            l10n.lyricsCopyModeSnackbar,
            duration: const Duration(seconds: 4),
          );
        }
      }
    });

    if (wasCopyMode) {
      _userScrollSuppressionTimer?.cancel();
      _userScrollSuppressionTimer = Timer(
        const Duration(milliseconds: 350),
        () {
          if (!mounted) return;
          setState(() {
            _temporarilyIgnoreUserScroll = false;
          });
        },
      );
    }
  }

  /// 换源页（歌词 / 音频双 tab）：默认落在歌词 tab。
  Future<void> _showSourceSwapPage() async {
    if (!mounted) return;

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);
    final currentTrack = playbackProvider.snapshot.current;
    final notificationService =
        Provider.of<NotificationService>(context, listen: false);
    final l10n = AppLocalizations.of(context)!;

    if (currentTrack == null) {
      notificationService.showSnackBar(l10n.noCurrentTrackPlaying);
      return;
    }

    final trackId = currentTrack.id.uri;
    final trackName = currentTrack.title;

    if (trackId.isEmpty || trackName.isEmpty) {
      notificationService.showSnackBar(l10n.cannotGetTrackInfo);
      return;
    }

    // 进入新页面前暂停自动滚动
    final wasAutoScrollEnabled = _autoScroll;
    _cancelUserScrollResume();
    if (_autoScroll) {
      setState(() {
        _autoScroll = false;
        _temporarilyIgnoreUserScroll = false;
        _userScrollSuppressionTimer?.cancel();
      });
    }

    final lyricsProvider =
        Provider.of<LyricsProvider>(context, listen: false);
    final result = await showSourceSwapPage(
      context,
      seed: currentTrack,
      lyricsProvider: lyricsProvider,
      initialTab: SourceSwapTab.lyrics,
    );
    if (!mounted) return;

    LyricsSearchSelection? selection;
    if (result is LyricsSearchSelection) {
      selection = result;
    }

    // 换源页歌词 tab 返回了歌词（页面已通过 LyricsProvider.saveManual
    // 写缓存并更新会话状态；这里只把结果落到本地渲染状态）
    if (selection != null && selection.lyrics.isNotEmpty) {
      final lyricsState = lyricsProvider.state;
      if (lyricsState.trackId != trackId ||
          lyricsState.status != LyricsStatus.ready) {
        return;
      }
      final bool synced = lyricsState.isSynced;
      final newLyrics = lyricsState.lines;
      _quickActionsHideTimer?.cancel();
      setState(() {
        _lyrics = newLyrics;
        _translations = lyricsState.translations;
        _romas = lyricsState.romas;
        _lyricsAreSynced = synced;
        _lastTrackId = trackId;
        _previousLineIndex = -1;
        _syncLineKeys(_lyrics.length);
        _manualQuickActionsVisible = false;

        // 换源前开启过自动滚动则恢复
        if (wasAutoScrollEnabled && synced) {
          _autoScroll = true;
          _temporarilyIgnoreUserScroll = true;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _autoScroll) {
              final currentPosition = playbackProvider.currentPosition;
              final currentIndex = _getCurrentLineIndex(currentPosition);
              if (currentIndex >= 0) {
                _scrollToCurrentLine(currentIndex);
                _previousLineIndex = currentIndex;
              }
            }
          });
        } else {
          _autoScroll = false;
          _temporarilyIgnoreUserScroll = false;
          _userScrollSuppressionTimer?.cancel();
        }
      });

      if (wasAutoScrollEnabled && _lyricsAreSynced && _autoScroll) {
        _userScrollSuppressionTimer?.cancel();
        _userScrollSuppressionTimer = Timer(
          const Duration(milliseconds: 350),
          () {
            if (!mounted) return;
            setState(() {
              _temporarilyIgnoreUserScroll = false;
            });
          },
        );
      }

      notificationService.showSnackBar(l10n.lyricsSearchAppliedSuccess);
    } else {
      // 未返回歌词或用户取消：
      // 恢复此前的自动滚动状态
      if (wasAutoScrollEnabled && !_autoScroll) {
        _enableAutoScrollWithSuppression();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _autoScroll) {
            final currentPosition = playbackProvider.currentPosition;
            final currentIndex = _getCurrentLineIndex(currentPosition);
            if (currentIndex >= 0) {
              _scrollToCurrentLine(currentIndex);
              _previousLineIndex = currentIndex;
            }
          }
        });
      }
    }

    // 打开页面前处于「手动滚动暂停」：返回后继续延迟恢复跟随。
    if (!_autoScroll && !_isCopyLyricsMode && _lyricsAreSynced) {
      _scheduleUserScrollResume();
    }
  }

  Future<void> _showLyricsSelectionPage() async {
    if (!mounted) return;

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);
    final currentTrack = playbackProvider.snapshot.current;
    final notificationService =
        Provider.of<NotificationService>(context, listen: false);
    final l10n = AppLocalizations.of(context)!;

    if (currentTrack == null) {
      notificationService.showSnackBar(l10n.noCurrentTrackPlaying);
      return;
    }

    if (_lyrics.isEmpty) {
      notificationService.showSnackBar(l10n.noLyricsToSelect);
      return;
    }

    final trackName = currentTrack.title;
    final artistName = _extractArtistNames(currentTrack);
    final albumCoverUrl = currentTrack.artwork?.uri.toString();
    // 歌词页展示开关：选择页与海报沿用同一对开关（歌词页看到什么就选什么）。
    final lyricsDisplaySettings = context.read<LyricsDisplaySettings>();

    // 暂停当前的自动滚动
    final wasAutoScrollEnabled = _autoScroll;
    _cancelUserScrollResume();
    if (_autoScroll) {
      setState(() {
        _autoScroll = false;
        _temporarilyIgnoreUserScroll = false;
        _userScrollSuppressionTimer?.cancel();
      });
    }

    await ResponsiveNavigation.showSecondaryPage<void>(
      context: context,
      child: LyricsSelectionPage(
        lyrics: _lyrics,
        translations: _translations,
        romas: _romas,
        showTranslation: lyricsDisplaySettings.pageTranslationEnabled,
        showRoma: lyricsDisplaySettings.pageRomaEnabled,
        trackTitle: trackName,
        artistName: artistName,
        albumCoverUrl: albumCoverUrl,
      ),
      preferredMode: SecondaryPageMode.sideSheet,
      maxWidth: 520,
      showCloseButton: false,
      barrierDismissible: false,
    );

    if (!mounted) return;

    if (wasAutoScrollEnabled && !_autoScroll) {
      _enableAutoScrollWithSuppression();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _autoScroll) {
          final currentPosition = playbackProvider.currentPosition;
          final currentIndex = _getCurrentLineIndex(currentPosition);
          if (currentIndex >= 0) {
            _scrollToCurrentLine(currentIndex);
            _previousLineIndex = currentIndex;
          }
        }
      });
    }

    // 打开页面前处于「手动滚动暂停」：返回后继续延迟恢复跟随。
    if (!_autoScroll && !_isCopyLyricsMode && _lyricsAreSynced) {
      _scheduleUserScrollResume();
    }
  }
}
