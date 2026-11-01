/// 封面风格的纯 Dart 渲染器：输入原始图片字节，输出方形的 PNG 派生图。
///
/// 只做展示层派生：不写文件、不进自定义封面 / 同步、不参与取色与标签。
/// 纹理全部程序化生成，不携带任何第三方图片素材或水印。
///
/// 算法参考成熟开源实现后重写（没有复制代码 / 素材）：
/// - 线稿：guided filter（He et al.）先降噪去纹理，再对平滑亮度做 Sobel
///   边缘提取；等价于 GPUImage Sketch / XDoG 一类 NPR 线稿的简化版；
/// - 铅笔：GIMP / OpenCV pencilSketch 常用的 grayscale + invert + blur +
///   color-dodge 思路，再叠一层线稿找回结构；
/// - 墨印：GPUImage Halftone 的旋转网点思路，用局部明暗决定网点半径；
/// - 双色：把亮度映射到两色渐变（gradient map），再轻度 posterize + 套印偏移；
/// - 像素：块平均降采样后用 octree 量化 + Floyd–Steinberg 抖动，再最近邻放大；
/// - 胶片：split toning + 高光扩散 + 颗粒 + 暗角；
/// - 纹理：确定性哈希噪声，避免每次处理结果漂移。
///
/// 算法参数按输出边长自适应：小缩略图加粗线条、降低细节，避免 40dp 封面糊成
/// 一团。处理失败返回 null，展示层保持原图。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../../domain/models/cover_style.dart';

/// 封面风格派生的最长边（播放页大图上限）。
const int maxCoverStyleEdge = 768;

/// 纸白（不同风格共用一套暖白，避免纯白刺眼）。
const int _paperR = 251;
const int _paperG = 249;
const int _paperB = 244;

/// 渲染入口：解码 → 烘焙 EXIF → 中心方形裁切 → 缩放 → 风格化 → PNG。
///
/// 非法字节 / 不支持的格式 / 空图返回 null（调用方保持原图，不阻塞播放）。
abstract final class CoverStyleRenderer {
  static Uint8List? render(
    Uint8List bytes, {
    required CoverStyle style,
    required int edge,
  }) {
    if (!style.isStylized || bytes.isEmpty) return null;
    try {
      final decoded = image.decodeImage(bytes);
      if (decoded == null) return null;
      final oriented = image.bakeOrientation(decoded);
      // 动图 / 多帧只取第一帧：封面风格是静态展示，一次算好不逐帧重算。
      final source = oriented.numFrames > 1
          ? image.Image.from(oriented.frames.first, noAnimation: true)
          : oriented;
      final side = math.min(source.width, source.height);
      if (side <= 0) return null;
      final cropped = image.copyCrop(
        source,
        x: (source.width - side) ~/ 2,
        y: (source.height - side) ~/ 2,
        width: side,
        height: side,
      );
      final target = edge.clamp(2, maxCoverStyleEdge);
      final resized = cropped.width == target && cropped.height == target
          ? cropped
          : image.copyResize(
              cropped,
              width: target,
              height: target,
              interpolation: image.Interpolation.linear,
            );
      final prepared = _Prepared.fromImage(resized);
      final image.Image? output = switch (style) {
        CoverStyle.oneLastKiss => _oneLastKiss(prepared),
        CoverStyle.lineArt => _lineArt(prepared),
        CoverStyle.pencil => _pencil(prepared),
        CoverStyle.emboss => _emboss(prepared),
        CoverStyle.pixel => _pixel(resized, target),
        CoverStyle.ink => _ink(prepared),
        CoverStyle.duotone => _duotone(prepared),
        CoverStyle.film => _film(prepared),
        CoverStyle.original => null,
      };
      if (output == null) return null;
      return Uint8List.fromList(image.encodePng(output));
    } catch (_) {
      return null;
    }
  }
}

/// 处理用的不透明 RGB + 归一化亮度平面。
class _Prepared {
  _Prepared({
    required this.width,
    required this.height,
    required this.r,
    required this.g,
    required this.b,
    required this.luma,
  });

