/// 播放传输语义（播放 / 暂停、上一首 / 下一首、播放模式、进度）的唯一实现。
///
/// 为什么单独一层：移动迷你条、播放页传输排、桌面底栏与壳层顶栏把同一套
/// 「有没有曲目 → 是否可用 / 当前播放态 → 图标与语义标签 / 点击 → 触感 +
/// provider 命令」各抄了一遍，播放模式的图标与标签还有第二份 switch。差异
/// 只在按钮变体（tonal / standard）、尺寸和所在布局，所以这里给可组合的
/// 小控件：各宿主自己排行、自己保留周边 chrome，版式不合并。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/playback_provider.dart';
import '../services/haptics.dart';
import 'icon_swap.dart';
import 'seek_bar.dart';
import 'seek_preview.dart';

/// AppLocalizations 查找：与其它行组件同一约定，未注册 delegate 时回退简体
/// 中文，避免纯图标按钮在测试 / 局部宿主里丢掉语义标签。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// [PlayMode] 在传输控件上的唯一呈现（图标 + 语义标签）。
///
/// 播放页进度排与桌面底栏此前各有一份 switch：新增 / 调整模式时漏改一处
/// 会出现「图标对了、读屏念错」的静默漂移。标签只作为 `semanticLabel`
/// 使用——本仓纯图标按钮不挂悬浮提示（见 `docs/architecture.md` §6）。
extension PlayModeTransportPresentation on PlayMode {
  IconData get transportIcon => switch (this) {
        PlayMode.shuffle => Icons.shuffle_rounded,
        PlayMode.listLoop => Icons.repeat_rounded,
        PlayMode.sequential => Icons.playlist_play_rounded,
        PlayMode.singleRepeat => Icons.repeat_one_rounded,
      };

  String transportLabel(AppLocalizations l10n) => switch (this) {
        PlayMode.listLoop => l10n.playModeListLoop,
        PlayMode.sequential => l10n.playModeSequential,
        PlayMode.shuffle => l10n.playModeShuffle,
        PlayMode.singleRepeat => l10n.playModeSingleRepeat,
      };
}

/// 播放 / 暂停：无曲目（含冷启动恢复态）禁用，其余三面共用同一契约。
///
/// [variant] / [size] / [visualSize] 是宿主唯一可调的外观差异：桌面底栏与
/// 顶栏用 tonal 做一屏唯一视觉重点，播放页与迷你条用 standard。
class PlaybackPlayPauseButton extends StatelessWidget {
  const PlaybackPlayPauseButton({
    super.key,
    this.variant = M3EIconButtonVariant.standard,
    this.size = M3EIconButtonSize.sm,
    this.visualSize,
  });

  final M3EIconButtonVariant variant;
  final M3EIconButtonSize size;
  final Size? visualSize;

  @override
  Widget build(BuildContext context) {
    final (hasTrack, isPlaying) =
        context.select<PlaybackProvider, (bool, bool)>(
      (provider) => (provider.hasTrack, provider.isPlaying),
    );
    final l10n = _l10n(context);
    return _TransportIconButton(
      enabled: hasTrack,
      icon: IconSwap<bool>(
        value: isPlaying,
        builder: (context, isPlaying) => Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        ),
      ),
      semanticLabel: isPlaying ? l10n.pause : l10n.play,
      onPressed: () {
        HapticsService.lightImpact();
        context.read<PlaybackProvider>().togglePlayPause();
      },
      variant: variant,
      size: size,
      visualSize: visualSize,
    );
  }
}

/// 上一首：与播放 / 暂停同一启用谓词与触感口径。
class PlaybackPreviousButton extends StatelessWidget {
  const PlaybackPreviousButton({
    super.key,
    this.variant = M3EIconButtonVariant.standard,
    this.size = M3EIconButtonSize.sm,
    this.visualSize,
  });

  final M3EIconButtonVariant variant;
  final M3EIconButtonSize size;
  final Size? visualSize;

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.select<PlaybackProvider, bool>(
      (provider) => provider.hasTrack,
    );
    return _TransportIconButton(
      enabled: hasTrack,
      icon: const Icon(Icons.skip_previous_rounded),
      semanticLabel: _l10n(context).previousTrackTooltip,
      onPressed: () {
        HapticsService.lightImpact();
        context.read<PlaybackProvider>().skipToPrevious();
      },
      variant: variant,
      size: size,
      visualSize: visualSize,
    );
  }
}

