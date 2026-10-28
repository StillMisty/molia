import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../models/lyric_line.dart';

/// 逐字歌词文本（当前行的词级高亮）。
///
/// 已唱词 = [playedColor]，未唱词 = [unplayedColor]，当前词按时间进度在两色
/// 之间插值（卡拉 OK 填充感）。
///
/// 进度来源为 position 通道（≤4Hz）：为消除 250ms 的跳变，内部用与采样间隔
/// 等长的线性补间平滑到每个新采样点；暂停 / 回跳 / 大跳（seek）直接落位。
///
/// 补间的代价是显示值恒定慢一拍（补到本拍采样值需要一整拍）。需要与真实
/// 人声对齐的调用方传 [lead]（正 = 提前）抵消这段滞后，见 `lyrics.dart`
/// 的视觉提前量说明。
class KaraokeLyricText extends StatefulWidget {
  const KaraokeLyricText({
    super.key,
    required this.words,
    required this.position,
    required this.playedColor,
    required this.unplayedColor,
    this.lead = Duration.zero,
    this.maxDelta = const Duration(milliseconds: 1500),
  });

  /// 词列表（绝对时间，来自 [LyricLine.words]）。
  final List<LyricWord> words;

  /// 进度通道（播放器 position）。
  final ValueListenable<Duration> position;

  /// 已唱词颜色。
  final Color playedColor;

  /// 未唱词颜色。
  final Color unplayedColor;

  /// 显示提前量：插值目标取 `position + lead`（正 = 提前）。
  ///
  /// 只平移显示进度，不改变补间速度；相对速度 / 回跳判定仍由相邻采样点
  /// 之差决定，因此 seek 与暂停的落位语义不变。
  final Duration lead;

  /// 超过该跨度视为跳转（seek），直接落位不做补间。
  final Duration maxDelta;

  @override
  State<KaraokeLyricText> createState() => _KaraokeLyricTextState();
}

class _KaraokeLyricTextState extends State<KaraokeLyricText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 补间起点（毫秒）。
  double _beginMs = 0;

  /// 补间目标 / 静态显示值（毫秒）。
  double _targetMs = 0;

  /// 非当前词（已唱 / 未唱）的 span 缓存：这两类颜色只随「词状态」变化，
  /// 逐帧重算时直接复用；只有正在插值的当前词需要新的 TextStyle。
  ///
  /// 键是词表引用 + 已唱 / 未唱颜色：父级换行或换主题色时整体丢弃。
  List<LyricWord>? _spanWords;
  Color? _spanPlayedColor;
  Color? _spanUnplayedColor;
  List<TextSpan?> _spanCache = const [];
  List<_WordPaint?> _spanPaints = const [];
  TextStyle _playedStyle = const TextStyle();
  TextStyle _unplayedStyle = const TextStyle();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _targetMs = _ledMs;
    _beginMs = _targetMs;
    widget.position.addListener(_onPositionChanged);
  }

  @override
  void didUpdateWidget(KaraokeLyricText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position ||
        oldWidget.lead != widget.lead) {
      oldWidget.position.removeListener(_onPositionChanged);
      widget.position.addListener(_onPositionChanged);
      _targetMs = _ledMs;
      _beginMs = _targetMs;
      _controller.stop();
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPositionChanged);
    _controller.dispose();
    super.dispose();
  }

  /// 带提前量的显示进度（毫秒）：插值目标以它为准。
  double get _ledMs =>
      (widget.position.value + widget.lead).inMilliseconds.toDouble();

  void _onPositionChanged() {
    final target = _ledMs;
    final displayed = _currentMs;
    final delta = target - displayed;
    if (delta <= 0 || delta > widget.maxDelta.inMilliseconds) {
      // 回跳 / 暂停采样 / seek：直接落位。
      _controller.stop();
      setState(() {
        _beginMs = target;
        _targetMs = target;
      });
      return;
    }
    setState(() {
      _beginMs = displayed;
      _targetMs = target;
    });
    _controller.duration = Duration(milliseconds: delta.round());
    _controller.forward(from: 0);
  }

  /// 当前插值进度（毫秒）：动画中取补间值，否则取目标值。
  double get _currentMs {
    if (_controller.isAnimating) {
      return _beginMs + (_targetMs - _beginMs) * _controller.value;
    }
    return _targetMs;
  }

  @override
  Widget build(BuildContext context) {
    // 每帧重建的 TextSpan 树与文本布局限制在本行内（外层是整页歌词列表）。
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final ms = _currentMs;
          return Text.rich(
            TextSpan(children: _buildSpans(ms)),
            textAlign: TextAlign.left,
          );
        },
      ),
    );
  }

  List<InlineSpan> _buildSpans(double ms) {
    final words = widget.words;
    if (!identical(words, _spanWords) ||
        words.length != _spanCache.length ||
        widget.playedColor != _spanPlayedColor ||
        widget.unplayedColor != _spanUnplayedColor) {
      _resetSpanCache(words);
    }
    final spans = List<TextSpan>.filled(
      words.length,
      const TextSpan(),
      growable: false,
    );
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final start = word.start.inMilliseconds.toDouble();
      final end = word.end.inMilliseconds.toDouble();
      if (ms >= end) {
        spans[i] = _spanFor(i, word, _WordPaint.played);
      } else if (ms <= start || end <= start) {
        spans[i] = _spanFor(i, word, _WordPaint.unplayed);
      } else {
        final color = Color.lerp(
          widget.unplayedColor,
          widget.playedColor,
          (ms - start) / (end - start),
        )!;
        spans[i] = TextSpan(text: word.text, style: TextStyle(color: color));
      }
    }
    return spans;
  }

  void _resetSpanCache(List<LyricWord> words) {
    _spanWords = words;
    _spanPlayedColor = widget.playedColor;
    _spanUnplayedColor = widget.unplayedColor;
    _spanCache = List<TextSpan?>.filled(words.length, null, growable: false);
    _spanPaints = List<_WordPaint?>.filled(words.length, null, growable: false);
    _playedStyle = TextStyle(color: widget.playedColor);
    _unplayedStyle = TextStyle(color: widget.unplayedColor);
  }

  /// 已唱 / 未唱词复用同色 span：词表与颜色不变时，同一个词只会分配一次。
  TextSpan _spanFor(int index, LyricWord word, _WordPaint paint) {
    if (_spanPaints[index] == paint) return _spanCache[index]!;
    final span = TextSpan(
      text: word.text,
      style: paint == _WordPaint.played ? _playedStyle : _unplayedStyle,
    );
    _spanPaints[index] = paint;
    _spanCache[index] = span;
    return span;
  }
}

/// 非当前词的两档颜色：只决定 span 缓存的复用边界。
enum _WordPaint { played, unplayed }