  factory _Prepared.fromImage(image.Image source) {
    final count = source.width * source.height;
    final rgba = source.getBytes(order: image.ChannelOrder.rgba);
    final r = Uint8List(count);
    final g = Uint8List(count);
    final b = Uint8List(count);
    final luma = Float32List(count);
    for (var i = 0; i < count; i++) {
      final o = i * 4;
      final alpha = rgba[o + 3];
      final red = alpha == 255
          ? rgba[o]
          : (rgba[o] * alpha + _paperR * (255 - alpha)) ~/ 255;
      final green = alpha == 255
          ? rgba[o + 1]
          : (rgba[o + 1] * alpha + _paperG * (255 - alpha)) ~/ 255;
      final blue = alpha == 255
          ? rgba[o + 2]
          : (rgba[o + 2] * alpha + _paperB * (255 - alpha)) ~/ 255;
      r[i] = red;
      g[i] = green;
      b[i] = blue;
      luma[i] = (red * 0.2125 + green * 0.7154 + blue * 0.0721) / 255;
    }
    return _Prepared(
      width: source.width,
      height: source.height,
      r: r,
      g: g,
      b: b,
      luma: luma,
    );
  }

  final int width;
  final int height;
  final Uint8List r;
  final Uint8List g;
  final Uint8List b;
  final Float32List luma;

  int get length => width * height;

  int index(int x, int y) => y * width + x;
}

/// 输出用的方形图像。
image.Image _output(int width, int height) =>
    image.Image(width: width, height: height, numChannels: 3);

/// 小缩略图（64/128 桶）需要更粗的线；缓存桶决定 40dp 在 2x/3x 下的尺寸。
bool _small(int width) => width <= 128;

/// 参数按目标边长缩放：512px 是调参基准。
double _scale(int width) => (width / 512).clamp(0.2, 1.6);

int _radius(int base, int width) => math.max(2, (base * _scale(width)).round());

double _sigma(double base, int width) =>
    math.max(1.0, math.min(10.0, base * _scale(width)));

/// One Last Kiss：白纸 + 彩色线稿。线稿用软掩码收硬边，再填固定彩虹渐变。
image.Image _oneLastKiss(_Prepared src) {
  final w = src.width;
  final h = src.height;
  final soft = _lineMask(src.luma, w, h, radius: _radius(9, w));
  final mask = Float32List(src.length);
  for (var i = 0; i < mask.length; i++) {
    mask[i] = soft[i] >= 0.42 ? 1.0 : 0.0;
  }
  final line = _dilate(mask, w, h);
  final out = _output(w, h);
  // 暖金 → 橙红 → 紫 → 蓝的固定斜向渐变，接近 One Last Kiss 封面的彩虹线。
  const stops = [
    [0.0, 250, 170, 26],
    [0.22, 246, 86, 28],
    [0.42, 214, 28, 92],
    [0.62, 122, 30, 178],
    [0.82, 20, 112, 210],
    [1.0, 16, 168, 208],
  ];
  double gradientAt(double t, int channel) {
    for (var i = 0; i < stops.length - 1; i++) {
      final a = stops[i];
      final b = stops[i + 1];
      if (t <= b[0]) {
        final f = ((t - a[0]) / (b[0] - a[0])).clamp(0.0, 1.0);
        return a[channel + 1] + (b[channel + 1] - a[channel + 1]) * f;
      }
    }
    return stops.last[channel + 1].toDouble();
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = src.index(x, y);
      final tone0 = line[i].clamp(0.0, 1.0);
      // 只在真正的暗部补色，避免中间调被整片渐变洗淡。
      final deep = src.luma[i] < 0.18
          ? math.pow((0.18 - src.luma[i]) / 0.18, 1.5).toDouble() * 0.35
          : 0.0;
      final tone = math.max(tone0, deep).clamp(0.0, 1.0);
      final u = (x / w) * 0.55 + (y / h) * 0.45;
      final paper = 251 + (_noise(x, y, 19) - 0.5) * 3;
      out.setPixelRgb(
        x,
        y,
        (gradientAt(u, 0) * tone + paper * (1 - tone)).round(),
        (gradientAt(u, 1) * tone + (paper - 2) * (1 - tone)).round(),
        (gradientAt(u, 2) * tone + (paper - 7) * (1 - tone)).round(),
      );
    }
  }
  return out;
}

