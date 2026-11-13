/// 海报绘制的共享几何 / 文本 / 解码工具（歌词海报、列表海报共用）。
///
/// 只放无状态的绘制原语：裁切矩形、单段文本、受限解码与 dispose 责任。
/// 调用方仍拥有画布与图像生命周期；这里不读 provider / 主题 / 语言。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
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

/// 以垂直中心为基准绘制一段文本（歌词 / 列表海报共用）。
void posterPaintTextAligned(
  Canvas canvas,
  String text,
  Offset position,
  TextStyle style,
  double maxWidth,
  TextAlign textAlign,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: textAlign,
  )..layout(maxWidth: maxWidth);
  posterPaintTextPainter(canvas, painter, position, textAlign);
  painter.dispose();
}

/// 绘制已 layout 的 TextPainter；`position.y` 是垂直中心。
void posterPaintTextPainter(
  Canvas canvas,
  TextPainter painter,
  Offset position,
  TextAlign textAlign,
) {
  var dx = position.dx;
  if (textAlign == TextAlign.center) {
    dx -= painter.width / 2;
  } else if (textAlign == TextAlign.right) {
    dx -= painter.width;
  }
  painter.paint(canvas, Offset(dx, position.dy - painter.height / 2));
}

/// 裁剪到圆角并居中裁切绘制封面（不拉伸）。
void posterDrawCover(
  Canvas canvas,
  ui.Image image,
  Rect rect, {
  double cornerRadius = 0,
}) {
  canvas.save();
  if (cornerRadius > 0) {
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius)),
    );
  } else {
    canvas.clipRect(rect);
  }
  canvas.drawImageRect(
    image,
    posterCoverCropRect(
      sourceWidth: image.width.toDouble(),
      sourceHeight: image.height.toDouble(),
      targetWidth: rect.width,
      targetHeight: rect.height,
    ),
    rect,
    Paint()..filterQuality = FilterQuality.medium,
  );
  canvas.restore();
}

/// 按目标宽度解码 app asset；失败上抛，由调用方决定是否降级。
Future<ui.Image> posterLoadAssetImage(
  String assetPath, {
  required int targetWidth,
}) async {
  final data = await rootBundle.load(assetPath);
  return posterDecodeImage(data.buffer.asUint8List(), targetWidth: targetWidth);
}

/// 绘制品牌水印（可选图标 + 文案），以 [leftX] / [centerY] 为基准。
///
/// 返回占用高度（图标与文本同高）。图标用 [color] 着色，不修改源图。
double posterDrawWatermark(
  Canvas canvas, {
  required ui.Image? icon,
  required TextPainter painter,
  required double leftX,
  required double centerY,
  required Color color,
  double iconTextSpacing = 8,
}) {
  final iconSize = painter.height;
  final height = math.max(painter.height, iconSize);
  var textX = leftX;
  if (icon != null) {
    canvas.drawImageRect(
      icon,
      Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
      Rect.fromLTWH(leftX, centerY - iconSize / 2, iconSize, iconSize),
      Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
    );
    textX = leftX + iconSize + iconTextSpacing;
  }
  painter.paint(canvas, Offset(textX, centerY - painter.height / 2));
  return height;
}

/// 录制画布 → PNG 字节；picture / 位图由本函数统一释放。
Future<Uint8List> posterEncodePng(
  ui.PictureRecorder recorder, {
  required int width,
  required int height,
}) async {
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image?.dispose();
    picture.dispose();
  }
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
