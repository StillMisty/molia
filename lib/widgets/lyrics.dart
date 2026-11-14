import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../domain/models/track.dart';
import '../models/lyric_line.dart';
import 'lyrics_scroll_policy.dart';
import '../models/play_mode.dart';
import '../pages/source_swap_page.dart';
import '../providers/lyrics_provider.dart';
import '../providers/playback_provider.dart';
import '../services/haptics.dart';
import '../services/lyrics_display/lyric_timing_policy.dart';
import '../services/lyrics_display/lyrics_display_settings.dart';
import '../services/notification_service.dart';
import '../theme/motion_policy.dart';
import '../utils/responsive.dart';
import 'lyric_karaoke_text.dart';
import 'lyrics_display_settings_action.dart';
import 'lyrics_selection_page.dart';
import 'lyrics_source_search_view.dart';
import 'lyrics_view_session.dart';
import 'playback_selectors.dart';
import 'shell_page_visibility.dart';

/// 歌词页 FAB 的固定动作序列（顺序即展示顺序）。
///
/// 前四项恒定：换源 / 复制歌词 / 歌词海报 / 显示设置。用户手动滚动后
/// 「居中当前行」只能追加在末尾——固定项不因歌词有无、是否本地曲目而增删，
/// 菜单位置才不会随状态跳来跳去。
enum LyricsQuickAction {
  swapSource,
  copyLyrics,
  poster,
  displaySettings,
  centerCurrentLine,
}

