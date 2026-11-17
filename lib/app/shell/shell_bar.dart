part of 'app_shell.dart';

/// 顶栏头部：左侧当前曲目封面（无封面回退音符图标），旁边歌名 + 作者。
///
/// 点击整条头部进入播放页（与点底栏「播放」同路径，触发共享封面飞行）；
/// 播放页激活（或飞行中）时交叉淡出为应用图标 + 自定义应用名，不响应点击。
class _ShellBarHeader extends StatelessWidget {
  const _ShellBarHeader({
    required this.morph,
    required this.reveal,
    required this.onOpenPlayer,
  });

  final PlayerMorphController morph;

  /// 曲目信息区入场进度（与播放/下一首按钮共用一根弹簧，见 [_BarHeaderReveal]）。
  final _BarHeaderReveal reveal;

  /// 进入播放页。点击区域覆盖封面 + 歌名整条：封面 40×40 仍达不到 48dp
  /// 的独立触控目标，也不符合迷你条「点哪都进播放页」的惯例。
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    // 无曲目标题时信息区本来就回退应用名，不做入场动画（避免同文案
    // 位移淡入与标题淡出叠影）。
    final hasTrackTitle = context.select<PlaybackProvider, bool>((provider) {
      final track = provider.snapshot.current;
      return track != null && track.title.isNotEmpty;
    });
    return AnimatedBuilder(
      animation: morph,
      builder: (context, _) {
        final showTrack = !morph.barHeaderHidden;
        // 封面与歌名+作者两行文本等高（titleMedium 24 + labelSmall 16）。
        // 点击语义与 12dp 间距由摘要模块收口，这里只给封面槽叠加品牌标志。
        return NowPlayingSummary(
          onTap: showTrack ? onOpenPlayer : null,
          cover: SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              fit: StackFit.expand,
              children: [
                NowPlayingCover.current(
                  size: 40,
                  flightKey: morph.barCoverKey,
                  hidden: !showTrack,
                ),
                AnimatedOpacity(
                  // 切歌信息出现时品牌标志瞬时让位（零时长不跑曲线）；回退时
                  // 短淡入，减弱动效下两端都硬切。
                  duration: effectDurationOf(
                    context,
                    showTrack ? Duration.zero : M3EMotion.short3,
                  ),
                  curve: M3EMotion.emphasizedDecelerate,
                  opacity: showTrack ? 0 : 1,
                  child: ColorFiltered(
                    // 同 MoliaMark：Image.color 在 Impeller 下会引入
                    // 1px 边缘杂线（见已知坑 19），用 ColorFiltered 着色。
                    colorFilter: ColorFilter.mode(
                      Theme.of(context).colorScheme.onSurface,
                      BlendMode.srcIn,
                    ),
                    child: Image.asset(
                      'assets/icons/adaptive_icon_monochrome.png',
                    ),
                  ),
                ),
              ],
            ),
          ),
          info: hasTrackTitle
              ? _BarHeaderTransition(reveal: reveal, showTrack: showTrack)
              : const NowPlayingAppTitle(),
        );
      },
    );
  }
}

/// 顶栏曲目信息区（歌名/作者 + 播放/下一首按钮）的共享入场进度。
///
/// 一根 expressive spatial 弹簧（800 / 0.6，轻微过冲，`snapToEnd` 落定精确
/// 吸附）从 0（隐藏）到 1（展示）；消费面把进度 clamp 到 0..1 后派生
/// 位移 / 缩放与透明度（effects 不过冲）。文本与按钮是两个兄弟子树，
/// 弹簧由壳层 State 持有后分别消费；快速连切靠 motor 中途重定向续接。
class _BarHeaderReveal extends ChangeNotifier {
  _BarHeaderReveal({required TickerProvider vsync, required bool revealed})
    : _motion = SingleMotionController(
        motion: SpringMotion(
          M3EMotion.expressiveSpatialFast.toDescription(),
          snapToEnd: true,
        ),
        vsync: vsync,
        initialValue: revealed ? 1 : 0,
      ) {
    _motion.addListener(notifyListeners);
  }

  final SingleMotionController _motion;

  /// 原始弹簧进度（可能短暂过冲 1；消费面自行 clamp）。
  double get progress => _motion.value;

