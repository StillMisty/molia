import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../providers/playback_provider.dart';

/// 播放状态 Provider 选择器集合
///
/// 使用 Selector 替代 Consumer 可以显著减少不必要的 Widget 重建。

/// 一行曲目的当前播放状态：[isCurrent] 为「这一行就是当前曲目」，
/// [isPlaying] 只在 [isCurrent] 为真时有意义。
typedef CurrentTrackState = ({bool isCurrent, bool isPlaying});

/// 行级订阅当前曲目状态（在该行自己的 build 里调用）。
///
/// 用 `PlaybackProvider?`：组件测试 / 独立预览没有播放栈时按「非当前曲目」
/// 处理，不抛 ProviderNotFoundException。非当前行在播放 / 暂停切换时返回的
/// `(false, false)` 不变，因此不会跟着整张列表重建。
CurrentTrackState selectCurrentTrackState(
  BuildContext context,
  TrackId trackId,
) {
  return context.select<PlaybackProvider?, CurrentTrackState>((provider) {
    final current = provider?.snapshot.current;
    final isCurrent = current?.id == trackId;
    return (
      isCurrent: isCurrent,
      isPlaying: isCurrent && (provider?.snapshot.isPlaying ?? false),
    );
  });
}

/// 选择进度条所需的数据
///
/// 进度走 provider 的独立 [PlaybackProvider.position] 通道
/// （`ValueListenableBuilder`），低频状态（时长/播放中/有无曲目）走
/// [Selector]（record `==` 可靠）。进度 tick 只重建 builder 自身，
/// 不触发整 Provider 通知。
class ProgressBarSelector extends StatelessWidget {
  final Widget Function(
    BuildContext context,
    Duration position,
    ({int duration, bool isPlaying, bool hasTrack}) state,
    Widget? child,
  ) builder;
  final Widget? child;

  const ProgressBarSelector({
    super.key,
    required this.builder,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final position = context.read<PlaybackProvider>().position;
    return Selector<PlaybackProvider,
        ({int duration, bool isPlaying, bool hasTrack})>(
      selector: (_, provider) => (
        duration:
            provider.hasTrack ? provider.snapshot.duration.inMilliseconds : 1,
        isPlaying: provider.isPlaying,
        hasTrack: provider.hasTrack,
      ),
      builder: (context, state, child) {
        return ValueListenableBuilder<Duration>(
          valueListenable: position,
          builder: (context, position, _) =>
              builder(context, position, state, child),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// 订阅 position 通道、只在“当前行号”变化时重建（歌词行高亮专用）。
///
/// 高频进度本身不触发重建：内部缓存 [lineIndexFor] 计算出的行号，
/// 仅当行号变化（或父级重建传入新歌词/曲目）时才刷新。
class PositionLineIndexBuilder extends StatefulWidget {
  const PositionLineIndexBuilder({
    super.key,
    required this.position,
    required this.lineIndexFor,
    required this.builder,
  });

  /// 进度通道（provider.position / facade.position）。
  final ValueListenable<Duration> position;

  /// 由进度计算当前行号（返回 -1 表示无高亮行）。
  final int Function(Duration position) lineIndexFor;

  final Widget Function(BuildContext context, int currentLineIndex) builder;

  @override
  State<PositionLineIndexBuilder> createState() =>
      _PositionLineIndexBuilderState();
}

class _PositionLineIndexBuilderState extends State<PositionLineIndexBuilder> {
  late int _currentLineIndex;

  @override
  void initState() {
    super.initState();
    _currentLineIndex = widget.lineIndexFor(widget.position.value);
    widget.position.addListener(_onPositionChanged);
  }

  void _onPositionChanged() {
    final next = widget.lineIndexFor(widget.position.value);
    if (next != _currentLineIndex) {
      setState(() => _currentLineIndex = next);
    }
  }

  @override
  void didUpdateWidget(PositionLineIndexBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onPositionChanged);
      widget.position.addListener(_onPositionChanged);
    }
    // 父级重建（歌词加载/换曲/翻译等）时同步一次行号；
    // 后续 build 紧随其后，直接赋值即可。
    _currentLineIndex = widget.lineIndexFor(widget.position.value);
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPositionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _currentLineIndex);
}