/// 纯线稿：guided filter 降噪后的 Sobel 线，纸白底。
image.Image _lineArt(_Prepared src) {
  final w = src.width;
  final h = src.height;
  final mask = _lineMask(
    src.luma,
    w,
    h,
    radius: _radius(9, w),
    dilate: _small(w),
  );
  final out = _output(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = src.index(x, y);
      final paper = 249 + (_noise(x, y, 17) - 0.5) * 4;
      final value = (paper + (14 - paper) * mask[i]).round();
      out.setPixelRgb(x, y, value, value, value);
    }
  }
  return out;
}

/// 铅笔素描：color dodge 出柔和石墨调，再叠一层线稿找回结构。
image.Image _pencil(_Prepared src) {
  final w = src.width;
  final h = src.height;
  final smooth = _guided(src.luma, w, h, _radius(8, w), 0.015);
  final line = _lineMask(
    src.luma,
    w,
    h,
    radius: _radius(9, w),
    dilate: _small(w),
  );
  final inv = Float32List(src.length);
  for (var i = 0; i < inv.length; i++) {
    inv[i] = 1 - smooth[i];
  }
  final blurInv = _gauss(inv, w, h, _sigma(9, w));
  final out = _output(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = src.index(x, y);
      var sketch = (src.luma[i] / (1 - blurInv[i] + 0.015)).clamp(0.0, 1.0);
      sketch = _smoothstep(0.12, 0.95, sketch);
      sketch = math.pow(sketch, 1.35).toDouble();
      sketch *= 1 - line[i] * 0.55;
      // 给暗部补一点石墨调：纯 dodge 在亮场景里会把主体冲得太淡。
      final shade = (1 - smooth[i]) * 0.28;
      sketch = math.min(sketch, 1 - shade);
      final paper = 249 + (_noise(x, y, 13) - 0.5) * 5;
      final value = (26 + (paper - 26) * sketch).round();
      out.setPixelRgb(x, y, value, value, value);
    }
  }
  return out;
}

/// 浮雕版画：平滑亮度上的方向性压印，保留一点原图明暗。
image.Image _emboss(_Prepared src) {
  final w = src.width;
  final h = src.height;
  final smooth = _guided(src.luma, w, h, _radius(4, w), 0.02);
  final out = _output(w, h);
  for (var y = 0; y < h; y++) {
    final ty = (y - 2).clamp(0, h - 1);
    final by = (y + 2).clamp(0, h - 1);
    for (var x = 0; x < w; x++) {
      final i = src.index(x, y);
      final lx = (x - 2).clamp(0, w - 1);
      final rx = (x + 2).clamp(0, w - 1);
      final relief =
          (smooth[src.index(lx, ty)] - smooth[src.index(rx, by)]) * 2.2 * 255;
      final local = (src.luma[i] - smooth[i]) * 1.1 * 255;
      var value = 128 * 0.62 + src.luma[i] * 255 * 0.38 + relief + local;
      value = 128 + (value - 128) * 1.12;
      value += (_noise(x, y, 53) - 0.5) * 10;
      final clamped = value.clamp(16, 238).toInt();
      out.setPixelRgb(x, y, clamped, clamped, clamped);
    }
  }
  return out;
}

