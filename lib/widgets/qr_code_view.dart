import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

/// 二维码视图：`qr` 的轻量绘制，替代只在一处使用的 `qr_flutter`。
///
/// 与旧 `QrImageView` 的默认口径一致：纠错级别 Low、方形码点、无码点间隙、
/// 内容四周留 10 逻辑像素白边（页面外层还有一圈背景色 padding）。
class QrCodeView extends StatelessWidget {
  const QrCodeView({
    super.key,
    required this.data,
    required this.backgroundColor,
    required this.moduleColor,
    this.size = 220,
    this.semanticsLabel,
  });

  final String data;
  final double size;
  final Color backgroundColor;
  final Color moduleColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final qrImage = QrImage(
      QrCode(
        payload: QrPayload.fromString(data),
        errorCorrectLevel: QrErrorCorrectLevel.low,
      ),
    );
    return Semantics(
      image: true,
      label: semanticsLabel,
      child: Container(
        width: size,
        height: size,
        color: backgroundColor,
        padding: const EdgeInsets.all(10),
        child: CustomPaint(
          painter: _QrPainter(qrImage: qrImage, color: moduleColor),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter({required this.qrImage, required this.color});

  final QrImage qrImage;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final moduleSize = size.shortestSide / qrImage.moduleCount;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      // 码点边缘不需要抗锯齿：半透明边缘会让扫码识别率下降。
      ..isAntiAlias = false;
    for (var y = 0; y < qrImage.moduleCount; y++) {
      for (var x = 0; x < qrImage.moduleCount; x++) {
        if (!qrImage.isDark(y, x)) continue;
        canvas.drawRect(
          Rect.fromLTWH(x * moduleSize, y * moduleSize, moduleSize, moduleSize),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.qrImage != qrImage || oldDelegate.color != color;
}
