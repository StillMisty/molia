/// 海报绘制的共享几何 / 文本 / 解码工具（歌词海报、列表海报共用）。
///
/// 只放无状态的绘制原语：裁切矩形、单段文本、受限解码与 dispose 责任。
/// 调用方仍拥有画布与图像生命周期；这里不读 provider / 主题 / 语言。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 方形目标区域的居中裁切矩形（`BoxFit.cover` 语义，不拉伸）。
///
/// 源图宽高比与目标不同时只裁不缩；任一边非正返回 [Rect.zero]。
Rect posterCoverCropRect({
  required double sourceWidth,
  required double sourceHeight,
  required double targetWidth,
  required double targetHeight,
}) {
  if (sourceWidth <= 0 ||
      sourceHeight <= 0 ||
      targetWidth <= 0 ||
      targetHeight <= 0) {
    return Rect.zero;
  }
  final scale = math.max(
    targetWidth / sourceWidth,
    targetHeight / sourceHeight,
  );
  final cropWidth = targetWidth / scale;
  final cropHeight = targetHeight / scale;
  return Rect.fromLTWH(
    (sourceWidth - cropWidth) / 2,
    (sourceHeight - cropHeight) / 2,
    cropWidth,
    cropHeight,
  );
}

/// 绘制一段文本并返回占用高度；`offset` 是左上角。
double posterPaintText(
  Canvas canvas,
  String text,
  Offset offset,
  TextStyle style,
  double maxWidth, {
  int maxLines = 1,
}) {
  if (text.isEmpty) return 0;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: '…',
    textAlign: TextAlign.left,
  )..layout(maxWidth: maxWidth);
  painter.paint(canvas, offset);
  final height = painter.height;
  painter.dispose();
  return height;
}

/// 按目标宽度等比解码图片；返回的图像由调用方 dispose。
Future<ui.Image> posterDecodeImage(
  Uint8List bytes, {
  required int targetWidth,
}) async {
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}
