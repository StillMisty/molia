import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_providers.dart';
import '../providers/playback_provider.dart';
import 'cover_deck_metrics.dart';
import 'now_playing_summary.dart';
import 'playback_cover_decode.dart';
import 'playback_transport.dart';
import 'player_cover_deck.dart';
import 'player_cover_semantics.dart';
import 'player_morph.dart';
import 'responsive.dart';
import 'seek_bar.dart';
import 'volume_control.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文（与其它行组件同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

class Player extends ConsumerStatefulWidget {
  final bool isLargeScreen;

  /// 封面区横向手势宿主 key（由封面堆叠模块持有）：拖动期间 element 必须
  /// 稳定（识别器不被 dispose），同时供测试精确定位这一层手势。
  static const Key artworkSwipeHostKey = PlayerCoverDeck.swipeHostKey;

  /// 播放页音量入口的稳定 Key（底栏隐藏后音量只在播放页可达）。
  static const Key volumeButtonKey = Key('playerVolumeButton');

  /// 播放页音量弹层的稳定 Key。
  static const Key volumePanelKey = Key('playerVolumePanel');

  /// 顶栏共享元素控制器：为封面/歌名/进度提供锚点并接收隐藏状态。
  final PlayerMorphController? morph;

  /// 小屏完整页的展开进度（0 = 收起高度 0、1 = 完整布局）；为 null 时直接
  /// 渲染完整布局。
  ///
  /// 收起态没有页内迷你播放条：顶栏是移动端唯一的迷你播放器，播放页收起后
  /// 直接让出整块高度给歌词 / 队列 / 信息（壳层顶栏承接封面 / 歌名 / 传输键）。
  /// 这里只负责高度裁剪与完整层透明度，不参与封面飞行。
  final Animation<double>? expandAnimation;

  /// 桌面骨架播放页版式：标题块下补专辑行、进度排上方补传输控制
  /// （移动/平板大屏版式不显示，纵向空间留给歌词）。
  final bool desktopLayout;

  const Player({
    super.key,
    this.isLargeScreen = false,
    this.morph,
    this.expandAnimation,
    this.desktopLayout = false,
  });

  @override
  ConsumerState<Player> createState() => _PlayerState();
}

class _PlayerState extends ConsumerState<Player> with TickerProviderStateMixin {
  Track? _lastTrack;

  // 标题单行 38、进度排 46（滑杆盒 32 + 时间行 2+16 的溢出绘制 + 余量）、
  // 两者间距 14。
  static const double _textSectionHeight = 38;
  static const double _seekSectionHeight = 46;
  static const double _sectionsGap = 14;

  /// 标题 / 进度排预留高度：1.0 字号档 = 98，随 `textScaler` 放大文字段。
  ///
  /// 小屏完整播放器用「可用高 − 预留」反推封面；预留不跟字号时，200% 字号
  /// 会把进度排挤出列（实测 480 宽桌面列溢出 14px）。滑杆盒是固定几何，
  /// 只放大标题行与时间行。
  static double _sectionsReservedHeightFor(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return scaler.scale(_textSectionHeight) +
        (_seekSectionHeight - 18) +
        scaler.scale(18) +
        _sectionsGap;
  }

  /// 播放器内容的横向内边距：标题/专辑/进度排与封面区同一留白。
  ///
  /// 大屏版式里封面两侧是硬边界（导航轨 / 分栏线），封面堆叠按它反推可用
  /// 宽度后不会再压过界（桌面列宽 480 → 可用 432 → 封面边 ≈288）。
  static const double _contentHorizontalPadding = 24;

  /// 大屏封面区纵向留白（上下各一份）：高度预算里的固定占位是估算值，
  /// 字号被放大时会先让封面收缩，而不是把进度排挤出可视区。
  ///
  /// 只有大屏版式留这段余量：小屏展开层会按内容高再算一次封面尺寸，
  /// 「扣掉却不渲染」的高度会被双扣（见 [_smallScreenDeckMetrics]）。
  static const double _largeScreenDeckMargin = 24;

  /// 传输排 / 进度排的横向内边距：两排首尾控件（播放模式 / 音量）的视觉
  /// 边缘对齐。
  static const double _controlsRowPadding = 12;