/// 下一首：与播放 / 暂停同一启用谓词与触感口径。
class PlaybackNextButton extends StatelessWidget {
  const PlaybackNextButton({
    super.key,
    this.variant = M3EIconButtonVariant.standard,
    this.size = M3EIconButtonSize.sm,
    this.visualSize,
  });

  final M3EIconButtonVariant variant;
  final M3EIconButtonSize size;
  final Size? visualSize;

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.select<PlaybackProvider, bool>(
      (provider) => provider.hasTrack,
    );
    return _TransportIconButton(
      enabled: hasTrack,
      icon: const Icon(Icons.skip_next_rounded),
      semanticLabel: _l10n(context).nextTrackTooltip,
      onPressed: () {
        HapticsService.lightImpact();
        context.read<PlaybackProvider>().skipToNext();
      },
      variant: variant,
      size: size,
      visualSize: visualSize,
    );
  }
}

/// 播放模式：图标 / 标签走 [PlayModeTransportPresentation] 的唯一映射。
///
/// 无曲目也可切换（模式是会话偏好，先选模式再起播是合法操作），因此这里
/// 不接 [PlaybackProvider.hasTrack] 的禁用谓词。
class PlaybackModeButton extends StatelessWidget {
  const PlaybackModeButton({
    super.key,
    this.variant = M3EIconButtonVariant.standard,
    this.size = M3EIconButtonSize.sm,
    this.visualSize,
  });

  final M3EIconButtonVariant variant;
  final M3EIconButtonSize size;
  final Size? visualSize;

  @override
  Widget build(BuildContext context) {
    final mode = context.select<PlaybackProvider, PlayMode>(
      (provider) => provider.currentMode,
    );
    return M3EIconButton(
      variant: variant,
      size: size,
      visualSize: visualSize,
      icon: IconSwap<PlayMode>(
        value: mode,
        builder: (context, mode) => Icon(mode.transportIcon),
      ),
      semanticLabel: mode.transportLabel(_l10n(context)),
      onPressed: () {
        HapticsService.lightImpact();
        context.read<PlaybackProvider>().togglePlayMode();
      },
    );
  }
}

/// 进度滑杆的宿主：生命周期与订阅口径只此一份。
///
/// 为什么收成宿主：播放页与桌面底栏各自 new 一遍 `SeekPreviewController`、
/// 各自写一段相同的 `Selector`（duration / isPlaying / hasTrack），再加一遍
/// dispose。控制器要同时订阅 position 与换曲（曲目身份变化清预览），漏掉
/// 任一 dispose 就是常驻监听 / 计时器。版式差异只有时间标签排布
/// [timeLabels]，行的内边距 / 是否 Expanded 仍由宿主决定。
class PlaybackSeekBar extends StatefulWidget {
  const PlaybackSeekBar({
    super.key,
    this.timeLabels = SeekTimeLabels.inline,
  });

  /// 时间标签排布：底栏 inline（与条同行），播放页 below（条下方）。
  final SeekTimeLabels timeLabels;

  @override
  State<PlaybackSeekBar> createState() => _PlaybackSeekBarState();
}

class _PlaybackSeekBarState extends State<PlaybackSeekBar> {
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
    // 只订阅滑杆需要的低频快照字段：progress tick 走 position 通道，
    // 不把整块宿主卷进每次位置采样。
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
        timeLabels: widget.timeLabels,
      ),
    );
  }
}

/// 三个传输键共用的按钮外壳：启用谓词只在这里落到 `onPressed: null`。
///
/// 私有且只收「已经判定好的」enabled / 回调，公开控件因此各自只表达自己的
/// 订阅与命令，不会长出 bool 参数袋。
class _TransportIconButton extends StatelessWidget {
  const _TransportIconButton({
    required this.enabled,
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    required this.variant,
    required this.size,
    this.visualSize,
  });

  final bool enabled;
  final Widget icon;
  final String semanticLabel;
  final VoidCallback onPressed;
  final M3EIconButtonVariant variant;
  final M3EIconButtonSize size;
  final Size? visualSize;

  @override
  Widget build(BuildContext context) {
    return M3EIconButton(
      variant: variant,
      size: size,
      visualSize: visualSize,
      icon: icon,
      semanticLabel: semanticLabel,
      onPressed: enabled ? onPressed : null,
    );
  }
}