  void setRevealed(bool value) => _motion.animateTo(value ? 1 : 0);

  @override
  void dispose() {
    _motion.removeListener(notifyListeners);
    _motion.dispose();
    super.dispose();
  }
}

/// 顶栏文本区转场：歌名 + 作者作为一块整体入场（不错峰），应用名出场
/// 先行走短时长淡出（fade-through 先后节奏，消除两段文字长时间叠影）。
///
/// 入场方向（曲目信息）：expressive spatial 弹簧驱动 −6dp → 0 位移，
/// 透明度从同一根弹簧进度 clamp 0..1（spatial 与 effects 同帧耦合）。
/// 出场方向（应用名）：`short2` + `emphasizedAccelerate` 先走淡出
/// （effects 保持时长+曲线，不走弹簧）；减弱动效时直接跳变。
class _BarHeaderTransition extends StatelessWidget {
  const _BarHeaderTransition({required this.reveal, required this.showTrack});

  final _BarHeaderReveal reveal;

  /// true = 展示曲目信息（应用名出场中）。
  final bool showTrack;

  /// 入场横向位移幅度（dp）：4–8dp 区间，避免与封面飞行的零速度交接打架。
  static const double _offsetX = 6;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, _) {
        final t = reveal.progress.clamp(0.0, 1.0);
        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            Transform.translate(
              offset: Offset(-_offsetX * (1 - t), 0),
              child: Opacity(
                opacity: t,
                child: const NowPlayingTrackText.bar(),
              ),
            ),
            AnimatedOpacity(
              // 出场先走（short2），入场稍慢（short3）：两段文字不错峰叠影。
              duration: effectDurationOf(
                context,
                showTrack ? M3EMotion.short2 : M3EMotion.short3,
              ),
              curve: showTrack
                  ? M3EMotion.emphasizedAccelerate
                  : M3EMotion.emphasizedDecelerate,
              opacity: showTrack ? 0 : 1,
              child: const NowPlayingAppTitle(),
            ),
          ],
        );
      },
    );
  }
}

/// 顶栏「播放/暂停」按钮（非播放页）：图标随播放态切换；无曲目（含冷启动
/// 恢复态）时禁用，与「下一首」同一契约。启用谓词 / 图标 / 标签 / 触感与
/// 命令都在共享传输模块，`select` 只订阅 hasTrack / 播放态，不触发整个
/// Shell 重建。
///
/// 顶栏唯一的高亮按钮（tonal）：一屏只留一个视觉重点，其余图标无底色。
/// 入场与歌名/作者共用同一根弹簧：0.92→1 缩放 pop + 透明度同步。
class _BarPlayPauseButton extends StatelessWidget {
  const _BarPlayPauseButton({required this.reveal});

  final _BarHeaderReveal reveal;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, _) => _BarRevealTransition(
        progress: reveal.progress,
        child: const PlaybackPlayPauseButton(
          variant: M3EIconButtonVariant.tonal,
        ),
      ),
    );
  }
}

/// 顶栏「下一首」按钮（非播放页）：无曲目（含冷启动恢复态）时禁用，
/// 避免空操作误导；订阅与命令收在共享传输模块，不触发整个 Shell 重建。
///
/// 无底色标准样式：顶栏唯一高亮留给旁边的播放/暂停。
/// 入场与播放/暂停按钮同一根弹簧（与歌名/作者同源）。
class _BarNextButton extends StatelessWidget {
  const _BarNextButton({required this.reveal});

  final _BarHeaderReveal reveal;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, _) => _BarRevealTransition(
        progress: reveal.progress,
        child: const PlaybackNextButton(),
      ),
    );
  }
}

/// 顶栏按钮的入场表现：缩放 0.92→1（幅度 ≤8%）+ 透明度同源 clamp 0..1。
/// 完全隐藏时不参与命中测试（flight 期间按钮已挂载但不可见）。
class _BarRevealTransition extends StatelessWidget {
  const _BarRevealTransition({required this.progress, required this.child});

  /// 原始弹簧进度（可能短暂过冲）。
  final double progress;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = progress.clamp(0.0, 1.0);
    return IgnorePointer(
      ignoring: t <= 0,
      child: Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
      ),
    );
  }
}
