/// 桌面骨架的常驻底部播放条（80dp）。
///
/// 左：封面 + 歌名/作者 + 收藏（点击进播放页，封面与播放页共享元素飞行）；
/// 中：上一首 / 播放暂停 / 下一首 + 可拖波浪进度 + 时间；
/// 右：播放模式 + 音量（图标 + 弹出滑杆）+ 队列开关。
library;

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../models/play_mode.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../services/app_branding_service.dart';
import '../../services/escape_claims.dart';
import '../../services/haptics.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/cover_appearance.dart';
import '../../widgets/icon_swap.dart';
import '../../widgets/player_morph.dart';
import '../../widgets/seek_bar.dart';
import '../../widgets/seek_preview.dart';

/// 常驻底部播放条。
class DesktopNowPlayingBar extends StatelessWidget {
  const DesktopNowPlayingBar({
    super.key,
    required this.morph,
    required this.queueOpen,
    required this.queueAvailable,
    required this.onOpenPlayer,
    required this.onToggleQueue,
  });

  /// 稳定 Key：测试定位整条播放条（桌面骨架存在性）。
  static const Key shellKey = Key('desktopNowPlayingBar');

  /// 队列开关按钮的稳定 Key。
  static const Key queueToggleKey = Key('desktopQueueToggle');

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

  /// 队列面板当前是否**实际渲染**（窄窗口下会被强制关闭；按钮态跟它走，
  /// 否则会出现「按钮亮着但面板不存在」的死控件）。
  final bool queueOpen;

  /// 当前窗口宽度是否允许队列面板（窄于阈值时按钮置灰，与侧栏的
  /// `alwaysCollapse` 同一口径：不提供点了没反应的入口）。
  final bool queueAvailable;

  /// 点击左区进入播放页。
  final VoidCallback onOpenPlayer;

  /// 切换队列面板。
  final VoidCallback onToggleQueue;

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
          const Expanded(flex: 4, child: _BarControls()),
          Expanded(
            flex: 3,
            child: _BarActions(
              queueOpen: queueOpen,
              queueAvailable: queueAvailable,
              onToggleQueue: onToggleQueue,
            ),
          ),
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
class _TrackSection extends StatelessWidget {
  const _TrackSection({required this.morph, required this.onOpenPlayer});

