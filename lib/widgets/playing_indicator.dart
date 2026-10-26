import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 播放中的均衡器角标：3 根圆角竖柱按正弦相位起伏。
///
/// 为什么自绘：图标字体只能表达「静态的均衡器符号」，而这里要的是持续起伏
/// 的播放状态；用 `AnimatedIcon` / 位移动画拼图标会让每一帧都重建组件树。
/// 自绘只把 [progress] 交给 painter，动画值变化只重绘这个 12dp 小区域。
///
/// 为什么包 [RepaintBoundary]：角标位于曲目行封面上，父级会因播放进度、
/// 列表滚动等频繁重建；边界把重绘隔离在角标内，不带着封面和整行一起提交。
///
/// 为什么是 3 柱：12dp 槽里 2 根看起来像闪烁、不够「播放中」，4 根在圆角
/// 笔帽下会互相粘连；3 根刚好能读出相位差，又保留柱间空隙。
class PlayingIndicator extends StatelessWidget {
  const PlayingIndicator({
    super.key,
    required this.progress,
    required this.color,
    this.size = 12,
  });

  /// 0..1 的循环进度；暂停时由外层停住，角标保持静态相位。
  final Animation<double> progress;

  final Color color;

  /// 方形绘制槽（默认 12dp，与角标图标同档）。
  final double size;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _PlayingIndicatorPainter(progress: progress, color: color),
      ),
    );
  }
}

class _PlayingIndicatorPainter extends CustomPainter {
  _PlayingIndicatorPainter({required this.progress, required this.color})
      : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double strokeWidth = size.shortestSide * 0.18;
    // 圆角笔帽会在端点外各多画半个笔宽，所以线长先扣掉笔宽，让视觉高度
    // 落在槽高的 1/4..3/4（12dp 槽内约 3..9dp）。
    final double minLength =
        math.max(0, size.shortestSide * 0.25 - strokeWidth);
    final double maxLength =
        math.max(minLength, size.shortestSide * 0.75 - strokeWidth);
    final double spacing = size.shortestSide * 0.28;
    final double centerX = size.width / 2;
    final double centerY = size.height / 2;
    final double phase = progress.value * math.pi * 2;
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    for (var index = 0; index < 3; index++) {
      // 相邻柱错开 1/3 周期：同一时刻总有一根在上升、一根在下降，读起来
      // 才像均衡器而不是整排一起呼吸。
      final double wave = math.sin(phase + index * math.pi * 2 / 3);
      final double length = minLength + (maxLength - minLength) * (wave + 1) / 2;
      final double x = centerX + (index - 1) * spacing;
      canvas.drawLine(
        Offset(x, centerY - length / 2),
        Offset(x, centerY + length / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PlayingIndicatorPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