/// 像素风：块平均降采样 + octree 量化 + Floyd–Steinberg 抖动 + 最近邻放大。
image.Image _pixel(image.Image src, int edge) {
  final blocks = edge <= 128
      ? 24
      : edge <= 256
      ? 32
      : edge <= 512
      ? 48
      : 64;
  final block = math.max(2, (src.width / blocks).round());
  final down = image.Image(
    width: (src.width / block).ceil(),
    height: (src.height / block).ceil(),
  );
  for (var by = 0; by < down.height; by++) {
    for (var bx = 0; bx < down.width; bx++) {
      var sumR = 0;
      var sumG = 0;
      var sumB = 0;
      var count = 0;
      final maxY = math.min((by + 1) * block, src.height);
      final maxX = math.min((bx + 1) * block, src.width);
      for (var y = by * block; y < maxY; y++) {
        for (var x = bx * block; x < maxX; x++) {
          final p = src.getPixel(x, y);
          sumR += p.r.toInt();
          sumG += p.g.toInt();
          sumB += p.b.toInt();
          count++;
        }
      }
      if (count > 0) {
        down.setPixelRgb(bx, by, sumR ~/ count, sumG ~/ count, sumB ~/ count);
      }
    }
  }
  final quantized = image.quantize(
    down,
    numberOfColors: 32,
    method: image.QuantizeMethod.octree,
    dither: image.DitherKernel.floydSteinberg,
  );
  return image.copyResize(
    quantized,
    width: edge,
    height: edge,
    interpolation: image.Interpolation.nearest,
  );
}

/// 黑白墨印：旋转网点，保留明暗层次而不是直接阈值成剪影。
image.Image _ink(_Prepared src) {
  final w = src.width;
  final h = src.height;
  final smooth = _guided(src.luma, w, h, _radius(10, w), 0.02);
  final out = _output(w, h);
  final cell = math.max(3, (w / 110).round()).toDouble();
  const theta = math.pi / 4;
  final cosT = math.cos(theta);
  final sinT = math.sin(theta);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = src.index(x, y);
      final u = (x * cosT + y * sinT) / cell;
      final v = (-x * sinT + y * cosT) / cell;
      final fx = (u - u.floor() - 0.5).abs();
      final fy = (v - v.floor() - 0.5).abs();
      final dist = math.sqrt(fx * fx + fy * fy);
      final tone = smooth[i];
      final radius = 0.62 * math.sqrt(1 - tone);
      final dot = 1 - _smoothstep(radius - 0.04, radius + 0.04, dist);
      final paper = 248 + (_noise(x, y, 61) - 0.5) * 4;
      final value = (paper + (18 - paper) * dot).round();
      out.setPixelRgb(x, y, value, value, value);
    }
  }
  return out;
}

/// 双色印刷：亮度 → 两色渐变的 gradient map，轻度 posterize + 套印偏移。
image.Image _duotone(_Prepared src) {
  final w = src.width;
  final h = src.height;
  final smooth = _guided(src.luma, w, h, _radius(8, w), 0.015);
  final out = _output(w, h);
  const dark = (24, 33, 74);
  const light = (244, 201, 76);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = src.index(x, y);
      final t = _smoothstep(0.03, 0.97, smooth[i]);
      final q = (t * 8).round() / 8;
      final sx = (x + 1).clamp(0, w - 1);
      final sy = (y + 1).clamp(0, h - 1);
      final shifted = _smoothstep(0.03, 0.97, smooth[sy * w + sx]);
      final q2 = (shifted * 8).round() / 8;
      final grain = (_noise(x, y, 29) - 0.5) * 7;
      final r =
          (dark.$1 + (light.$1 - dark.$1) * q) * 0.88 +
          (dark.$1 + (light.$1 - dark.$1) * q2) * 0.12 +
          grain;
      final g =
          (dark.$2 + (light.$2 - dark.$2) * q) * 0.88 +
          (dark.$2 + (light.$2 - dark.$2) * q2) * 0.12 +
          grain;
      final b =
          (dark.$3 + (light.$3 - dark.$3) * q) * 0.88 +
          (dark.$3 + (light.$3 - dark.$3) * q2) * 0.12 +
          grain;
      out.setPixelRgb(
        x,
        y,
        r.round().clamp(0, 255),
        g.round().clamp(0, 255),
        b.round().clamp(0, 255),
      );
    }
  }
  return out;
}

