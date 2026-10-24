/// 桌面骨架的常驻底部播放条（80dp）。
///
/// 左：封面 + 歌名/作者 + 收藏（点击进播放页，封面与播放页共享元素飞行）；
/// 中：上一首 / 播放暂停 / 下一首 + 可拖波浪进度 + 时间；
/// 右：播放模式 + 音量（图标 + 弹出滑杆）+ 队列。
///
/// 只在非播放页出现：播放页是沉浸主场，整条由壳层让位（见
/// `app/desktop/desktop_shell.dart` 的 `bottomNavigationBar`）。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/play_mode.dart';
import '../../providers/playback_provider.dart';
import '../../services/haptics.dart';
import '../../widgets/icon_swap.dart';
import '../../widgets/now_playing_summary.dart';
import '../../widgets/player_morph.dart';
import '../../widgets/seek_bar.dart';
import '../../widgets/seek_preview.dart';
import '../../widgets/volume_control.dart';

/// 常驻底部播放条。
class DesktopNowPlayingBar extends StatelessWidget {
  const DesktopNowPlayingBar({
    super.key,
    required this.morph,
    required this.onOpenPlayer,
    required this.onOpenQueue,
  });

  /// 稳定 Key：测试定位整条播放条（桌面骨架存在性）。
  static const Key shellKey = Key('desktopNowPlayingBar');

  /// 队列入口按钮的稳定 Key。
  static const Key openQueueKey = Key('desktopOpenQueue');

  /// 音量按钮的稳定 Key。
  static const Key volumeButtonKey = Key('desktopVolumeButton');

  /// 音量弹层（滑杆 + 静音开关）的稳定 Key。
  static const Key volumePanelKey = Key('desktopVolumePanel');

  /// 播放条固定高度（桌面骨架底栏档位）。
  static const double barHeight = 80;

  /// 封面槽边长：与顶栏 40 档同源外观（[CoverAppearance.bar]），尺寸放大
  /// 到 48 与迷你条一致——底栏是常驻信息位，比顶栏需要更强的可读性。
  static const double coverSize = 48;

  /// 三个分区（左信息 / 中控制 / 右动作）互不挤压的宽度下限：更窄时整条
  /// 按比例缩小渲染（[FittedBox] scaleDown）。Linux / Windows 原生侧已设
  /// 最小窗口 900×600（见 `services/window/window_chrome_io.dart`），这里
  /// 是兜底：macOS / 测试 / 任何更小的宿主都不该出现 RenderFlex 溢出。
  static const double _minComfortableWidth = 720;

  /// 顶栏 ↔ 播放页共享元素控制器：封面锚点与「播放页激活时收起封面」。
  final PlayerMorphController morph;

  /// 点击左区进入播放页。
  final VoidCallback onOpenPlayer;

  /// 队列入口：跳播放页并让页内右栏切到队列 tab。
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: _TrackSection(
              morph: morph,
              onOpenPlayer: onOpenPlayer,
            ),
          ),
          // 中区（传输三键 + 进度排）吃右区之外的余量：右区按内容宽贴右缘，
          // 省下的空白全归进度排——进度条是这条底栏上唯一需要宽度的控件。
          const Expanded(flex: 6, child: _BarControls()),
          _BarActions(onOpenQueue: onOpenQueue),
        ],
      ),
    );
    // 容器色取 surfaceContainer：与顶栏 AppBar / M3E 导航栏的「外壳容器」
    // 语义一致——播放条是壳层家具，不参与页面内容的 surface 层级。
    return Material(
      color: scheme.surfaceContainer,
      child: SizedBox(
        height: barHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= _minComfortableWidth) return content;
            return FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(width: _minComfortableWidth, child: content),
            );
          },
        ),
      ),
    );
  }
}

/// 左区：封面 + 歌名/作者 + 收藏。
///
/// 封面复用顶栏那套隐藏语义（[PlayerMorphController.barHeaderHidden]：
/// 播放页激活或飞行中淡出，避免与页面大封面重复）；但封面槽**占位宽度
/// 不变**——收起时整条文字区不跳动，也保证共享飞行的起止锚点稳定。
/// 摘要内容（封面 / 文本 / 收藏）由 `now_playing_summary.dart` 收口，
/// 这里只决定底栏的尺寸与尾部位置。
class _TrackSection extends StatelessWidget {
  const _TrackSection({required this.morph, required this.onOpenPlayer});

  final PlayerMorphController morph;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: morph,
      builder: (context, _) {
        final showTrack = !morph.barHeaderHidden;
        return NowPlayingSummary(
          onTap: onOpenPlayer,
          cover: SizedBox(
            width: DesktopNowPlayingBar.coverSize,
            height: DesktopNowPlayingBar.coverSize,
            child: NowPlayingCover.current(
              size: DesktopNowPlayingBar.coverSize,
              flightKey: morph.barCoverKey,
              hidden: !showTrack,
            ),
          ),
          trailing: const NowPlayingFavoriteButton(),
        );
      },
    );
  }
}

