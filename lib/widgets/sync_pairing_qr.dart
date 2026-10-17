import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

import '../theme/scheme_builder.dart';

/// 配对码二维码：白底 + 黑色模块 + 静区（`CustomPaint` 自绘，尺寸填满父级）。
///
/// 颜色固定黑白（[qrSurfaceColor] / [qrModuleColor]）：机器可读表面不能随
/// 主题反转，深色主题下反色二维码的相机解码率明显下降。
class SyncPairingQr extends StatelessWidget {
  const SyncPairingQr({
    super.key,
    required this.data,
    this.errorCorrectLevel = QrErrorCorrectLevel.medium,
  });

  final String data;

  /// 容错级别；默认 M（可容忍约 15% 污损，静态屏幕展示足够）。
  final QrErrorCorrectLevel errorCorrectLevel;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: errorCorrectLevel,
    ));
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: SyncPairingQrPainter(image),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// 二维码绘制：静区 4 模块（QR 规范的最小值，贴边会扫不出）。
class SyncPairingQrPainter extends CustomPainter {
  SyncPairingQrPainter(this.image, {this.quietZoneModules = 4});

  final QrImage image;
  final int quietZoneModules;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = image.moduleCount + quietZoneModules * 2;
    final module = math.min(size.width, size.height) / modules;
    final originX = (size.width - module * modules) / 2;
    final originY = (size.height - module * modules) / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = qrSurfaceColor);
    final paint = Paint()
      ..color = qrModuleColor
      ..isAntiAlias = false;
    for (var y = 0; y < image.moduleCount; y++) {
      for (var x = 0; x < image.moduleCount; x++) {
        if (!image.isDark(y, x)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            originX + (x + quietZoneModules) * module,
            originY + (y + quietZoneModules) * module,
            module,
            module,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant SyncPairingQrPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.quietZoneModules != quietZoneModules;
}