  /// 小屏封面尺寸预算：容器高只扣标题/进度排。
  ///
  /// 与 [_playerContentHeight] 必须严格互逆：展开层的完整子树被
  /// `OverflowBox` 按内容高强制布局，并在这个高度上**再算一次**封面尺寸——
  /// 任何「扣掉却不渲染」的纵向余量都会双扣（art 变小、容器底部留白），
  /// 所以小屏的可用高度不能预扣留白。
  static CoverDeckMetrics _smallScreenDeckMetrics(
    double maxWidth,
    double maxHeight,
    double reservedHeight,
  ) => coverDeckMetricsFor(
    availableWidth: maxWidth,
    availableHeight: maxHeight.isFinite
        ? max(0.0, maxHeight - reservedHeight)
        : double.infinity,
  );

  /// 大屏封面可用高度：容器高扣掉固定占位与封面区上下留白（未约束宿主返回
  /// 无限高，纵向不参与约束）。
  static double _largeScreenDeckAvailableHeight(
    double maxHeight,
    double reserved,
  ) => maxHeight.isFinite
      ? max(0.0, maxHeight - reserved - _largeScreenDeckMargin * 2)
      : double.infinity;

  /// 完整播放器内容高度：高度贴合内容（封面堆叠 + 标题/进度排），
  /// 避免大片留白；是 [_smallScreenDeckMetrics] 的逆函数。
  double _playerContentHeight(double art, double reservedHeight) =>
      art * coverDeckVerticalFactor + reservedHeight;

  /// 切歌入场：M3E no-overshoot spatial 弹簧（aospSpatial 380/1.0）驱动文字
  /// 轻量上移落位 + 同源淡入，与封面切歌同帧启动；连续切歌带速度续跑。
  /// 弹簧保持无过冲是刻意的设计意图。
  late SingleMotionController _trackEntrance;

  /// 页面可见性（TickerMode）：隐藏时标题入场直接落位，不冻结等回到页面再播。
  bool _tickersEnabled = true;

  @override
  void initState() {
    super.initState();
    _trackEntrance = SingleMotionController(
      motion: SpringMotion(
        M3EMotion.aospSpatial.toDescription(),
        snapToEnd: true,
      ),
      vsync: this,
      initialValue: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
  }

  @override
  void dispose() {
    _trackEntrance.dispose();
    super.dispose();
  }

  /// 歌手展示名（唯一词表 [Track.artistLabel]；无有效歌手回退 l10n 兜底）。
  static String _artistsLabel(BuildContext context, Track track) {
    final label = track.artistLabel;
    return label.isEmpty ? _l10n(context).unknownArtist : label;
  }

  /// 封面模块的切歌联动（切歌帧的 post-frame 触发）：非拖动中切换时启动
  /// 标题入场（拖动中让位拖动预览）。旧进度预览的清理由
  /// `SeekPreviewController` 自行订阅曲目身份完成。
  void _handleTrackSwapped(bool duringDrag) {
    if (duringDrag) return;
    if (_tickersEnabled) {
      _trackEntrance.animateTo(1, from: 0, withVelocity: 0);
    } else {
      // 页面不可见：直接落位，避免回到播放页时标题再弹一遍。
      _trackEntrance.value = 1.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(
      playbackProvider.select((provider) => provider.snapshot.current),
    );

    final playback = ref.read(playbackProvider);

    // 展示曲目沿用上一次非空曲目：换歌瞬间快照可能短暂为空，直接回退到
    // 「无曲目播放页」会让封面 / 标题闪一帧。
    final displayTrack = track ?? _lastTrack;
    if (track != null) {
      _lastTrack = track;
    }

    if (widget.isLargeScreen) {
      return RepaintBoundary(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: playbackCoverMaxLogicalEdge,
            ),
            child: _buildLargeScreenPlayerLayout(displayTrack, playback),
          ),
        ),
      );
    }