/// 胶片颗粒：split toning + 高光扩散 + 颗粒 + 暗角。
image.Image _film(_Prepared src) {
  final w = src.width;
  final h = src.height;
  final out = _output(w, h);
  final bright = Float32List(src.length);
  for (var i = 0; i < src.length; i++) {
    bright[i] = ((src.luma[i] - 0.55) / 0.45).clamp(0.0, 1.0);
  }
  final glow = _gauss(bright, w, h, _sigma(8, w));
  final cx = (w - 1) / 2;
  final cy = (h - 1) / 2;
  final radius = math.sqrt(cx * cx + cy * cy);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = src.index(x, y);
      final dx = (x - cx) / radius;
      final dy = (y - cy) / radius;
      final vignette = 1 - 0.44 * math.pow(dx * dx + dy * dy, 1.6);
      final bloom = math.pow(glow[i], 1.4).toDouble() * 90;
      final l = src.luma[i];
      final shadowTeal = l < 0.28 ? (0.28 - l) * 18 : 0.0;
      final grain = (_noise(x, y, 37) - 0.5) * 12;
      final r =
          (src.r[i] * 1.06 + 9 + bloom + grain - shadowTeal * 0.3) * vignette;
      final g =
          (src.g[i] * 1.01 +
              5 +
              bloom * 0.55 +
              grain * 0.9 +
              shadowTeal * 0.55) *
          vignette;
      final b =
          (src.b[i] * 0.9 + 1 + bloom * 0.28 + grain * 0.7 + shadowTeal) *
          vignette;
      out.setPixelRgb(
        x,
        y,
        r.round().clamp(0, 255),
        g.round().clamp(0, 255),
        b.round().clamp(0, 255),
      );
    }
  }
  return out;
}

/// 线稿掩码：guided filter 降噪后的 Sobel 梯度，smoothstep 成软线。
Float32List _lineMask(
  Float32List src,
  int w,
  int h, {
  required int radius,
  bool dilate = false,
}) {
  final smooth = _guided(src, w, h, radius, 0.03);
  final g = _sobel(smooth, w, h);
  final low = w <= 128 ? 0.12 : 0.14;
  final high = w <= 128 ? 0.38 : 0.46;
  final out = Float32List(src.length);
  for (var i = 0; i < src.length; i++) {
    final mag = math.sqrt(g.gx[i] * g.gx[i] + g.gy[i] * g.gy[i]);
    out[i] = _smoothstep(low, high, mag);
  }
  return dilate ? _dilate(out, w, h) : out;
}

/// 自引导 guided filter（He et al.）：O(n) 盒式滤波，保边降纹理。
Float32List _guided(Float32List src, int w, int h, int radius, double eps) {
  final mean = _box(src, w, h, radius);
  final squared = Float32List(src.length);
  for (var i = 0; i < src.length; i++) {
    squared[i] = src[i] * src[i];
  }
  final meanSquared = _box(squared, w, h, radius);
  final a = Float32List(src.length);
  final b = Float32List(src.length);
  for (var i = 0; i < src.length; i++) {
    final variance = math.max(0.0, meanSquared[i] - mean[i] * mean[i]);
    final ai = variance / (variance + eps);
    a[i] = ai;
    b[i] = mean[i] - ai * mean[i];
  }
  final meanA = _box(a, w, h, radius);
  final meanB = _box(b, w, h, radius);
  final out = Float32List(src.length);
  for (var i = 0; i < src.length; i++) {
    out[i] = (meanA[i] * src[i] + meanB[i]).clamp(0.0, 1.0);
  }
  return out;
}

({Float32List gx, Float32List gy}) _sobel(Float32List src, int w, int h) {
  final gx = Float32List(src.length);
  final gy = Float32List(src.length);
  for (var y = 0; y < h; y++) {
    final up = y > 0 ? y - 1 : y;
    final down = y < h - 1 ? y + 1 : y;
    for (var x = 0; x < w; x++) {
      final l = x > 0 ? x - 1 : x;
      final r = x < w - 1 ? x + 1 : x;
      gx[y * w + x] =
          -src[up * w + l] -
          2 * src[y * w + l] -
          src[down * w + l] +
          src[up * w + r] +
          2 * src[y * w + r] +
          src[down * w + r];
      gy[y * w + x] =
          -src[up * w + l] -
          2 * src[up * w + x] -
          src[up * w + r] +
          src[down * w + l] +
          2 * src[down * w + x] +
          src[down * w + r];
    }
  }
  return (gx: gx, gy: gy);
}