/// 中区：上一首 / 播放暂停 / 下一首 + 可拖进度 + 时间。
///
/// 无曲目（含冷启动恢复态）时三个控制键禁用；触感走全应用唯一入口
/// [HapticsService]（与顶栏播放按钮同一契约）。
class _BarControls extends StatelessWidget {
  const _BarControls();

  @override
  Widget build(BuildContext context) {
    final (hasTrack, isPlaying) =
        context.select<PlaybackProvider, (bool, bool)>(
      (provider) => (provider.hasTrack, provider.isPlaying),
    );
    final l10n = AppLocalizations.of(context)!;
    final playback = context.read<PlaybackProvider>();
    return Row(
      children: [
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          semanticLabel: l10n.previousTrackTooltip,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: hasTrack
              ? () {
                  HapticsService.lightImpact();
                  playback.skipToPrevious();
                }
              : null,
        ),
        M3EIconButton(
          // 播放/暂停是这条底栏唯一的高亮按钮（tonal）：一屏一个视觉重点，
          // 与移动骨架顶栏的约定一致。
          variant: M3EIconButtonVariant.tonal,
          semanticLabel: isPlaying ? l10n.pause : l10n.play,
          icon: IconSwap<bool>(
            value: isPlaying,
            builder: (context, isPlaying) => Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          onPressed: hasTrack
              ? () {
                  HapticsService.lightImpact();
                  playback.togglePlayPause();
                }
              : null,
        ),
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          semanticLabel: l10n.nextTrackTooltip,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: hasTrack
              ? () {
                  HapticsService.lightImpact();
                  playback.skipToNext();
                }
              : null,
        ),
        const SizedBox(width: 12),
        const Expanded(child: _BarSeekSlider()),
      ],
    );
  }
}

/// 可拖进度排：当前时间 + 波浪滑杆 + 总时长。
///
/// seek 语义（拖动预览 / 提交等待 / 换曲清理）与播放页共用
/// `widgets/seek_preview.dart` + `widgets/seek_bar.dart`；宿主只负责生命周期，
/// 取值与时间标签版式都在共享模块里。
class _BarSeekSlider extends StatefulWidget {
  const _BarSeekSlider();

  @override
  State<_BarSeekSlider> createState() => _BarSeekSliderState();
}

class _BarSeekSliderState extends State<_BarSeekSlider> {
  late final PlaybackProvider _playback;
  late final SeekPreviewController _seekPreview;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackProvider>();
    _seekPreview = SeekPreviewController(
      position: _playback.position,
      trackChanges: _playback,
      currentTrackId: () => _playback.snapshot.current?.id,
      seek: _playback.seekToPosition,
    );
  }

  @override
  void dispose() {
    _seekPreview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Selector<PlaybackProvider,
        ({int durationMs, bool isPlaying, bool hasTrack})>(
      selector: (_, provider) => (
        durationMs: provider.snapshot.duration.inMilliseconds,
        isPlaying: provider.isPlaying,
        hasTrack: provider.hasTrack,
      ),
      builder: (context, state, _) => SeekBar(
        controller: _seekPreview,
        position: _playback.position,
        durationMs: state.durationMs,
        isPlaying: state.isPlaying,
        hasTrack: state.hasTrack,
        // 底栏版式：时间与条同行（底栏横向与传输键 / 右区共享，另起一行会顶高整条）。
        timeLabels: SeekTimeLabels.inline,
      ),
    );
  }
}

/// 右区：播放模式 + 音量 + 队列入口。
///
/// 按内容宽收口（不吃 Expanded）：底栏的余量让给中区进度排，见
/// [DesktopNowPlayingBar.build]。
class _BarActions extends StatelessWidget {
  const _BarActions({required this.onOpenQueue});

  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final mode = context.select<PlaybackProvider, PlayMode>(
      (provider) => provider.currentMode,
    );
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: IconSwap<PlayMode>(
            value: mode,
            builder: (context, mode) => Icon(
              switch (mode) {
                PlayMode.shuffle => Icons.shuffle_rounded,
                PlayMode.listLoop => Icons.repeat_rounded,
                PlayMode.sequential => Icons.playlist_play_rounded,
                PlayMode.singleRepeat => Icons.repeat_one_rounded,
              },
            ),
          ),
          semanticLabel: switch (mode) {
            PlayMode.listLoop => l10n.playModeListLoop,
            PlayMode.sequential => l10n.playModeSequential,
            PlayMode.shuffle => l10n.playModeShuffle,
            PlayMode.singleRepeat => l10n.playModeSingleRepeat,
          },
          onPressed: () {
            HapticsService.lightImpact();
            context.read<PlaybackProvider>().togglePlayMode();
          },
        ),
        VolumeControl(
          buttonKey: DesktopNowPlayingBar.volumeButtonKey,
          panelKey: DesktopNowPlayingBar.volumePanelKey,
        ),
        M3EIconButton(
          key: DesktopNowPlayingBar.openQueueKey,
          variant: M3EIconButtonVariant.standard,
          semanticLabel: l10n.playerBarQueue,
          icon: const Icon(Icons.queue_music_rounded),
          // 「跳播放页 + 切队列 tab」在任何窗口宽下都成立：按钮不置灰。
          onPressed: onOpenQueue,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
