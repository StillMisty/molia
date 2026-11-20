/// 桌面骨架的常驻底部播放条（80dp）。
///
/// 左：封面 + 歌名/作者（点击进播放页，封面与播放页共享元素飞行）；
/// 中：上一首 / 播放暂停 / 下一首 + 可拖波浪进度 + 时间；
/// 右：收藏 + 播放模式 + 音量（图标 + 弹出滑杆）+ 队列。
///
/// 只在非播放页出现：播放页是沉浸主场，整条由壳层让位（见
/// `app/desktop/desktop_shell.dart` 的 `bottomNavigationBar`）。
library;

import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/now_playing_summary.dart';
import '../../widgets/playback_transport.dart';
import '../../widgets/player_morph.dart';
import '../../widgets/seek_bar.dart';
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

  /// 窄窗口（贴靠 / 手动缩到 480）的底栏高度：单行只留曲目 + 传输 + 队列，
  /// 不再把 720 内容缩成小字。
  static const double compactBarHeight = 64;

  /// 紧凑底栏的稳定 Key（测试定位）。
  static const Key compactKey = Key('desktopNowPlayingBarCompact');

  /// 封面槽边长：与顶栏 40 档同源外观（[CoverAppearance.bar]），尺寸放大
  /// 到 48 与迷你条一致——底栏是常驻信息位，比顶栏需要更强的可读性。
  static const double coverSize = 48;

  /// 三个分区（左信息 / 中控制 / 右动作）互不挤压的宽度下限：更窄时换成
  /// 紧凑单行（[compactBarHeight]），不再把整条内容等比缩成小字。
  static const double _minComfortableWidth = 720;

  /// 中区（传输 + 进度排）宽度上限：宽屏时再宽也换不来更好读的进度条，
  /// 余量还给左区标题（见 [build] 的 4:5 分配）。
  static const double _maxCenterWidth = 520;

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
          // 左 / 中按约 4:6 分配除右区之外的宽度，且左区至少 200；中区封顶
          // 520 后剩余宽度全部给左区（宽屏标题不再被固定比例压窄）。
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 中区优先拿 60%，但左区至少留 200（封面 48 + 间距 12 +
                // 标题约 140）；宽屏再由 [_maxCenterWidth] 封顶，余量回给标题。
                final centerWidth = math.max(
                  0.0,
                  math.min(
                    math.min(
                      constraints.maxWidth * 0.6,
                      constraints.maxWidth - 200,
                    ),
                    _maxCenterWidth,
                  ),
                );
                return Row(
                  children: [
                    SizedBox(
                      width: constraints.maxWidth - centerWidth,
                      child: _TrackSection(
                        morph: morph,
                        onOpenPlayer: onOpenPlayer,
                      ),
                    ),
                    SizedBox(width: centerWidth, child: const _BarControls()),
                  ],
                );
              },
            ),
          ),
          // 右区按内容宽贴右缘：中区封顶后余量给左区，不再从进度排身上扣。
          _BarActions(onOpenQueue: onOpenQueue),
        ],
      ),
    );
    // 容器色取 surfaceContainer：与顶栏 AppBar / M3E 导航栏的「外壳容器」
    // 语义一致——播放条是壳层家具，不参与页面内容的 surface 层级。
    return Material(
      color: scheme.surfaceContainer,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄窗口（贴靠区 / 最小 480）换紧凑单行：整条 720 内容等比缩到
          // 0.66 会把标题和时间一起缩成看不清的小字，信息反而更少。
          if (constraints.maxWidth < _minComfortableWidth) {
            return SizedBox(
              key: compactKey,
              height: compactBarHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _TrackSection(
                        morph: morph,
                        onOpenPlayer: onOpenPlayer,
                        coverSize: 40,
                      ),
                    ),
                    const PlaybackPreviousButton(),
                    const PlaybackPlayPauseButton(
                      variant: M3EIconButtonVariant.tonal,
                    ),
                    const PlaybackNextButton(),
                    // 紧凑版式保留收藏（宽版式已把它移进右区动作组）；
                    // 模式 / 音量在播放页都有落点，这里只多留队列入口，
                    // 保证「看接下来放什么」仍然一步可达。
                    const NowPlayingFavoriteButton(),
                    M3EIconButton(
                      key: openQueueKey,
                      variant: M3EIconButtonVariant.standard,
                      semanticLabel: AppLocalizations.of(context)!
                          .playerBarQueue,
                      icon: const Icon(Icons.queue_music_rounded),
                      onPressed: onOpenQueue,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            );
          }
          return SizedBox(height: barHeight, child: content);
        },
      ),
    );
  }
}

