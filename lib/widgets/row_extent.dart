/// 固定行高列表的行高测量：按系统文字缩放放大 M3E 字阶的行高，
/// 再与 M3E 列表 token 取较大值。
///
/// 为什么需要共享 helper：`itemExtent` 与行内 `SizedBox` 必须同源，
/// 各列表各写一份 `textScaler.scale(fontSize) * height` 迟早漂移；
/// 大字体下 extent 小于实际内容会被裁切，反过来滚动条拇指和拖动定位失准。
/// token 只作为最小值——1.0× 下仍保持 M3E 既有的 56 / 72，不改变默认视觉。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 单个文本样式的整行高度（按 [MediaQuery.textScalerOf] 缩放后向上取整）。
///
/// 用 [TextPainter] 而不是 `fontSize × height`：真实 CJK 字体（Noto Sans CJK
/// 等）的 ascent / descent 可能高于 M3E 的 `height` 倍率，公式会漏算 2–4px，
/// 大字号下正好把卡片底部裁掉。结果按「样式 + 文字缩放」缓存，行构建不重复
/// 排版。
double scaledLineHeightOf(BuildContext context, TextStyle style) =>
    lineHeightFor(style, MediaQuery.textScalerOf(context));

/// 指定缩放下的文本行高（供需要同时比较 1.0× 基线的调用方使用）。
double lineHeightFor(TextStyle style, TextScaler scaler) {
  final key = (style: style, scaler: scaler);
  final cached = _lineHeightCache[key];
  if (cached != null) return cached;

  final painter = TextPainter(
    // 同时覆盖 CJK 与拉丁字形：CJK 字体回退的 ascent / descent 更高，
    // 按它测出的行高对两种文本都安全。
    text: TextSpan(text: '歌Ag', style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final measured = painter.height;
  painter.dispose();
  // 向上取整容 1e-6 浮点尾差：extent 比真实高度少零点几像素时，固定高度
  // 会把最后一行裁掉。
  final height = (measured - 1e-6).ceilToDouble();
  _lineHeightCache[key] = height;
  return height;
}

final Map<({TextStyle style, TextScaler scaler}), double> _lineHeightCache = {};

/// 行高：多行文本按 [stacked] 累加 / 取最高，再与 [minExtent] 取较大值。
///
/// [extra] 是行内固定间距（例如卡片标题与副标题之间的 2dp），
/// [allowance] 是给不同字体回退 / 字形度量预留的安全余量（只在内容确实
/// 顶到 token 上限时才生效，不会抬高 1.0× 的默认行高），
/// [padding] 是行内上下内边距（卡片 8+8）；两者都不含在 [minExtent] 里。
double scaledRowExtentOf(
  BuildContext context, {
  required double minExtent,
  required Iterable<TextStyle> styles,
  bool stacked = false,
  double extra = 0,
  double allowance = 0,
  double padding = 0,
}) {
  final heights = [
    for (final style in styles) scaledLineHeightOf(context, style),
  ];
  final content = stacked
      ? heights.fold<double>(0, (sum, height) => sum + height) +
            extra +
            allowance
      : heights.fold<double>(0, math.max) + allowance;
  return math.max(minExtent, content) + padding;
}
