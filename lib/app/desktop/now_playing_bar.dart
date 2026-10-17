/// 桌面骨架的常驻底部播放条（80dp）。
///
/// 左：封面 + 歌名/作者 + 收藏（点击进播放页，封面与播放页共享元素飞行）；
/// 中：上一首 / 播放暂停 / 下一首 + 可拖波浪进度 + 时间；
/// 右：播放模式 + 音量（图标 + 弹出滑杆）+ 队列开关。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
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
import '../../utils/duration_text.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/cover_appearance.dart';
import '../../widgets/icon_swap.dart';
import '../../widgets/player_morph.dart';

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
/// seek 语义（拖动期本地预览、松手提交、position 追上或 1.5s 超时撤下
/// 预览）与播放页 `player.dart::_buildSeekSlider` / `_commitSeek` /
/// `_handlePositionTick` 三段逐字一致。
///
/// 为什么复制而不是复用：那份实现与播放页宿主（封面堆叠、入场动画、
/// 迷你 ⇄ 完整切换）耦合且是私有成员，导出私有状态会污染播放页公开面；
/// 两处宿主不同，只能各持一份。改 seek 语义时必须同步两份实现。
class _BarSeekSlider extends StatefulWidget {
  const _BarSeekSlider();

  @override
  State<_BarSeekSlider> createState() => _BarSeekSliderState();
}

class _BarSeekSliderState extends State<_BarSeekSlider> {
  /// 进度条拖动预览（毫秒）：非空时滑杆显示本地值、忽略 position 通道，
  /// 松手后提交 seek 并保留显示，直到 position 追上目标或超时。
  final ValueNotifier<double?> _seekPreviewMs = ValueNotifier<double?>(null);
  int? _seekTargetMs;
  Timer? _seekSettleTimer;
  ValueListenable<Duration>? _positionListenable;
  PlaybackProvider? _playback;
  String? _lastTrackUri;

  @override
  void initState() {
    super.initState();
    final playback = context.read<PlaybackProvider>();
    _playback = playback;
    _positionListenable = playback.position..addListener(_handlePositionTick);
    _lastTrackUri = playback.snapshot.current?.id.uri;
    // 底栏没有播放页封面堆叠的「切歌回调」可用，直接订阅 provider 检测
    // 换曲：切歌后清掉拖动预览，避免旧进度残留在新曲目的滑杆上。
    playback.addListener(_handleProviderChanged);
  }

  @override
  void dispose() {
    _playback?.removeListener(_handleProviderChanged);
    _positionListenable?.removeListener(_handlePositionTick);
    _seekSettleTimer?.cancel();
    _seekPreviewMs.dispose();
    super.dispose();
  }

  void _handleProviderChanged() {
    final uri = _playback?.snapshot.current?.id.uri;
    if (uri == _lastTrackUri) return;
    _lastTrackUri = uri;
    _clearSeekPreview();
  }

  /// seek 提交后，position 追上目标（或超时兜底）才撤下预览，
  /// 避免滑杆在通道追上之前回跳到旧位置。
  void _handlePositionTick() {
    final target = _seekTargetMs;
    if (target == null) return;
    final current = _positionListenable?.value.inMilliseconds ?? 0;
    if ((current - target).abs() <= 800) {
      _seekTargetMs = null;
      _seekSettleTimer?.cancel();
      _seekPreviewMs.value = null;
    }
  }

  /// 松手提交 seek：保留拖动值显示直到 position 追上。
  void _commitSeek(double value) {
    final target = value.round();
    _seekTargetMs = target;
    _seekPreviewMs.value = value;
    _seekSettleTimer?.cancel();
    _seekSettleTimer = Timer(const Duration(milliseconds: 1500), () {
      if (_seekTargetMs != target) return;
      _seekTargetMs = null;
      _seekPreviewMs.value = null;
    });
    unawaited(_playback!.seekToPosition(target));
  }

  void _clearSeekPreview() {
    _seekTargetMs = null;
    _seekSettleTimer?.cancel();
    _seekPreviewMs.value = null;
  }

  /// 时间标签：m:ss；无曲目或时长 0 显示 `--:--`。
  ///
  /// tabular figures：等宽数字避免每秒文本宽度变化把滑杆左右推挤。
  static TextStyle? _timeStyle(TextTheme textTheme) =>
      textTheme.labelSmall?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  @override
  Widget build(BuildContext context) {
    // 外层 RepaintBoundary 是硬需求：`M3ESlider.wavy` 内部是 `repeat()` 的
    // 无限动画（包内每帧重建/重绘轨道），不隔离的话播放中每次波形重绘都会
    // 把整条底栏（封面 + 文字）卷进同一图层重光栅化（理由同播放页滑杆）。
    return RepaintBoundary(
      child: ValueListenableBuilder<double?>(
        valueListenable: _seekPreviewMs,
        builder: (context, previewMs, _) {
          return ValueListenableBuilder<Duration>(
            valueListenable: _playback!.position,
            builder: (context, position, _) {
              final (durationMs, isPlaying, hasTrack) =
                  context.select<PlaybackProvider, (int, bool, bool)>(
                (provider) => (
                  provider.snapshot.duration.inMilliseconds,
                  provider.isPlaying,
                  provider.hasTrack,
                ),
              );
              final bool enabled = hasTrack && durationMs > 0;
              final double maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
              final double valueMs =
                  (previewMs ?? position.inMilliseconds.toDouble())
                      .clamp(0.0, maxMs);
              final ValueChanged<double>? onChanged = enabled
                  ? (value) {
                      // 新拖动作废上一次的等待落点。
                      _seekTargetMs = null;
                      _seekSettleTimer?.cancel();
                      _seekPreviewMs.value = value;
                    }
                  : null;
              final ValueChanged<double>? onChangeEnd =
                  enabled ? _commitSeek : null;

              // 暂停时切到平直滑杆：波浪动画不会停（一直在动），
              // 与「已暂停」的状态自相矛盾。
              final Widget slider = isPlaying
                  ? M3ESlider.wavy(
                      value: valueMs,
                      min: 0,
                      max: maxMs,
                      size: M3ESliderSize.xs,
                      trackThickness: 6,
                      enabled: enabled,
                      label: durationText(valueMs.round()) ?? '0:00',
                      onChanged: onChanged,
                      onChangeEnd: onChangeEnd,
                    )
                  : M3ESlider(
                      value: valueMs,
                      min: 0,
                      max: maxMs,
                      size: M3ESliderSize.xs,
                      trackThickness: 6,
                      enabled: enabled,
                      label: durationText(valueMs.round()) ?? '0:00',
                      onChanged: onChanged,
                      onChangeEnd: onChangeEnd,
                    );

              final style = _timeStyle(Theme.of(context).textTheme);
              return Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      enabled ? (durationText(valueMs.round()) ?? '0:00') : '--:--',
                      style: style,
                      maxLines: 1,
                    ),
                  ),
                  Expanded(child: slider),
                  SizedBox(
                    width: 40,
                    child: Text(
                      enabled ? (durationText(durationMs) ?? '--:--') : '--:--',
                      style: style,
                      maxLines: 1,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              );
            },
          );
        },
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