/// 左区：封面 + 歌名/作者。
///
/// 封面复用顶栏那套隐藏语义（[PlayerMorphController.barHeaderHidden]：
/// 播放页激活或飞行中淡出，避免与页面大封面重复）；但封面槽**占位宽度
/// 不变**——收起时整条文字区不跳动，也保证共享飞行的起止锚点稳定。
/// 摘要内容（封面 / 文本）由 `now_playing_summary.dart` 收口，收藏等
/// 动作放在右区（[_BarActions]），左区只留给标题。
class _TrackSection extends StatelessWidget {
  const _TrackSection({
    required this.morph,
    required this.onOpenPlayer,
    this.coverSize = DesktopNowPlayingBar.coverSize,
  });

  final PlayerMorphController morph;
  final VoidCallback onOpenPlayer;
  final double coverSize;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: morph,
      builder: (context, _) {
        final showTrack = !morph.barHeaderHidden;
        return NowPlayingSummary(
          onTap: onOpenPlayer,
          cover: SizedBox(
            width: coverSize,
            height: coverSize,
            child: NowPlayingCover.current(
              size: coverSize,
              flightKey: morph.barCoverKey,
              hidden: !showTrack,
            ),
          ),
        );
      },
    );
  }
}

/// 中区：上一首 / 播放暂停 / 下一首 + 可拖进度 + 时间。
///
/// 传输三键走共享模块（无曲目时禁用、触感、命令与语义标签只有一份）；这里
/// 只排行，按钮外观全是模块默认档。进度排的控制器生命周期与低频快照订阅在
/// [PlaybackSeekBar] 内，宿主只选时间标签档位。
class _BarControls extends StatelessWidget {
  const _BarControls();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        PlaybackPreviousButton(),
        // 播放/暂停是这条底栏唯一的高亮按钮（tonal）：一屏一个视觉重点，
        // 与移动骨架顶栏的约定一致。
        PlaybackPlayPauseButton(variant: M3EIconButtonVariant.tonal),
        PlaybackNextButton(),
        SizedBox(width: 12),
        // 底栏版式：时间与条同行（底栏横向与传输键 / 右区共享，另起一行会
        // 顶高整条）。
        Expanded(child: PlaybackSeekBar(timeLabels: SeekTimeLabels.inline)),
      ],
    );
  }
}

/// 右区：收藏 + 播放模式 + 音量 + 队列入口。
///
/// 收藏从左侧标题区移到这里：它和模式 / 音量 / 队列一样是「播放动作」，
/// 左区只负责当前曲目。模式按钮与播放页进度排同源（[PlaybackModeButton]）：
/// 两处都是「当前会话的播放顺序」的一步切换，图标 / 标签 / 触感只在共享
/// 模块维护一份。按内容宽收口（不吃 Expanded），余量让给中区进度排与左区
/// 标题，见 [DesktopNowPlayingBar.build]。
class _BarActions extends StatelessWidget {
  const _BarActions({required this.onOpenQueue});

  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const NowPlayingFavoriteButton(),
        // 模式图标 / 标签 / 触感 / 命令在共享传输模块，播放页进度排同源。
        const PlaybackModeButton(),
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
