import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../domain/models/download.dart' show kLocalSourceKey;
import '../domain/models/track.dart';
import '../models/lyric_line.dart';
import 'lyrics_scroll_policy.dart';
import '../models/play_mode.dart';
import '../pages/lyrics_display/lyrics_content_settings_page.dart';
import '../pages/source_swap_page.dart';
import '../providers/lyrics_provider.dart';
import '../providers/playback_provider.dart';
import '../services/haptics.dart';
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

  /// 目标行未布局时的重试上限：按帧重试，超过后放弃（行号再变化会重新触发）。
  static const int _maxPendingScrollRetries = 8;

  /// 快捷操作栏：M3EFabMenu 浮动 FAB 的屏边距。
  static const double _quickActionsScreenOffset = 16;

  /// 快捷操作栏 FAB 容器尺寸（M3EFabSize.regular = 56dp，与展开态关闭键一致）。
  static const double _quickActionsFabSize = 56;

  /// 激活行锚点相对「可见区域中线」的上移比例（占视口高度）。
  ///
  /// 顶栏（顶部渐隐带 + 圆点带）比底栏高，只按可见区域居中会让激活行
  /// 视觉偏下；上移一点后上下留白更平衡，也接近主流歌词页的中上排版。
  /// 锚点作用于「主行文本块顶边」（整项还含翻译/罗马音，不参与锚定）。
  static const double _activeLineUpwardBias = 0.10;

  /// 歌词会话模块：会话真相的唯一来源（本组件只消费，不维护镜像字段）。
  LyricsProvider? _lyricsProvider;

  /// 本组件已请求加载的曲目 id（`null` = 尚未请求；渲染侧簿记，非会话状态）。
  String? _lastTrackId;

  /// 上一次已渲染的会话状态（用于「内容变了才重置滚动簿记」）。
  LyricsState _lastState = LyricsState.idle;

  /// 当前曲目的会话状态：尚未请求加载、或 provider 持有的是别的曲目时为空态。
  LyricsState get _session {
    final trackId = _lastTrackId;
    if (trackId == null) return LyricsState.idle;
    final state = _lyricsProvider?.state ?? LyricsState.idle;
    return state.trackId == trackId ? state : LyricsState.idle;
  }

  /// 会话是否正在加载（渲染侧读取，不再维护标志位）。
  bool get _isLoading => _session.status == LyricsStatus.loading;
  late final ScrollController _scrollController =
      widget.controller ?? ScrollController();
  final GlobalKey _listViewKey = GlobalKey();
  bool _autoScroll = true;
  bool _isCopyLyricsMode = false;
  PlayMode? _previousPlayMode;
  int _previousLineIndex = -1;

  /// 行（整项）的 key：点行 seek 与命中判定用。
  final List<GlobalKey> _lineKeys = [];

  /// 主行文本块的 key：自动滚动锚定用——整项还包含翻译/罗马音，按文本块
  /// 锚定落点才不会被项高带偏。
  final List<GlobalKey> _lineTextKeys = [];

  /// 等待精确滚动的目标行（目标未布局时下一帧重试）。
  int? _pendingScrollIndex;

  /// 未布局重试次数：目标行始终构建不出来时停止重试，避免每帧空转。
  int _pendingScrollRetries = 0;
  int? _currentTrackDurationMs;
  bool _temporarilyIgnoreUserScroll = false;
  Timer? _userScrollSuppressionTimer;

  /// 用户手动滚动后延迟恢复自动跟随的计时器（连续滚动会不断重置）。
  Timer? _userScrollResumeTimer;
  Timer? _quickActionsHideTimer;
  bool _manualQuickActionsVisible = false;
  bool _lyricsContentScrollable = true;
  bool _scrollabilityCheckScheduled = false;

  /// 快捷操作栏显隐弹簧：0 = 完全隐藏、1 = 完全展开。
  ///
  /// 直接用 motor（M3E 包内部同一驱动）：`MaterialSpringMotion.expressiveSpatialFast`
  /// 就是 expressive 的 fast spatial token（800 / 0.6，与
  /// [M3EMotion.expressiveSpatialFast] 一致）；`snapToEnd` 让弹簧落定精确吸附目标，
  /// 省掉容差收尾补丁。透明度同源并截断到 0..1（M3E 规范：effects 不过冲）。
  late final SingleMotionController _quickActionsMotion;

  /// FAB menu 控制器：隐藏时强制收起（打开状态不能随弹簧「藏起来」）。
  final M3EFabMenuController _fabMenuController = M3EFabMenuController();

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

  /// 会话状态变化（自己的加载落地 / 换源页手动保存等外部替换）：
  /// 状态值没变就直接跳过，避免无谓 setState。
  void _onLyricsProviderChanged() {
    if (!mounted) return;
    final state = _session;
    if (state == _lastState) return;
    _lastState = state;
    _applySessionChange(state);
  }

  @override
  void dispose() {
    _lyricsProvider?.removeListener(_onLyricsProviderChanged);
    _userScrollSuppressionTimer?.cancel();
    _userScrollResumeTimer?.cancel();
    _quickActionsHideTimer?.cancel();
    _quickActionsMotion.dispose();
    _fabMenuController.dispose();
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
      if (_session.lines.isNotEmpty || _lastTrackId != null) {
        _quickActionsHideTimer?.cancel();
        setState(() {
          _lastTrackId = null; // 会话状态经 _session 归空
          _lastState = LyricsState.idle;
          _autoScroll = true;
          _previousLineIndex = -1;
          _syncLineKeys(0);
          _currentTrackDurationMs = null;
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
      _lastState = LyricsState.idle; // 会话状态经 _session 归空
      _autoScroll = true;
      _previousLineIndex = -1;
      _syncLineKeys(0);
      _currentTrackDurationMs = trackDurationMs;
      _manualQuickActionsVisible = false;
    });

    // 取词/缓存/解析统一走歌词会话模块；本组件只消费 LyricsState。
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
      _lastState = lyricsState;
      _applySessionChange(lyricsState, trackDurationMs: trackDurationMs);
      // 下一首歌词预载在组合根统一处理（不依赖本组件是否挂载）。
    } else {
      // 取词失败 / 空歌词：会话状态已归空（_session 返回空态），只重置簿记。
      _lastState = LyricsState.idle;
      _applySessionChange(LyricsState.idle);
    }
  }

  /// 会话内容变化后的渲染侧簿记：滚动簿记 / 行 key / 跟随开关统一在这里重置。
  void _applySessionChange(LyricsState state, {int? trackDurationMs}) {
    _quickActionsHideTimer?.cancel();
    setState(() {
      _autoScroll = state.isSynced;
      _previousLineIndex = -1;
      _syncLineKeys(state.lines.length);
      if (trackDurationMs != null) _currentTrackDurationMs = trackDurationMs;
      _pendingScrollIndex = null;
      _pendingScrollRetries = 0;
      _manualQuickActionsVisible = false;
    });
  }

  void _syncLineKeys(int targetLength) {
    _resizeKeys(_lineKeys, targetLength);
    _resizeKeys(_lineTextKeys, targetLength);
  }

  static void _resizeKeys(List<GlobalKey> keys, int targetLength) {
    if (keys.length == targetLength) return;
    if (keys.length < targetLength) {
      final difference = targetLength - keys.length;
      for (int i = 0; i < difference; i++) {
        keys.add(GlobalKey());
      }
    } else {
      keys.removeRange(targetLength, keys.length);
    }
  }

  String _extractArtistNames(AppLocalizations l10n, Track track) {
    final label = track.artistLabel;
    return label.isEmpty ? l10n.unknownArtist : label;
  }

  bool get _requiresManualQuickActions =>
      _session.lines.isNotEmpty && (!_session.isSynced || !_lyricsContentScrollable);

  /// 当前是否有曲目（无曲目时 FAB 隐藏：换歌词 / 显示设置都没有对象）。
  bool get _hasTrack =>
      Provider.of<PlaybackProvider>(context, listen: false).snapshot.current !=
      null;

  bool get _shouldShowQuickActionsBar {
    // 复制模式下必须保留出口（否则收起播放器后无法退出复制模式）。
    if (!widget.quickActionsEnabled && !_isCopyLyricsMode) {
      return false;
    }
    if (!_hasTrack) return false;
    if (_isCopyLyricsMode || _session.lines.isEmpty) {
      return true;
    }
    if (_session.isSynced && _lyricsContentScrollable) {
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
          _session.lines.isNotEmpty && (!_session.isSynced || !canScroll);
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
        _session.lines.isEmpty) {
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
          _session.lines.isEmpty) {
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
  ///
  /// 只返回「视口比例」，落点由 `anchoredLineOffset` 换算为主行文本块顶边。
  double _anchorFraction() {
    if (!_scrollController.hasClients) {
      return 0.5 - _activeLineUpwardBias;
    }
    final viewport = _scrollController.position.viewportDimension;
    return effectiveAlignment(
      viewport: viewport,
      topOverlay: _topOverlay(),
      bottomOverlay: _bottomOverlay(),
      upwardBias: _activeLineUpwardBias,
    );
  }

  /// 顶栏遮挡：渐隐带 + 系统状态栏。
  double _topOverlay() => kTopFadeBandHeight + MediaQuery.of(context).padding.top;

  /// 底栏遮挡：快捷操作栏（FAB menu 的 FAB）可见时 = 屏边距 + FAB 尺寸
  /// + 底部安全区；隐藏时为 0。
  double _bottomOverlay() {
    if (!_shouldShowQuickActionsBar) return 0.0;
    final padding = MediaQuery.of(context).padding;
    return padding.bottom + _quickActionsScreenOffset + _quickActionsFabSize;
  }

  double _tailSpace() {
    if (!_scrollController.hasClients) return 400.0;
    final position = _scrollController.position;
    if (!position.hasPixels || position.viewportDimension <= 0) {
      return 400.0;
    }
    return tailSpace(
      viewport: position.viewportDimension,
      topOverlay: _topOverlay(),
      bottomOverlay: _bottomOverlay(),
      upwardBias: _activeLineUpwardBias,
    );
  }

  /// 快捷操作栏显隐：条件变化才起弹簧（建期调用安全，弹簧在下一帧才改值）。
  ///
  /// [SingleMotionController.animateTo] 自动携带当前速度续跑（中途反向不跳变）。
  void _syncQuickActions(bool show) {
    if (_quickActionsExpanded == show) return;
    _quickActionsExpanded = show;
    if (!show) {
      // 收起时先关掉打开的菜单：FAB 藏起来但菜单还开着会失去出口。
      _fabMenuController.close();
    }
    _quickActionsMotion.animateTo(show ? 1.0 : 0.0);
  }

  /// 居中/恢复跟随：开启自动跟随并立即滚回当前行。
  void _centerCurrentLine() {
    HapticsService.lightImpact();
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

  /// FAB menu 项（歌词域操作）：换歌词 / 复制模式 / 歌词海报 /
  /// 居中跟随（条件）；无歌词时 = 换歌词 + 歌词显示设置。
  ///
  /// 文案统一取「动作 + 对象」的短名（3–6 字）：胶囊宽度随文案生长 + 右缘对齐，
  /// 长短悬殊时一眼就能看出参差，所以海报入口用「歌词海报」而不是整句说明。
  ///
  /// `M3EFabMenu` 要求 2–6 项且不支持 disabled：条件项只能增删，因此无歌词
  /// 时用「显示设置」凑下限，而不是展示禁用项。
  List<M3EFabMenuItem> _buildQuickActions(AppLocalizations l10n) {
    final bool hasLyrics = _session.lines.isNotEmpty;
    // 本地下载曲目：文件是持久副本，不提供「换源」入口（自动换源也已跳过）。
    // 用 listen:false 读取：本方法在 PositionLineIndexBuilder 的 build 内被
    // 调用，context.select 在该阶段会触发 provider 断言；曲目变化时外层
    // Selector（按 track uri）会重建整个歌词内容，取值仍是最新。
    final isLocalTrack =
        Provider.of<PlaybackProvider>(context, listen: false)
                .snapshot
                .current
                ?.id
                .sourceKey ==
            kLocalSourceKey;
    return <M3EFabMenuItem>[
      // 换歌词：歌词页的快捷入口（信息页歌词来源行是数据面入口）。
      if (!isLocalTrack)
        M3EFabMenuItem(
          icon: const Icon(Icons.swap_horiz_rounded),
          label: l10n.lyricsSwapAction,
          onPressed: () => unawaited(_showSourceSwapPage()),
        ),
      M3EFabMenuItem(
        icon: Icon(
          _isCopyLyricsMode
              ? Icons.playlist_play_rounded
              : Icons.edit_note_rounded,
        ),
        label: _isCopyLyricsMode
            ? l10n.lyricsCopyModeExit
            : l10n.lyricsCopyModeAction,
        onPressed: () {
          HapticsService.lightImpact();
          _toggleCopyLyricsMode();
        },
      ),
      if (hasLyrics)
        M3EFabMenuItem(
          icon: const Icon(Icons.checklist_rounded),
          label: l10n.lyricsPosterAction,
          onPressed: () => unawaited(_showLyricsSelectionPage()),
        ),
      // 居中/恢复跟随：仅「手动滚动暂停 + 有同步歌词」时入列。
      if (hasLyrics && !_autoScroll && _session.isSynced)
        M3EFabMenuItem(
          icon: const Icon(Icons.vertical_align_center_rounded),
          label: l10n.centerCurrentLine,
          onPressed: _centerCurrentLine,
        ),
      // 无歌词：歌词显示设置（与「换歌词」一起满足 2 项下限）。
      if (!hasLyrics)
        M3EFabMenuItem(
          icon: const Icon(Icons.tune_rounded),
          label: l10n.lyricsDisplaySettingsAction,
          onPressed: () => unawaited(_showLyricsDisplaySettings()),
        ),
    ];
  }

  /// 歌词显示设置（歌词页 + 输出共享项）：无歌词时的 FAB menu 入口。
  Future<void> _showLyricsDisplaySettings() {
    return ResponsiveNavigation.showSecondaryPage<void>(
      context: context,
      child: const LyricsContentSettingsPage(),
      preferredMode: SecondaryPageMode.sideSheet,
      maxWidth: 520,
      showCloseButton: false,
    );
  }

  /// 滚到当前行：把主行文本块的顶边锚定在 [_anchorFraction] 处。
  ///
  /// 目标取「主行文本块」而非整项：长行换行 / 翻译·罗马音不再影响落点；
  /// 目标尚未布局（远跳 / 首帧）时先按时间戳比例粗定位一次，下一帧重试。
  void _scrollToCurrentLine(int currentLineIndex) {
    if (!mounted ||
        !_autoScroll ||
        !_session.isSynced ||
        !_scrollController.hasClients ||
        currentLineIndex < 0 ||
        currentLineIndex >= _lineTextKeys.length) {
      return;
    }

    final position = _scrollController.position;
    final renderObject =
        _lineTextKeys[currentLineIndex].currentContext?.findRenderObject();
    if (renderObject == null) {
      // 目标行还没进入构建范围：粗定位把列表带过去，下一帧再精确滚动。
      _pendingScrollIndex = currentLineIndex;
      _jumpTowardLineByRatio(currentLineIndex);
      if (_pendingScrollRetries < _maxPendingScrollRetries) {
        _pendingScrollRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _autoScroll &&
              _pendingScrollIndex == currentLineIndex) {
            _scrollToCurrentLine(currentLineIndex);
          }
        });
      }
      return;
    }

    _pendingScrollIndex = null;
    _pendingScrollRetries = 0;

    try {
      final viewport = RenderAbstractViewport.of(renderObject);
      // 顶边对齐视口顶边时的偏移；再减去锚点距离得到目标偏移。
      final leadingOffset = viewport.getOffsetToReveal(renderObject, 0.0).offset;
      final target = anchoredLineOffset(
        leadingOffset: leadingOffset,
        viewport: position.viewportDimension,
        anchorFraction: _anchorFraction(),
      );
      final clampedOffset = clampScrollOffset(
        target: target,
        minScrollExtent: position.minScrollExtent,
        maxScrollExtent: position.maxScrollExtent,
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

  /// 目标未布局时的粗定位：按时间戳（缺曲目时长时按行号）比例估算偏移并
  /// 跳过去，让目标进入列表构建范围；精确滚动交给下一帧重试。
  void _jumpTowardLineByRatio(int currentLineIndex) {
    final position = _scrollController.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    final lines = _session.lines;
    if (lines.isEmpty || currentLineIndex >= lines.length) return;

    double ratio;
    final durationMs = _currentTrackDurationMs;
    if (durationMs != null && durationMs > 0) {
      ratio = lines[currentLineIndex].timestamp.inMilliseconds / durationMs;
    } else if (lines.length <= 1) {
      ratio = 0.0;
    } else {
      ratio = currentLineIndex / (lines.length - 1);
    }
    ratio = ratio.isFinite ? ratio.clamp(0.0, 1.0) : 0.0;

    final target = clampScrollOffset(
      target: ratio * position.maxScrollExtent -
          _anchorFraction() * position.viewportDimension,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
    );
    if (!shouldScrollTo(current: position.pixels, target: target)) return;
    try {
      _scrollController.jumpTo(target);
    } catch (_) {
      // 跳转失败可忽略：下一帧会重试
    }
  }

  void _enableAutoScrollWithSuppression(
      {Duration duration = const Duration(milliseconds: 350)}) {
    if (!mounted) {
      return;
    }
    // 无论走哪条分支，排队的「延迟恢复」都已不需要。
    _cancelUserScrollResume();
    if (!_session.isSynced) {
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
    if (_isCopyLyricsMode || !_session.isSynced || _session.lines.isEmpty) {
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
        !_session.isSynced ||
        _autoScroll ||
        _session.lines.isEmpty) {
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

    _syncLineKeys(_session.lines.length);
    _scheduleScrollabilityCheck();

    // 歌词页扩展行开关：独立于输出侧（桌面 / 通知 / 蓝牙）的翻译·罗马音设置。
    final lyricsDisplaySettings = context.watch<LyricsDisplaySettings>();

    final playbackProvider =
        Provider.of<PlaybackProvider>(context, listen: false);

    if (_autoScroll &&
        _session.lines.isNotEmpty &&
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
            if (_session.lines.isEmpty && _isLoading)
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
            // 空态（取词失败 / 没找到词）：俏皮话提示，动作由 FAB menu
            // （换歌词 / 显示设置）承担；不拦截手势。
            if (_session.lines.isEmpty && !_isLoading && currentTrackId != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        l10n.lyricsEmptyState,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
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
              itemCount: _session.lines.length + 1,
              itemBuilder: (context, index) {
                if (index == _session.lines.length) {
                  return SizedBox(height: _tailSpace());
                }
                final theme = Theme.of(context);
                final bool isWideLyricLayout = context
                    .layoutType(ResponsivePageType.detail)
                    .preferTwoPane;
                final line = _session.lines[index];
                final bool lyricsSynced = _session.isSynced;
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
                final double lyricFontSize =
                    isWideLyricLayout ? 24.0 : 22.0;
                final String lineTranslation =
                    index < _session.translations.length ? _session.translations[index] : '';
                final String lineRoma =
                    index < _session.romas.length ? _session.romas[index] : '';
                // 扩展行逐行渲染：有数据且歌词页开关打开就显示，空文本不占位
                // （与海报 / 选择页同语义）。
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
                // 行样式必须从环境样式派生：AnimatedDefaultTextStyle 是「替换」
                // 而不是合并（内部直接 `DefaultTextStyle(style: …)`，见 SDK
                // implicit_animations.dart），写字面量会把字体族一并丢成引擎
                // 默认字体——设置页选的「应用字体」（含主题注入的平台默认）会在
                // 整段歌词行失效，与本页其它文字两种字体。这里只覆盖字号/字重/
                // 颜色/行高，其余（字体族、回退链、排版属性）继续继承主题。
                final TextStyle lineBaseStyle =
                    DefaultTextStyle.of(context).style;
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
                    HapticsService.lightImpact();
                    if (!mounted) return;

                    final tappedTimestamp = _session.lines[index].timestamp;
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
                      vertical: isCurrentLine ? 12.0 : 8.0,
                      // 宽版式（桌面右栏 / 平板两栏）与队列、详情同一内容边距
                      // （16，M3E 口径）；窄版式保持歌词行特有的 40。
                      horizontal: isWideLyricLayout ? 16.0 : 40.0,
                    ),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutCubic,
                      style: lineBaseStyle.copyWith(
                        fontSize: lyricFontSize,
                        fontWeight: isCurrentLine
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: baseTextColor,
                        height: 1.1,
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
                                key: _lineTextKeys[index],
                                words: lineWords,
                                position: playbackProvider.position,
                                playedColor: theme.colorScheme.primary,
                                unplayedColor: theme.colorScheme.onSurface,
                              )
                            else
                              Text(
                                line.text,
                                key: _lineTextKeys[index],
                                textAlign: TextAlign.left,
                              ),
                            // 翻译 / 罗马音：空文本不占位；顺序与
                            // LyricLineTracker 的扩展行拼接一致。逐行渲染，
                            // 与主行一起滚动；歌词页开关切换时展开 / 收起。
                            _buildExtendedLines(
                              showTranslation: showTranslation,
                              translation: lineTranslation,
                              showRoma: showRoma,
                              roma: lineRoma,
                              style: extendedLineStyle,
                            ),
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
            // 底部快捷操作栏：M3EFabMenu（底部右侧 FAB → 带文字 label 的
            // 操作胶囊）。常驻挂载 + 弹性滑入淡出（进度 0..1）；隐藏态
            // IgnorePointer 让手势穿透到歌词滚动，不与「到顶继续下拉」
            // 切换播放器竞争。
            Positioned(
              right: _quickActionsScreenOffset,
              bottom: _quickActionsScreenOffset +
                  MediaQuery.of(context).padding.bottom,
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
                          // 下滑完整高度（外层屏边距 + FAB + 底部安全区）保证出画。
                          offset: Offset(
                            0,
                            (1 - raw) *
                                (2 * _quickActionsScreenOffset +
                                    _quickActionsFabSize +
                                    MediaQuery.of(context).padding.bottom),
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: RepaintBoundary(
                      child: M3EFabMenu(
                        key: const Key('lyricsQuickActions'),
                        controller: _fabMenuController,
                        size: M3EFabSize.regular,
                        // 右下角：胶囊自右缘生长、右边缘对齐，多项 label
                        // 长短不一时比左侧更整齐（也避开歌词左侧的阅读边）。
                        position: M3EFabMenuPosition.right,
                        icon: const Icon(Icons.more_horiz_rounded),
                        items: _buildQuickActions(l10n),
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
    if (!_session.isSynced) return -1;
    return lyricLineIndexAt(_session.lines, currentPosition);
  }

  /// 翻译 / 罗马音块（挂在主行文本下方，逐行渲染）。
  ///
  /// 通过 [AnimatedSwitcher] + `SizeTransition` 做「淡出 + 收起」：歌词页
  /// 开关切换（翻译 / 罗马音开或关）时扩展行从主行下方展开 / 收起，
  /// 而不是硬切、也不是留下占位。
  Widget _buildExtendedLines({
    required bool showTranslation,
    required String translation,
    required bool showRoma,
    required String roma,
    required TextStyle style,
  }) {
    final bool visible = showTranslation || showRoma;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topLeft,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topLeft,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: !visible
          ? const SizedBox.shrink(key: ValueKey<String>('lyricsExtendedNone'))
          : Column(
              key: const ValueKey<String>('lyricsExtendedLines'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showTranslation) ...[
                  const SizedBox(height: 2),
                  Text(
                    translation,
                    textAlign: TextAlign.left,
                    style: style,
                  ),
                ],
                if (showRoma) ...[
                  const SizedBox(height: 2),
                  Text(
                    roma,
                    textAlign: TextAlign.left,
                    style: style,
                  ),
                ],
              ],
            ),
    );
  }

  void _toggleCopyLyricsMode() {
    if (!mounted) return;

    final provider = Provider.of<PlaybackProvider>(context, listen: false);
    final wasCopyMode = _isCopyLyricsMode;

    setState(() {
      if (_isCopyLyricsMode) {
        _isCopyLyricsMode = false;
        _autoScroll = _session.isSynced;
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
      _quickActionsHideTimer?.cancel();
      setState(() {
        // 会话状态已由 saveManual 更新（唯一真相），这里只重置渲染侧簿记。
        _lastState = lyricsState;
        _lastTrackId = trackId;
        _previousLineIndex = -1;
        _syncLineKeys(lyricsState.lines.length);
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

      if (wasAutoScrollEnabled && _session.isSynced && _autoScroll) {
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
      // 恢复打开搜索前的自动滚动状态
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
    if (!_autoScroll && !_isCopyLyricsMode && _session.isSynced) {
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

    if (_session.lines.isEmpty) {
      notificationService.showSnackBar(l10n.noLyricsToSelect);
      return;
    }

    final trackName = currentTrack.title;
    final artistName = _extractArtistNames(l10n, currentTrack);
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
        lyrics: _session.lines,
        translations: _session.translations,
        romas: _session.romas,
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
    if (!_autoScroll && !_isCopyLyricsMode && _session.isSynced) {
      _scheduleUserScrollResume();
    }
  }
}