Float32List _dilate(Float32List src, int w, int h) {
  final out = Float32List(src.length);
  for (var y = 0; y < h; y++) {
    final up = y > 0 ? y - 1 : y;
    final down = y < h - 1 ? y + 1 : y;
    for (var x = 0; x < w; x++) {
      final l = x > 0 ? x - 1 : x;
      final r = x < w - 1 ? x + 1 : x;
      var value = src[y * w + x];
      value = math.max(value, src[up * w + l]);
      value = math.max(value, src[up * w + x]);
      value = math.max(value, src[up * w + r]);
      value = math.max(value, src[y * w + l]);
      value = math.max(value, src[y * w + r]);
      value = math.max(value, src[down * w + l]);
      value = math.max(value, src[down * w + x]);
      value = math.max(value, src[down * w + r]);
      out[y * w + x] = value;
    }
  }
  return out;
}

/// 可分离盒式模糊（两次一维滑动窗口，O(n)）。
Float32List _box(Float32List src, int w, int h, int radius) {
  if (radius <= 0 || w <= 0 || h <= 0) return Float32List.fromList(src);
  final window = radius * 2 + 1;
  final horizontal = Float32List(w * h);
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var sum = 0.0;
    for (var k = -radius; k <= radius; k++) {
      sum += src[row + k.clamp(0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      horizontal[row + x] = sum / window;
      sum +=
          src[row + (x + radius + 1).clamp(0, w - 1)] -
          src[row + (x - radius).clamp(0, w - 1)];
    }
  }
  for (var x = 0; x < w; x++) {
    var sum = 0.0;
    for (var k = -radius; k <= radius; k++) {
      sum += horizontal[k.clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] = sum / window;
      sum +=
          horizontal[(y + radius + 1).clamp(0, h - 1) * w + x] -
          horizontal[(y - radius).clamp(0, h - 1) * w + x];
    }
  }
  return out;
}

/// 可分离高斯模糊：线稿 / 铅笔 / 胶片的高光扩散共用。
Float32List _gauss(Float32List src, int w, int h, double sigma) {
  final radius = math.max(1, (sigma * 3).round());
  final kernel = Float32List(radius * 2 + 1);
  var total = 0.0;
  for (var i = -radius; i <= radius; i++) {
    final value = math.exp(-(i * i) / (2 * sigma * sigma));
    kernel[i + radius] = value;
    total += value;
  }
  for (var i = 0; i < kernel.length; i++) {
    kernel[i] /= total;
  }
  final horizontal = Float32List(w * h);
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 0.0;
      for (var k = -radius; k <= radius; k++) {
        sum += src[y * w + (x + k).clamp(0, w - 1)] * kernel[k + radius];
      }
      horizontal[y * w + x] = sum;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 0.0;
      for (var k = -radius; k <= radius; k++) {
        sum += horizontal[(y + k).clamp(0, h - 1) * w + x] * kernel[k + radius];
      }
      out[y * w + x] = sum;
    }
  }
  return out;
}

double _smoothstep(double low, double high, double value) {
  if (high <= low) return value >= high ? 1 : 0;
  final t = ((value - low) / (high - low)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// 确定性哈希噪声（0..1）：同一张图重复处理结果一致，测试可断言纹理。
double _noise(int x, int y, int seed) {
  var value = x * 0x1f1f1f1f ^ y * 0x27d4eb2d ^ seed * 0x165667b1;
  value = (value ^ (value >> 15)) * 0x85ebca6b;
  value = (value ^ (value >> 13)) * 0xc2b2ae35;
  value ^= value >> 16;
  return (value & 0xFFFF) / 65535.0;
}