  final PlayerMorphController morph;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final track = context.select<PlaybackProvider, Track?>(
      (provider) => provider.snapshot.current,
    );
    return AnimatedBuilder(
      animation: morph,
      builder: (context, _) {
        final showTrack = !morph.barHeaderHidden;
        return Row(
          children: [
            Expanded(
              // 刻意不用 M3ETappable：它点击时会请求焦点（与顶栏同款取舍，
              // 避免打断搜索输入），GestureDetector 与顶栏头部手势一致。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onOpenPlayer,
                child: Row(
                  children: [
                    SizedBox(
                      width: DesktopNowPlayingBar.coverSize,
                      height: DesktopNowPlayingBar.coverSize,
                      child: AnimatedOpacity(
                        // 飞行落位时真身封面必须与副本移除同帧亮出
                        // （duration 0 = 同步跳变）；收起方向保持 160ms 淡出。
                        duration: showTrack
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        opacity: showTrack ? 1 : 0,
                        child: CoverCard(
                          key: morph.barCoverKey,
                          size: DesktopNowPlayingBar.coverSize,
                          appearance: CoverAppearance.bar,
                          content: (context, clip, iconSize) => AppNetworkImage(
                            url: artworkUrlOf(track),
                            borderRadius: clip,
                            fallbackIconSize: iconSize,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(child: _BarTrackText()),
                  ],
                ),
              ),
            ),
            const _BarFavoriteButton(),
          ],
        );
      },
    );
  }
}

/// 歌名 + 作者两行；无曲目（或空标题）回退自定义应用名。
///
/// 排版与顶栏曲目信息区（`app_shell.dart::_BarTrackInfo`）同契约：标题
/// titleMedium、作者 labelSmall（默认 onSurfaceVariant）。
class _BarTrackText extends StatelessWidget {
  const _BarTrackText();

  @override
  Widget build(BuildContext context) {
    final info = context.select<PlaybackProvider, (String?, String?)>(
      (provider) {
        final track = provider.snapshot.current;
        return (track?.title, track?.artistLabel);
      },
    );
    final (title, artists) = info;
    if (title == null || title.isEmpty) {
      return ValueListenableBuilder<String>(
        valueListenable: AppBrandingService.titleNotifier,
        builder: (context, appTitle, _) => Text(
          appTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (artists != null && artists.isNotEmpty)
          Text(
            artists,
            style: Theme.of(context).textTheme.labelSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

/// 左区收藏按钮：与播放页 `player.dart::_FavoriteButton`（私有）同契约——
/// 图标态即反馈（已收藏 primary / 未收藏 onSurfaceVariant），不弹提示；
/// 写路径唯一：`LibraryProvider.toggleFavoriteTrack`。
///
/// 为什么内联一份：那份实现是播放页私有类，且布局在播放页进度排里；
/// 两处宿主不同，导出私有类会污染播放页公开面。改契约时两处必须同步。
class _BarFavoriteButton extends StatelessWidget {
  const _BarFavoriteButton();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider?>();
    final track = context.select<PlaybackProvider, Track?>(
      (provider) => provider.snapshot.current,
    );
    if (library == null || track == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final favorite = library.isFavorite(track.id.sourceKey, track.id.id);
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      icon: IconSwap<bool>(
        value: favorite,
        builder: (context, favorite) => Icon(
          favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: favorite
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      tooltip: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
      onPressed: () async {
        HapticsService.lightImpact();
        await library.toggleFavoriteTrack(track);
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
          tooltip: l10n.previousTrackTooltip,
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
          tooltip: isPlaying ? l10n.pause : l10n.play,
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
          tooltip: l10n.nextTrackTooltip,
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
/// `widgets/seek_preview.dart` + `widgets/seek_bar.dart`；宿主只负责
/// 生命周期与时间标签版式。
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
        showTimeLabels: true,
      ),
    );
  }
}

/// 右区：播放模式 + 音量 + 队列开关。
class _BarActions extends StatelessWidget {
  const _BarActions({
    required this.queueOpen,
    required this.queueAvailable,
    required this.onToggleQueue,
  });

  final bool queueOpen;
  final bool queueAvailable;
  final VoidCallback onToggleQueue;

  @override
  Widget build(BuildContext context) {
    final mode = context.select<PlaybackProvider, PlayMode>(
      (provider) => provider.currentMode,
    );
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: IconSwap<PlayMode>(
            value: mode,
            builder: (context, mode) => Icon(
              switch (mode) {
                PlayMode.shuffle => Icons.shuffle_rounded,
                PlayMode.sequential => Icons.repeat_rounded,
                PlayMode.singleRepeat => Icons.repeat_one_rounded,
              },
            ),
          ),
          tooltip: switch (mode) {
            PlayMode.sequential => l10n.playModeSequential,
            PlayMode.shuffle => l10n.playModeShuffle,
            PlayMode.singleRepeat => l10n.playModeSingleRepeat,
          },
          onPressed: () {
            HapticsService.lightImpact();
            context.read<PlaybackProvider>().togglePlayMode();
          },
        ),
        const _VolumeButton(),
        M3EIconButton(
          key: DesktopNowPlayingBar.queueToggleKey,
          // 面板打开时用 tonal 变体表达选中态（一屏内唯一的「已展开」信号）。
          variant: queueOpen
              ? M3EIconButtonVariant.tonal
              : M3EIconButtonVariant.standard,
          tooltip: l10n.playerBarQueue,
          icon: const Icon(Icons.queue_music_rounded),
          // 窄窗口（面板被强制关闭）时置灰：点了也看不到面板。
          onPressed: queueAvailable ? onToggleQueue : null,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// 音量按钮：图标随静音 / 零音量切换，点击在图标上方弹出滑杆面板。
///
/// 弹层用 [OverlayPortal]（不占布局、跟随图标锚点），点击外部或 Esc 关闭。
class _VolumeButton extends StatefulWidget {
  const _VolumeButton();

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  final OverlayPortalController _controller = OverlayPortalController();

  /// 图标与面板同组：点图标算「组内」，不触发 onTapOutside——否则点图标
  /// 关闭面板时 onTapOutside 会先关一次、onPressed 的 toggle 再把它开回来。
  final Object _tapGroup = Object();

  @override
  Widget build(BuildContext context) {
    final (muted, volume) = context.select<PlaybackProvider, (bool, double)>(
      (provider) => (provider.muted, provider.volume),
    );
    final l10n = AppLocalizations.of(context)!;
    final off = muted || volume == 0;
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _controller,
      overlayChildBuilder: (context, info) {
        // 锚点矩形（overlay 坐标系）= portal child 的本地矩形经
        // childPaintTransform 映射。刻意不用 CompositedTransformFollower：
        // overlay child 拿到的永远是整屏紧约束，follower 会以整屏尺寸参与
        // 定位与命中（面板变成铺满屏幕的命中区，点外部永远关不掉）。
        final anchor = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        return Positioned(
          // 面板右缘贴图标右缘（按钮在窗口右下角，向左展开不会出界），
          // 底边在图标顶边上方 8dp。
          right: info.overlaySize.width - anchor.right,
          bottom: info.overlaySize.height - anchor.top + 8,
          child: TapRegion(
            groupId: _tapGroup,
            onTapOutside: (_) => _controller.hide(),
            child: _VolumePanel(
              key: DesktopNowPlayingBar.volumePanelKey,
              onClose: _controller.hide,
            ),
          ),
        );
      },
      child: TapRegion(
        groupId: _tapGroup,
        child: MouseRegion(
          // 桌面鼠标习惯：可点元素给手型（M3E 按钮自身不设鼠标指针）。
          cursor: SystemMouseCursors.click,
          child: M3EIconButton(
            key: DesktopNowPlayingBar.volumeButtonKey,
            variant: M3EIconButtonVariant.standard,
            tooltip: l10n.playerBarVolume,
            icon: IconSwap<bool>(
              value: off,
              builder: (context, off) => Icon(
                off ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
            onPressed: _controller.toggle,
          ),
        ),
      ),
    );
  }
}

/// 音量面板：横向滑杆（~120dp）+ 静音开关。
///
/// Esc 由自己的 [HardwareKeyboard] 处理器接住，与 [EscapeClaims] 登记同源
/// （挂载 = 可见 = 占用，都不依赖焦点位置）。不用 [Focus.onKeyEvent]：焦点被
/// Tab 移出弹层子树后按键不再冒泡到这里，而登记仍让壳层让位，Esc 会被完全
/// 吞掉。[Focus] 只保留 autofocus，供滑杆的键盘操作。
class _VolumePanel extends StatefulWidget {
  const _VolumePanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<_VolumePanel> createState() => _VolumePanelState();
}

class _VolumePanelState extends State<_VolumePanel> {
  /// 登记判定：本组件存在 = 面板可见（随 Overlay 挂载 / 卸载）。
  late final bool Function() _escapeClaim = _claimEscape;

  bool _claimEscape() => true;

  /// HardwareKeyboard 处理器引用：注册 / 注销必须是同一闭包。
  late final bool Function(KeyEvent) _keyHandler = _handleKeyEvent;

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    widget.onClose();
    return true;
  }

  @override
  void initState() {
    super.initState();
    EscapeClaims.add(_escapeClaim);
    HardwareKeyboard.instance.addHandler(_keyHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    EscapeClaims.remove(_escapeClaim);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (muted, volume) = context.select<PlaybackProvider, (bool, double)>(
      (provider) => (provider.muted, provider.volume),
    );
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      autofocus: true,
      child: Material(
        color: scheme.surfaceContainerHigh,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 120,
                child: M3ESlider(
                  value: volume.clamp(0.0, 1.0),
                  min: 0,
                  max: 1,
                  onChanged: (value) =>
                      context.read<PlaybackProvider>().setVolume(value),
                ),
              ),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                tooltip: muted ? l10n.playerBarUnmute : l10n.playerBarMute,
                icon: IconSwap<bool>(
                  value: muted,
                  builder: (context, muted) => Icon(
                    muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  ),
                ),
                onPressed: () => context.read<PlaybackProvider>().toggleMute(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