    final expand = widget.expandAnimation;
    if (expand == null) {
      return RepaintBoundary(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: double.infinity),
            child: _buildSmallScreenPlayerLayout(
              displayTrack,
              playback,
              morph: widget.morph,
            ),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: _buildExpandableSmallScreenLayout(displayTrack, playback, expand),
    );
  }

  /// 小屏完整播放器：三封面堆叠 → 标题/作者（单行）→ 可拖动进度排。
  ///
  /// 高度感知：可用高度（NowPlaying 传入的 maxHeight）不足时收缩封面，
  /// 避免进度排把歌词区挤出屏幕。小屏封面是全宽主场（两侧没有相邻列），
  /// 可用宽就是容器宽；纵向预算与 [_playerContentHeight] 互逆（见
  /// [_smallScreenDeckMetrics]）。
  Widget _buildSmallScreenPlayerLayout(
    Track? displayTrack,
    PlaybackProvider playback, {
    PlayerMorphController? morph,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _smallScreenDeckMetrics(
          constraints.maxWidth,
          constraints.maxHeight,
          _sectionsReservedHeightFor(context),
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageCoverSemantics(
              track: displayTrack,
              child: PlayerCoverDeck(
                displayTrack: displayTrack,
                artDimension: metrics.artDimension,
                stackDimension: metrics.stackWidth,
                stackHeight: metrics.stackHeight,
                isLargeScreen: widget.isLargeScreen,
                morph: morph,
                onTrackSwapped: _handleTrackSwapped,
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _contentHorizontalPadding,
              ),
              child: _buildTrackInfo(context, displayTrack, playback),
            ),
            const SizedBox(height: 2),
            _buildSeekBar(),
          ],
        );
      },
    );
  }

  /// 收起 / 展开：同一控制器驱动容器高度与完整层透明度。
  ///
  /// 收起高度是 **0**：移动端顶栏条是唯一的迷你播放器，播放页收起后不再
  /// 保留页内迷你条——那会与顶栏重复一层「封面 + 歌名 + 传输键」，还把歌词
  /// 区往下压 72dp。完整层始终按最终高度布局、顶部对齐裁剪，高度连续过渡时
  /// 封面尺寸不会重排。
  ///
  /// 封面飞行不在页内做：顶栏 ⇄ 展开位置由壳层的 `PlayerMorphFlight` 统一
  /// 承接（见 `app_shell.dart`）。收起态也把 [Player.morph] 交给封面 deck，
  /// 让壳层在飞行起止两端都能抓到播放页封面的真实矩形。
  ///
  /// [fullHeight] 就是完整层的内容高：完整层在这个高度上重算封面尺寸，
  /// 两者必须同一口径（见 [_smallScreenDeckMetrics]），否则展开态封面会
  /// 比外层预算小一截、容器底部多出等量空白。
  Widget _buildExpandableSmallScreenLayout(
    Track? displayTrack,
    PlaybackProvider playback,
    Animation<double> expand,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double reservedHeight = _sectionsReservedHeightFor(context);
        final double fullHeight = _playerContentHeight(
          _smallScreenDeckMetrics(
            constraints.maxWidth,
            constraints.maxHeight,
            reservedHeight,
          ).artDimension,
          reservedHeight,
        );
        // 完整层在这里构建一次，弹簧逐帧只改下面的包装层（高度 / 裁剪 /
        // 透明度 / 点击门控）：整棵播放器不随每一帧动画重建。
        final Widget fullLayer = _buildSmallScreenPlayerLayout(
          displayTrack,
          playback,
          morph: widget.morph,
        );
        return AnimatedBuilder(
          animation: expand,
          builder: (context, _) {
            // motor 弹簧进度即运动曲线；截断 0..1：
            // 高度不过冲，避免内容区随过冲回流；透明度由同一进度派生。
            final double t = expand.value.clamp(0.0, 1.0);
            final double height = fullHeight * t;
            final double fullOpacity = Curves.easeInCubic.transform(
              ((t - 0.35) / 0.65).clamp(0.0, 1.0),
            );
            return SizedBox(
              height: height,
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // 完整层：始终按最终高度布局，避免过渡中重排封面。
                    Positioned.fill(
                      child: OverflowBox(
                        minHeight: fullHeight,
                        maxHeight: fullHeight,
                        alignment: Alignment.topCenter,
                        child: ExcludeSemantics(
                          // 收起态（高度 0）整层不可读也不可点：读屏 / 点击
                          // 只能落在顶栏承接下来的播放条上。
                          excluding: t < 0.5,
                          child: IgnorePointer(
                            ignoring: t < 0.5,
                            child: Opacity(
                              opacity: fullOpacity,
                              // 展开 / 收起逐帧只改这里的透明度与高度；播放器
                              // 内容本身不脏，独立图层让每帧只做合成，不再
                              // 重放整棵播放器（封面 / 阴影 / 进度）的绘制。
                              child: RepaintBoundary(child: fullLayer),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 进度排：收藏（左）+ 可拖动波浪进度（中）+ 播放模式 / 音量（右）。
  ///
  /// 拖动期间本地预览、松手才提交 seek；控制器生命周期与低频快照订阅都在
  /// `PlaybackSeekBar` 内，这里只决定版式与时间标签档位。波浪只在这一处
  /// （播放页主场）开启，顶栏 / 底栏的进度线默认平直，避免全局 60fps 装饰动画。
  ///
  /// 播放模式常显在进度排：播放域动作一步可达，当前模式一眼可见
  /// （见 ADR-0007 的分域与 ADR-0030 的取舍）。
  ///
  /// 音量入口只在「桌面平台 + 没有传输排」的单栏播放页补：桌面骨架分栏
  /// （[Player.desktopLayout]）的音量在传输排，底栏窄窗又会主动去掉音量，
  /// 不补这一处 480–839 的桌面窗口就没有任何屏幕音量控件。
  Widget _buildSeekBar() {
    final bool showVolume = isDesktopPlatform() && !widget.desktopLayout;
    return Padding(
      // 纵向不留内边距：上方 2dp 由外层排布给（小屏 / 大屏两套版式都是
      // `SizedBox(height: 2)`），下方 2dp 由时间行自己的呼吸位承担——进度排
      // 的纵向预算就是滑杆盒子本身。
      padding: const EdgeInsets.symmetric(horizontal: _controlsRowPadding),
      child: Row(
        // 图标与进度条同一行居中：进度排的布局高度就是滑杆盒（时间行是溢出
        // 绘制、不参与这一行的居中），默认居中即图标中线对齐条的中线。
        children: [
          _buildFavoriteButton(),
          const SizedBox(width: 4),
          // 播放页版式：时间挪到条下方，横向空间全给进度条。
          const Expanded(
            child: PlaybackSeekBar(
              timeLabels: SeekTimeLabels.below,
              wavy: true,
            ),
          ),
          const SizedBox(width: 4),
          // 与收藏同一套简单图标按钮；模式图标 / 标签由共享模块唯一映射。
          const PlaybackModeButton(visualSize: Size(44, 44)),
          if (showVolume) ...[
            const SizedBox(width: 4),
            // 稳定 key 与桌面骨架传输排同一个（底栏隐藏后音量只在这里可达）。
            const VolumeControl(
              buttonKey: Player.volumeButtonKey,
              panelKey: Player.volumePanelKey,
            ),
          ],
        ],
      ),
    );
  }

  /// 标题/作者：单行「歌名 · 作者」+ 无过冲轻量入场（上移 14px）。
  Widget _buildTrackInfo(
    BuildContext context,
    Track? displayTrack,
    PlaybackProvider playback,
  ) {
    return AnimatedBuilder(
      animation: _trackEntrance,
      builder: (context, child) {
        final t = _trackEntrance.value;
        return Transform.translate(
          offset: Offset(0, (1 - t) * 14),
          child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
        );
      },
      child: _buildTrackInfoText(context, displayTrack, playback),
    );
  }

  /// 标题块：桌面版式是「歌名 / 作者」两行，移动 / 平板大屏是「歌名 · 作者」
  /// 单行（那里纵向空间优先让给歌词）。
  ///
  /// 标题块不带左侧竖条：它与进度把手同宽、同色、同形，上下相邻时会被读成
  /// 重复元素（用户反馈的「两根竖条」），且形似可拖动的把手却不可交互；
  /// 强调色只留给可交互控件（波浪进度/把手）。字阶 / 截断 / 颜色契约由
  /// `now_playing_summary.dart` 的播放页版式统一。
  Widget _buildTrackInfoText(
    BuildContext context,
    Track? displayTrack,
    PlaybackProvider playback,
  ) {
    final header =
        displayTrack?.title ??
        playback.lastPlayedTrackName ??
        _l10n(context).noCurrentTrackPlaying;
    final artistText = displayTrack != null
        ? _artistsLabel(context, displayTrack)
        : playback.lastPlayedArtists ?? _l10n(context).unknownArtist;

    return NowPlayingTrackText.page(
      title: header,
      artist: artistText,
      stacked: widget.desktopLayout,
    );
  }

  /// 本地收藏按钮：加入/移出默认收藏列表（无当前曲目/资料库时隐藏）。
  ///
  /// 播放页进度排用 44 视觉格（顶栏 / 底栏的迷你位没有收藏键）。
  Widget _buildFavoriteButton() => const NowPlayingFavoriteButton(
    size: M3EIconButtonSize.sm,
    visualSize: Size(44, 44),
  );

  /// 大屏全屏播放器：与小屏同构（三封面堆叠 → 歌名/作者 → 可拖动进度排），
  /// 封面按两轴可用空间自适应。
  Widget _buildLargeScreenPlayerLayout(
    Track? displayTrack,
    PlaybackProvider playback,
  ) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 标题块高度预算：桌面版式是两行（歌名 + 作者），移动 / 平板大屏单行。
        // 预算随 textScaler 放大：固定值会把 200% 字号的标题块按实际高度占位、
        // 封面却仍按旧预算吃满，矮窗口里把进度排（含条下方时间行）顶出可视区。
        final double textScale = MediaQuery.textScalerOf(context).scale(1.0);
        final double textSectionFixedHeight =
            (widget.desktopLayout ? 52.0 : 56.0) * textScale;
        const double spacingBelowArt = 2.0;
        // 桌面版式多出的传输控制排（md 播放键 56）与标题块间距 8：封面可用
        // 高度要扣掉，否则矮窗口里进度排会被挤出可视区。同样随字号放大预留：
        // 大字号下封面让位，而不是把下方内容压出边界。
        final double desktopExtrasHeight = widget.desktopLayout
            ? 64.0 * textScale
            : 0.0;

        // 封面两侧与文字块共用同一内边距：大屏封面的左右是硬边界
        // （导航轨 / 分栏线），堆叠不能贴上去。
        final metrics = coverDeckMetricsFor(
          availableWidth: constraints.maxWidth - _contentHorizontalPadding * 2,
          availableHeight: _largeScreenDeckAvailableHeight(
            constraints.maxHeight,
            textSectionFixedHeight +
                _seekSectionHeight +
                spacingBelowArt +
                desktopExtrasHeight,
          ),
        );

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            PageCoverSemantics(
              track: displayTrack,
              child: PlayerCoverDeck(
                displayTrack: displayTrack,
                artDimension: metrics.artDimension,
                stackDimension: metrics.stackWidth,
                stackHeight: metrics.stackHeight,
                isLargeScreen: widget.isLargeScreen,
                morph: widget.morph,
                onTrackSwapped: _handleTrackSwapped,
              ),
            ),
            const SizedBox(height: spacingBelowArt),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _contentHorizontalPadding,
              ),
              child: _buildTrackInfo(context, displayTrack, playback),
            ),
            if (widget.desktopLayout) ...[
              const SizedBox(height: 8),
              _buildTransportRow(),
            ],
            const SizedBox(height: spacingBelowArt),
            _buildSeekBar(),
          ],
        );
      },
    );
  }

  /// 桌面骨架播放页：进度排上方补传输控制（底栏也有，但播放页是「操作
  /// 主场景」，与移动端把控制放在播放器里同一意图）。
  ///
  /// 底栏进播放页会隐藏（沉浸主场），音量必须在这一排同样可达；传输三键
  /// 居中（播放键是这一列的视觉锚点），音量作为次级控件贴右缘。三个键的
  /// 启用谓词 / 图标 / 标签 / 触感全在共享传输模块，这里只管布局。
  Widget _buildTransportRow() {
    return SizedBox(
      // 撑满列宽：传输三键按列居中，音量贴列右缘（Stack 只按最大子项定宽，
      // 不撑满就会缩到三键那一小条上）。
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PlaybackPreviousButton(),
              SizedBox(width: 8),
              PlaybackPlayPauseButton(
                variant: M3EIconButtonVariant.tonal,
                size: M3EIconButtonSize.md,
              ),
              SizedBox(width: 8),
              PlaybackNextButton(),
            ],
          ),
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                // 与进度排右侧播放模式同一内边距：两排右缘对齐。
                padding: const EdgeInsets.only(right: _controlsRowPadding),
                child: VolumeControl(
                  buttonKey: Player.volumeButtonKey,
                  panelKey: Player.volumePanelKey,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