/// 按状态计算 FAB 动作：前四项恒定，「居中当前行」只作为第五项追加。
List<LyricsQuickAction> lyricsQuickActionOrder({
  required bool hasLyrics,
  required bool synced,
  required bool autoScroll,
}) {
  return [
    LyricsQuickAction.swapSource,
    LyricsQuickAction.copyLyrics,
    LyricsQuickAction.poster,
    LyricsQuickAction.displaySettings,
    if (hasLyrics && synced && !autoScroll) LyricsQuickAction.centerCurrentLine,
  ];
}

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
        SingleTickerProviderStateMixin
    implements LyricsViewHost {
  /// 快捷操作栏：M3EFabMenu 浮动 FAB 的屏边距。
  static const double _quickActionsScreenOffset = 16;

  /// 快捷操作栏 FAB 容器尺寸（M3EFabSize.regular = 56dp，与展开态关闭键一致）。
  static const double _quickActionsFabSize = 56;

  /// 激活行锚点相对「可见区域中线」的上移比例（占视口高度）。
  ///
  /// 顶栏（顶部渐隐带 + 圆点带）比底栏高，只按可见区域居中会让激活行
  /// 视觉偏下；0.14 使主行文本顶边落在视口约 38%–40% 高度（中上排版），
  /// 上下留白更平衡。
  /// 锚点作用于「主行文本块顶边」（整项还含翻译/罗马音，不参与锚定）。
  static const double _activeLineUpwardBias = 0.14;

  /// 歌词会话模块：会话真相的唯一来源（本组件只消费，不维护加载镜像）。
  LyricsProvider? _lyricsProvider;

  /// 上一次已应用的会话状态（渲染侧簿记：内容变了才重置滚动 / 行 key）。
  LyricsState _lastState = LyricsState.idle;

  /// 当前曲目的会话状态（曲目变化由组合根经 `ensureForTrack` 推进）。
  LyricsState get _session => _lyricsProvider?.state ?? LyricsState.idle;

  /// 会话是否正在加载（渲染侧直接读该状态）。
  bool get _isLoading => _session.status == LyricsStatus.loading;
  late final ScrollController _scrollController =
      widget.controller ?? ScrollController();
  final GlobalKey _listViewKey = GlobalKey();

  /// 歌词页视图会话：跟随 / 复制模式 / 操作栏 / 滚动重试的唯一状态机。
  ///
  /// 本 State 同时实现 [LyricsViewHost]：播放事实从这里读取，滚动几何与
  /// 弹簧仍在本侧执行；会话只决定时机（见 lyrics_view_session.dart）。
  late final LyricsViewSession _viewSession;

  /// 生产调度器：帧末回调用 post-frame，延迟窗口用真实 Timer。
  final _WidgetLyricsScheduler _scheduler = _WidgetLyricsScheduler();

  /// 页面当前是否活跃：nearest [ShellPageVisibility] 为 true（壳层可见且
  /// 宿主播放页停在歌词 tab；见 nowplaying.dart 的 tab 门控包装）。
  ///
  /// build 期写入、post-frame 回调读取：隐藏页即使还有排队中的帧末回调，
  /// 也不能再滚动 / 起弹簧。隐藏时 [PositionLineIndexBuilder] 不订阅进度，
  /// 因此本页在隐藏期间不会再因播放进度重建。
  bool _active = true;

  /// 行（整项）的 key：点行 seek 与命中判定用。
  final List<GlobalKey> _lineKeys = [];

  /// 主行文本块的 key：自动滚动锚定用——整项还包含翻译/罗马音，按文本块
  /// 锚定落点才不会被项高带偏。
  final List<GlobalKey> _lineTextKeys = [];

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
    _viewSession = LyricsViewSession(host: this);
    _viewSession.addListener(_onViewSessionChanged);
    // 快捷操作栏初始态与宿主传入的可见性一致（收起态歌词区才展开操作栏）。
    _quickActionsExpanded = widget.quickActionsEnabled;
    _quickActionsMotion = SingleMotionController(
      motion: const MaterialSpringMotion.expressiveSpatialFast(snapToEnd: true),
      vsync: this,
      initialValue: _quickActionsExpanded ? 1 : 0,
    );
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

  /// 视图会话的离散状态变化（跟随 / 复制模式 / 操作栏显隐）：重建渲染。
  void _onViewSessionChanged() {
    if (mounted) setState(() {});
  }

  /// 会话状态变化（组合根按曲目推进 / 换源页手动保存等外部替换）：
  /// 状态值没变就直接跳过，避免无谓 setState。
  void _onLyricsProviderChanged() {
    if (!mounted) return;
    final state = _session;
    if (state == _lastState) return;
    final trackChanged = state.trackId != _lastState.trackId;
    _lastState = state;
    _applySessionChange(state);
    if (!trackChanged) return;
    // 换曲 / 清空：取消待恢复的自动跟随，回到列表顶部（同步歌词随后
    // 由自动跟随滚到当前行）。
    _viewSession.cancelResume();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    // 复制模式锁定单曲循环：跨曲目保留会改变新曲的播放行为，换曲即退出。
    // 放到微任务里：本回调由会话通知触发，避免在通知链内重入播放命令。
    if (_viewSession.copyMode) {
      Future.microtask(_viewSession.toggleCopyMode);
    }
  }

  @override
  void dispose() {
    _lyricsProvider?.removeListener(_onLyricsProviderChanged);
    _viewSession.removeListener(_onViewSessionChanged);
    _viewSession.dispose();
    _quickActionsMotion.dispose();
    _fabMenuController.dispose();
    // 外部控制器由宿主释放。
    if (widget.controller == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  /// 会话内容变化后的渲染侧簿记：滚动簿记 / 行 key / 跟随开关统一在这里重置。
  void _applySessionChange(LyricsState state) {
    _viewSession.resetForLyrics();
    setState(() {
      _syncLineKeys(state.lines.length);
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

  /// 测量歌词内容是否可滚动，并把结果交给视图会话（显隐条件在那里统一）。
  void _scheduleScrollabilityCheck() {
    if (_scrollabilityCheckScheduled) {
      return;
    }
    _scrollabilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollabilityCheckScheduled = false;
      if (!mounted || !_active) {
        return;
      }
      if (!_scrollController.hasClients) {
        _scheduleScrollabilityCheck();
        return;
      }
      final position = _scrollController.position;
      final bool canScroll =
          (position.maxScrollExtent - position.minScrollExtent).abs() > 1.0;
      _viewSession.setScrollable(canScroll);
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
  double _topOverlay() =>
      kTopFadeBandHeight + MediaQuery.of(context).padding.top;

  /// 底栏遮挡：快捷操作栏（FAB menu 的 FAB）可见时 = 屏边距 + FAB 尺寸
  /// + 底部安全区；隐藏时为 0。
  double _bottomOverlay() {
    if (!_viewSession.quickActionsBarVisible) return 0.0;
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
    _viewSession.centerCurrentLine();
  }

  /// FAB menu 项（歌词域操作）：换源 / 复制歌词 / 歌词海报 / 显示设置
  /// 四项固定顺序；手动滚动暂停跟随时末尾追加「居中当前行」。
  ///
  /// 文案统一取「动作 + 对象」的短名（3–6 字）：胶囊宽度随文案生长 + 右缘对齐，
  /// 长短悬殊时一眼就能看出参差，所以海报入口用「歌词海报」而不是整句说明。
  ///
  /// `M3EFabMenu` 要求 2–6 项：固定四项已满足下限，条件项只追加不替换，
  /// 菜单的前四项在任何状态下都不变。
  List<M3EFabMenuItem> _buildQuickActions(AppLocalizations l10n) {
    final bool hasLyrics = _session.lines.isNotEmpty;
    return [
      for (final action in lyricsQuickActionOrder(
        hasLyrics: hasLyrics,
        synced: _session.isSynced,
        autoScroll: _viewSession.following,
      ))
        _quickActionItem(action, l10n),
    ];
  }

  M3EFabMenuItem _quickActionItem(
    LyricsQuickAction action,
    AppLocalizations l10n,
  ) {
    switch (action) {
      case LyricsQuickAction.swapSource:
        // 换源：歌词页的快捷入口（信息页歌词来源行是数据面入口）。
        return M3EFabMenuItem(
          icon: const Icon(Icons.swap_horiz_rounded),
          label: l10n.lyricsSwapAction,
          onPressed: () => unawaited(_showSourceSwapPage()),
        );
      case LyricsQuickAction.copyLyrics:
        return M3EFabMenuItem(
          icon: Icon(
            _viewSession.copyMode
                ? Icons.playlist_play_rounded
                : Icons.edit_note_rounded,
          ),
          label: _viewSession.copyMode
              ? l10n.lyricsCopyModeExit
              : l10n.lyricsCopyModeAction,
          onPressed: () {
            HapticsService.lightImpact();
            _toggleCopyLyricsMode();
          },
        );
      case LyricsQuickAction.poster:
        return M3EFabMenuItem(
          icon: const Icon(Icons.checklist_rounded),
          label: l10n.lyricsPosterAction,
          onPressed: () => unawaited(_showLyricsSelectionPage()),
        );
      case LyricsQuickAction.displaySettings:
        return M3EFabMenuItem(
          icon: const Icon(Icons.tune_rounded),
          label: l10n.lyricsDisplaySettingsAction,
          onPressed: () => unawaited(showLyricsDisplaySettings(context)),
        );
      case LyricsQuickAction.centerCurrentLine:
        return M3EFabMenuItem(
          icon: const Icon(Icons.vertical_align_center_rounded),
          label: l10n.centerCurrentLine,
          onPressed: _centerCurrentLine,
        );
    }
  }

  /// 滚到当前行：把主行文本块的顶边锚定在 [_anchorFraction] 处。
  ///
  /// 目标取「主行文本块」而非整项：长行换行 / 翻译·罗马音不再影响落点。
  /// 目标尚未布局（远跳 / 首帧）时返回 false，粗定位与按帧重试由视图会话
  /// 决定（见 `lyrics_view_session.dart`）。
  @override
  bool scrollToLine(int index) {
    if (!mounted ||
        !_scrollController.hasClients ||
        index < 0 ||
        index >= _lineTextKeys.length) {
      return false;
    }

    final position = _scrollController.position;
    final renderObject = _lineTextKeys[index].currentContext
        ?.findRenderObject();
    if (renderObject == null) return false;

    try {
      final viewport = RenderAbstractViewport.of(renderObject);
      // 顶边对齐视口顶边时的偏移；再减去锚点距离得到目标偏移。
      final leadingOffset = viewport
          .getOffsetToReveal(renderObject, 0.0)
          .offset;
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

      if (reduceMotionOf(context)) {
        // 减弱动效：直接落位，保留同一 clamp / 重试口径。
        _scrollController.jumpTo(clampedOffset);
      } else {
        _scrollController.animateTo(
          clampedOffset,
          // M3E long4 + emphasized decelerate：长距离跟随「先快后稳」收住，
          // 到点不甩尾。
          duration: M3EMotion.long4,
          curve: M3EMotion.emphasizedDecelerate,
        );
      }
    } catch (_) {
      // 滚动失败可忽略：下一帧会话会重试
    }
    return true;
  }

  /// 目标未布局时的粗定位：按时间戳（缺曲目时长时按行号）比例估算偏移并
  /// 跳过去，让目标进入列表构建范围；精确滚动交给下一帧重试。
  @override
  void jumpTowardLine(int currentLineIndex) {
    final position = _scrollController.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    final lines = _session.lines;
    if (lines.isEmpty || currentLineIndex >= lines.length) return;

    double ratio;
    // 曲目时长直接从播放快照读：会话状态只描述歌词，不复制播放元数据。
    final durationMs = Provider.of<PlaybackProvider>(
      context,
      listen: false,
    ).snapshot.current?.duration?.inMilliseconds;
    if (durationMs != null && durationMs > 0) {
      ratio = lines[currentLineIndex].timestamp.inMilliseconds / durationMs;
    } else if (lines.length <= 1) {
      ratio = 0.0;
    } else {
      ratio = currentLineIndex / (lines.length - 1);
    }
    ratio = ratio.isFinite ? ratio.clamp(0.0, 1.0) : 0.0;

    final target = clampScrollOffset(
      target:
          ratio * position.maxScrollExtent -
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

  /// 拖拽 / 滚轮类滚动：用户动作重置恢复计时；自动滚动只重置暂停中的计时。
  void _onScrollActivity(bool userInitiated) {
    if (userInitiated) {
      _viewSession.onUserScrollActivity();
    } else {
      _viewSession.onAutomaticScrollActivity();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final playbackProvider = Provider.of<PlaybackProvider>(
      context,
      listen: false,
    );

    // 可见性门控：隐藏页（壳层不在前台，或播放页停在队列 / 信息 tab）不再
    // 订阅进度、不自动滚动、不跑快捷操作弹簧。nearest scope 已把「壳层可见
    // && 当前 tab」组合好（见 nowplaying.dart），无壳层挂载时按可见处理。
    final bool active = ShellPageVisibility.maybeVisibleOf(context) ?? true;
    final bool becameActive = active && !_active;
    _active = active;
    if (becameActive) {
      // 隐藏期间进度通道被放弃，行号可能已经过期：重新可见时按最新进度
      // 强制同步一次当前行（否则行号没变就永远不会触发自动滚动）。
      _viewSession.onPageBecameActive();
    }

    // 曲目变化走低频快照 Selector；行高亮订阅 position 独立通道，
    // 仅在行号变化时重建（PositionLineIndexBuilder 内部缓存行号）。
    return Selector<PlaybackProvider, String?>(
      selector: (_, provider) => provider.snapshot.current?.id.uri,
      builder: (context, currentTrackId, _) {
        return PositionLineIndexBuilder(
          position: playbackProvider.position,
          enabled: active,
          lineIndexFor: _getCurrentLineIndex,
          builder: (context, currentLineIndex) => _buildLyricsContent(
            context,
            l10n,
            currentTrackId,
            currentLineIndex,
            active: active,
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
    int currentLineIndex, {
    required bool active,
  }) {
    _syncLineKeys(_session.lines.length);
    // 隐藏页不排帧末探测 / 自动滚动 / 弹簧同步：等重新可见时这里会再跑一遍。
    if (active) {
      _scheduleScrollabilityCheck();
    }

    // 歌词页扩展行开关：独立于输出侧（桌面 / 通知 / 蓝牙）的翻译·罗马音设置。
    final lyricsDisplaySettings = context.watch<LyricsDisplaySettings>();

    final playbackProvider = Provider.of<PlaybackProvider>(
      context,
      listen: false,
    );

    if (active) {
      // 行号变化（或仍有排队目标）由会话排帧末滚动；门控与重试都在会话里。
      _viewSession.reportLineIndex(currentLineIndex);
    }

    final bool shouldShowQuickActions = _viewSession.quickActionsBarVisible;
    if (active) {
      _syncQuickActions(shouldShowQuickActions);
    }

    // 行高亮 / 展开收起是 effects：减弱动效时零时长硬切。
    final Duration lineEffectDuration = effectDurationOf(
      context,
      M3EMotion.medium1,
    );

    return Material(
      color: Colors.transparent,
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollNotification) {
          if (!mounted) return true;

          // 滚动通知归一化成会话的三个入口：用户方向变化 / 用户拖拽 /
          // 非用户滚动（自动跟随动画或 idle 回调）。
          if (scrollNotification is UserScrollNotification) {
            if (scrollNotification.direction == ScrollDirection.idle) {
              _viewSession.onAutomaticScrollActivity();
            } else {
              _viewSession.onUserScrollStarted();
            }
          } else if (scrollNotification is ScrollStartNotification) {
            _onScrollActivity(scrollNotification.dragDetails != null);
          } else if (scrollNotification is ScrollUpdateNotification) {
            _onScrollActivity(scrollNotification.dragDetails != null);
          } else if (scrollNotification is OverscrollNotification) {
            _onScrollActivity(scrollNotification.dragDetails != null);
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
                1000.0,
              ), // 预建附近行，减少兜底跳转
              padding: EdgeInsets.only(
                top: 80 + MediaQuery.of(context).padding.top,
                bottom: 40 + MediaQuery.of(context).padding.bottom,
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
                final double lyricFontSize = isWideLyricLayout ? 24.0 : 22.0;
                final String lineTranslation =
                    index < _session.translations.length
                    ? _session.translations[index]
                    : '';
                final String lineRoma = index < _session.romas.length
                    ? _session.romas[index]
                    : '';
                // 扩展行逐行渲染：有数据且歌词页开关打开就显示，空文本不占位
                // （与海报 / 选择页同语义）。
                final bool showTranslation =
                    lyricsDisplaySettings.pageTranslationEnabled &&
                    lineTranslation.isNotEmpty;
                final bool showRoma =
                    lyricsDisplaySettings.pageRomaEnabled &&
                    lineRoma.isNotEmpty;
                // 逐字渲染：仅当前行 + 有词时间轴 + 非复制模式；
                // 已唱/未唱用 primary/onSurface 双色，行级强调由词高亮表达。
                // 隐藏页不挂逐字组件：它会自己订阅 position（4Hz + 补间控制器），
                // 重新可见时由当前行重建按最新进度直接落位。
                final List<LyricWord>? lineWords = line.words;
                final bool useKaraoke =
                    active &&
                    isCurrentLine &&
                    !_viewSession.copyMode &&
                    lineWords != null &&
                    lineWords.isNotEmpty;
                // 行样式必须从环境样式派生：AnimatedDefaultTextStyle 是「替换」
                // 而不是合并（内部直接 `DefaultTextStyle(style: …)`，见 SDK
                // implicit_animations.dart），写字面量会把字体族一并丢成引擎
                // 默认字体——设置页选的「应用字体」（含主题注入的平台默认）会在
                // 整段歌词行失效，与本页其它文字两种字体。这里只覆盖字号/字重/
                // 颜色/行高，其余（字体族、回退链、排版属性）继续继承主题。
                final TextStyle lineBaseStyle = DefaultTextStyle.of(context)
                    .style;
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
                    playbackProvider.seekToPosition(
                      tappedTimestamp.inMilliseconds,
                    );
                    // 复制模式退出 / 暂停中恢复跟随（短抑制）/ 已在跟随，都要
                    // 立即把目标行滚回锚点：seek 后行号可能不变。
                    _viewSession.revealAfterLineTap(index);
                  },
                  child: AnimatedPadding(
                    duration: lineEffectDuration,
                    curve: M3EMotion.emphasizedDecelerate,
                    padding: EdgeInsets.symmetric(
                      vertical: isCurrentLine ? 12.0 : 8.0,
                      // 宽版式（桌面右栏 / 平板两栏）与队列、详情同一内容边距
                      // （16，M3E 口径）；窄版式保持歌词行特有的 40。
                      horizontal: isWideLyricLayout ? 16.0 : 40.0,
                    ),
                    child: AnimatedDefaultTextStyle(
                      duration: lineEffectDuration,
                      curve: M3EMotion.emphasizedDecelerate,
                      style: lineBaseStyle.copyWith(
                        fontSize: lyricFontSize,
                        // M3E 没有 w600 档：当前行 w700、其余 w500，
                        // 保留「高亮行更重」的两级对照（原来 w700/w600）。
                        fontWeight: isCurrentLine
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: baseTextColor,
                        height: 1.1,
                      ),
                      child: AnimatedOpacity(
                        duration: lineEffectDuration,
                        curve: M3EMotion.emphasizedDecelerate,
                        opacity: lyricsSynced
                            ? (isCurrentLine ? 1.0 : 0.8)
                            : 1.0,
                        child: Semantics(
                          // 行是阅读单位：逐字高亮只影响绘画，不做逐词语义；
                          // 自动滚动不请求焦点，也不把行标成 live region。
                          container: true,
                          excludeSemantics: true,
                          label: line.text,
                          selected: isCurrentLine,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (useKaraoke)
                                KaraokeLyricText(
                                  key: _lineTextKeys[index],
                                  words: lineWords,
                                  position: playbackProvider.position,
                                  lead: kLyricDisplayLead,
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
                                // 只有当前行（且页面活跃）做展开 / 收起：
                                // 否则切换翻译开关时几十行 SizeTransition 同时跑。
                                animate: active && isCurrentLine,
                              ),
                            ],
                          ),
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
                        Theme.of(context).colorScheme.surface
                            .withValues(alpha: 0.8),
                        Theme.of(context).colorScheme.surface
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
              bottom:
                  _quickActionsScreenOffset +
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
    // 行高亮 / 自动滚动 / 居中跟随共用同一时间策略（含 200ms 视觉提前量）。
    return LyricTimingPolicy.page.lineIndexAt(
      _session.lines,
      currentPosition,
      isSynced: _session.isSynced,
    );
  }

  /// 翻译 / 罗马音块（挂在主行文本下方，逐行渲染）。
  ///
  /// 通过 [AnimatedSwitcher] + `SizeTransition` 做「淡出 + 收起」：歌词页
  /// 开关切换（翻译 / 罗马音开或关）时扩展行从主行下方展开 / 收起，
  /// 而不是硬切、也不是留下占位。
  ///
  /// [animate] 只为当前行打开：其余行零时长直接切换，避免开关一次让
  /// 几十行 SizeTransition 同时跑（列表越大越明显）。
  Widget _buildExtendedLines({
    required bool showTranslation,
    required String translation,
    required bool showRoma,
    required String roma,
    required TextStyle style,
    required bool animate,
  }) {
    final bool visible = showTranslation || showRoma;
    return AnimatedSwitcher(
      duration: animate
          ? effectDurationOf(context, M3EMotion.short4)
          : Duration.zero,
      switchInCurve: M3EMotion.emphasizedDecelerate,
      switchOutCurve: M3EMotion.emphasizedAccelerate,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topLeft,
        children: [...previousChildren, ?currentChild],
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
                  Text(translation, textAlign: TextAlign.left, style: style),
                ],
                if (showRoma) ...[
                  const SizedBox(height: 2),
                  Text(roma, textAlign: TextAlign.left, style: style),
                ],
              ],
            ),
    );
  }

  /// 复制模式切换：状态机在视图会话，进入时的提示属于页面反馈。
  void _toggleCopyLyricsMode() {
    if (!mounted) return;
    final bool entered = _viewSession.toggleCopyMode();
    if (!entered) return;
    final l10n = AppLocalizations.of(context)!;
    Provider.of<NotificationService>(context, listen: false).showSnackBar(
      l10n.lyricsCopyModeSnackbar,
      duration: const Duration(seconds: 4),
    );
  }

  /// 换源页（歌词 / 音频双 tab）：默认落在歌词 tab。
  Future<void> _showSourceSwapPage() async {
    if (!mounted) return;

    final playbackProvider = Provider.of<PlaybackProvider>(
      context,
      listen: false,
    );
    final currentTrack = playbackProvider.snapshot.current;
    final notificationService = Provider.of<NotificationService>(
      context,
      listen: false,
    );
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

    // 进入新页面前暂停自动滚动（离页期间不跑滚动工作）。
    final bool wasFollowing = _viewSession.following;
    _viewSession.suspendFollow();

    final lyricsProvider = Provider.of<LyricsProvider>(context, listen: false);
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
      // 会话状态已由 saveManual 更新（唯一真相），这里只重置渲染侧簿记；
      // 换源前开启过自动滚动则由会话按 350ms 窗口恢复并滚回当前行。
      _viewSession.adoptReplacementLyrics(restoreFollow: wasFollowing);
      setState(() {
        _lastState = lyricsState;
        _syncLineKeys(lyricsState.lines.length);
      });
      notificationService.showSnackBar(l10n.lyricsSearchAppliedSuccess);
    } else {
      // 未返回歌词或用户取消：恢复打开搜索前的自动滚动状态。
      _viewSession.restoreFollow(wasFollowing: wasFollowing);
    }

    // 打开页面前处于「手动滚动暂停」：返回后继续延迟恢复跟随。
    _viewSession.scheduleResumeIfPaused();
  }

  Future<void> _showLyricsSelectionPage() async {
    if (!mounted) return;

    final playbackProvider = Provider.of<PlaybackProvider>(
      context,
      listen: false,
    );
    final currentTrack = playbackProvider.snapshot.current;
    final notificationService = Provider.of<NotificationService>(
      context,
      listen: false,
    );
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

    // 暂停当前的自动滚动（离页期间不跑滚动工作）。
    final bool wasFollowing = _viewSession.following;
    _viewSession.suspendFollow();

    await ResponsiveNavigation.showSecondaryPage<void>(
      context: context,
      title: l10n.selectLyrics,
      body: LyricsSelectionPage(
        lyrics: _session.lines,
        translations: _session.translations,
        romas: _session.romas,
        isSynced: _session.isSynced,
        showTranslation: lyricsDisplaySettings.pageTranslationEnabled,
        showRoma: lyricsDisplaySettings.pageRomaEnabled,
        trackTitle: trackName,
        artistName: artistName,
        albumCoverUrl: albumCoverUrl,
        trackId: currentTrack.id,
        embedded: true,
      ),
      preferredMode: SecondaryPageMode.sideSheet,
      maxWidth: 520,
      barrierDismissible: false,
    );

    if (!mounted) return;

    _viewSession.restoreFollow(wasFollowing: wasFollowing);

    // 打开页面前处于「手动滚动暂停」：返回后继续延迟恢复跟随。
    _viewSession.scheduleResumeIfPaused();
  }

  // LyricsViewHost：会话的播放事实与效果宿主
  //
  // 会话决定「什么时候」，这里提供播放事实并把滚动 / 播放命令落到真实
  // 控制器与 Provider；滚动几何仍由本侧测量（lyrics_scroll_policy）。

  @override
  Duration get position =>
      Provider.of<PlaybackProvider>(context, listen: false).currentPosition;

  @override
  bool get isPlaying =>
      Provider.of<PlaybackProvider>(context, listen: false).isPlaying;

  @override
  List<LyricLine> get lines => _session.lines;

  @override
  bool get isSynced => _session.isSynced;

  @override
  bool get hasTrack =>
      Provider.of<PlaybackProvider>(context, listen: false).hasTrack;

  @override
  bool get quickActionsEnabled => widget.quickActionsEnabled;

  @override
  bool get active => _active;

  @override
  bool get canScroll => _scrollController.hasClients;

  @override
  PlayMode get currentPlayMode =>
      Provider.of<PlaybackProvider>(context, listen: false).currentMode;

  @override
  void setPlayMode(PlayMode mode) {
    Provider.of<PlaybackProvider>(context, listen: false).setPlayMode(mode);
  }

  @override
  void lightImpact() {
    HapticsService.lightImpact();
  }

  @override
  LyricsViewScheduler get scheduler => _scheduler;
}

/// 生产调度器：帧末回调用 post-frame（与会话的重试节奏一致），延迟窗口
/// 用真实 Timer；两者的取消 / 过期语义都由视图会话负责。
class _WidgetLyricsScheduler implements LyricsViewScheduler {
  @override
  void scheduleFrame(VoidCallback callback) {
    WidgetsBinding.instance.addPostFrameCallback((_) => callback());
  }

  @override
  LyricsTimerHandle startTimer(Duration duration, VoidCallback callback) {
    return _WidgetLyricsTimer(Timer(duration, callback));
  }
}

class _WidgetLyricsTimer implements LyricsTimerHandle {
  _WidgetLyricsTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() {
    _timer.cancel();
  }
}
