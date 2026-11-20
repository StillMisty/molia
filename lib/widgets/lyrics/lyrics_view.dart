import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:motor/motor.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../domain/models/track.dart';
import '../../domain/models/lyric_line.dart';
import '../../domain/models/play_mode.dart';
import '../../pages/source_swap_page.dart';
import '../../providers/lyrics_provider.dart';
import '../../providers/playback_provider.dart';
import '../../services/haptics.dart';
import '../../services/lyrics_display/lyric_timing_policy.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/notification_service.dart';
import '../../theme/motion_policy.dart';
import '../responsive.dart';
import '../lyrics_display_settings_action.dart';
import '../lyrics_scroll_policy.dart';
import '../lyrics_selection_page.dart';
import '../lyrics_source_search_view.dart';
import '../lyrics_view_session.dart';
import '../playback_selectors.dart';
import '../scroll_edge_fade.dart';
import '../shell_page_visibility.dart';
import 'lyrics_controls.dart';
import 'lyrics_line_tile.dart';
import 'lyrics_scroll.dart';

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

  /// 歌词会话模块：会话真相的唯一来源（本组件只消费，不维护加载镜像）。
  LyricsProvider? _lyricsProvider;

  /// 上一次已应用的会话状态（渲染侧簿记：内容变了才重置滚动 / 行 key）。
  LyricsState _lastState = LyricsState.idle;

  /// 当前曲目的会话状态（曲目变化由组合根经 `ensureForTrack` 推进）。
  LyricsState get _session => _lyricsProvider?.state ?? LyricsState.idle;

  /// 会话是否正在加载（渲染侧直接读该状态）。
  bool get _isLoading => _session.status == LyricsStatus.loading;

  /// 歌词页视图会话：跟随 / 复制模式 / 操作栏 / 滚动重试的唯一状态机。
  ///
  /// 本 State 同时实现 [LyricsViewHost]：播放事实从这里读取，滚动几何与
  /// 弹簧仍在本侧执行；会话只决定时机（见 lyrics_view_session.dart）。
  late final LyricsViewSession _viewSession;

  /// 滚动宿主：ScrollController / 行 key / 视口测量与落点。
  late final LyricsScrollDriver _scroll;

  /// 生产调度器：帧末回调用 post-frame，延迟窗口用真实 Timer。
  final _WidgetLyricsScheduler _scheduler = _WidgetLyricsScheduler();

  /// 页面当前是否活跃：nearest [ShellPageVisibility] 为 true（壳层可见且
  /// 宿主播放页停在歌词 tab；见 nowplaying.dart 的 tab 门控包装）。
  ///
  /// build 期写入、post-frame 回调读取：隐藏页即使还有排队中的帧末回调，
  /// 也不能再滚动 / 起弹簧。隐藏时 [PositionLineIndexBuilder] 不订阅进度，
  /// 因此本页在隐藏期间不会再因播放进度重建。
  bool _active = true;

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
    _scroll = LyricsScrollDriver(
      externalController: widget.controller,
      topOverlay: _topOverlay,
      bottomOverlay: _bottomOverlay,
      canScheduleWork: () => mounted && _active,
      onScrollableChanged: _viewSession.setScrollable,
    );
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
    _scroll.jumpToTop();
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
    _scroll.dispose();
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
    _scroll.syncLineKeys(targetLength);
  }

  String _extractArtistNames(AppLocalizations l10n, Track track) {
    final label = track.artistLabel;
    return label.isEmpty ? l10n.unknownArtist : label;
  }

  /// 顶栏遮挡：渐隐带 + 系统状态栏。
  double _topOverlay() =>
      kTopFadeBandHeight + MediaQuery.paddingOf(context).top;

  /// 底栏遮挡：快捷操作栏（FAB menu 的 FAB）可见时 = 屏边距 + FAB 尺寸
  /// + 底部安全区；隐藏时为 0。
  double _bottomOverlay() {
    if (!_viewSession.quickActionsBarVisible) return 0.0;
    final padding = MediaQuery.paddingOf(context);
    return padding.bottom + _quickActionsScreenOffset + _quickActionsFabSize;
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

  List<M3EFabMenuItem> _buildQuickActions(AppLocalizations l10n) {
    return buildLyricsQuickActionItems(
      l10n: l10n,
      hasLyrics: _session.lines.isNotEmpty,
      synced: _session.isSynced,
      following: _viewSession.following,
      copyMode: _viewSession.copyMode,
      onSwapSource: () => unawaited(_showSourceSwapPage()),
      onToggleCopyMode: () {
        HapticsService.lightImpact();
        _toggleCopyLyricsMode();
      },
      onPoster: () => unawaited(_showLyricsSelectionPage()),
      onDisplaySettings: () => unawaited(showLyricsDisplaySettings(context)),
      onCenterCurrentLine: _centerCurrentLine,
    );
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
      _scroll.scheduleScrollabilityCheck();
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
                child: LyricsLoadingState(message: l10n.lyricsLoading),
              ),
            // 空态（取词失败 / 没找到词）：俏皮话提示，动作由 FAB menu
            // （换歌词 / 显示设置）承担；不拦截手势。
            if (_session.lines.isEmpty && !_isLoading && currentTrackId != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: LyricsEmptyState(message: l10n.lyricsEmptyState),
                ),
              ),
            ListView.builder(
              key: _scroll.listViewKey,
              controller: _scroll.controller,
              physics: const BouncingScrollPhysics(),
              scrollCacheExtent: const ScrollCacheExtent.pixels(
                1000.0,
              ), // 预建附近行，减少兜底跳转
              padding: EdgeInsets.only(
                top: 80 + MediaQuery.paddingOf(context).top,
                bottom: 40 + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: _session.lines.length + 1,
              itemBuilder: (context, index) {
                if (index == _session.lines.length) {
                  return SizedBox(height: _scroll.tailSpacePixels);
                }
                final bool isWideLyricLayout = context
                    .layoutType(ResponsivePageType.detail)
                    .preferTwoPane;
                final line = _session.lines[index];
                final bool lyricsSynced = _session.isSynced;
                final bool isCurrentLine =
                    lyricsSynced && index == currentLineIndex;
                final bool isPastLine =
                    lyricsSynced && index < currentLineIndex;
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

                return LyricsLineTile(
                  lineKey: _scroll.lineKeys[index],
                  textKey: _scroll.lineTextKeys[index],
                  line: line,
                  isSynced: lyricsSynced,
                  isPastLine: isPastLine,
                  isCurrentLine: isCurrentLine,
                  active: active,
                  copyMode: _viewSession.copyMode,
                  wideLayout: isWideLyricLayout,
                  showTranslation: showTranslation,
                  translation: lineTranslation,
                  showRoma: showRoma,
                  roma: lineRoma,
                  effectDuration: lineEffectDuration,
                  position: playbackProvider.position,
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
                );
              },
            ),
            // 顶部渐隐：歌词行滑到屏顶 chrome 下时淡出，不是硬切。覆盖层
            // 自带 IgnorePointer / ExcludeSemantics（不接收手势），颜色统一取
            // colorScheme.surface，避免两处背景色来源漂移。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 40 + MediaQuery.paddingOf(context).top,
              child: ScrollEdgeFade(
                edge: FadeEdge.top,
                extent: 40 + MediaQuery.paddingOf(context).top,
              ),
            ),
            // 底部渐隐：歌词行从右下快捷操作后面滚过时淡出，不是硬切。
            // 必须排在 FAB 之前（先绘制）：渐隐只压歌词，不压住可点的
            // 操作胶囊——页面级叠一层会把 FAB 下缘刷成半透明 surface。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 40 + MediaQuery.paddingOf(context).bottom,
              child: ScrollEdgeFade(
                edge: FadeEdge.bottom,
                extent: 40 + MediaQuery.paddingOf(context).bottom,
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
                  MediaQuery.paddingOf(context).bottom,
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
                                    MediaQuery.paddingOf(context).bottom),
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
  bool get canScroll => _scroll.hasClients;

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

  /// 滚到当前行：把主行文本块的顶边锚定在会话给出的锚点。
  @override
  bool scrollToLine(int index) {
    if (!mounted) return false;
    return _scroll.scrollToLine(index, context: context);
  }

  @override
  void jumpTowardLine(int currentLineIndex) {
    final durationMs = Provider.of<PlaybackProvider>(
      context,
      listen: false,
    ).snapshot.current?.duration?.inMilliseconds;
    _scroll.jumpTowardLine(
      currentLineIndex: currentLineIndex,
      lines: _session.lines,
      durationMs: durationMs,
    );
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
