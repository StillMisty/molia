/// 封面风格的纯 Dart 渲染器：输入原始图片字节，输出方形的 PNG 派生图。
///
/// 只做展示层派生：不写文件、不进自定义封面 / 同步、不参与取色与标签。
/// 纹理全部程序化生成（哈希噪声 / 盒式模糊 / 索伯边缘），不携带任何第三方
/// 图片素材或水印。算法参数按输出边长自适应：小缩略图加粗线条、降低细节，
/// 避免 40dp 列表封面糊成一团。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../../domain/models/cover_style.dart';

/// 封面风格派生的最长边（播放页大图上限）。
const int maxCoverStyleEdge = 768;

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
      final target = edge.clamp(1, maxCoverStyleEdge);
      final resized = cropped.width == target && cropped.height == target
          ? cropped
          : image.copyResize(
              cropped,
              width: target,
              height: target,
              interpolation: image.Interpolation.linear,
            );
      final rgba = resized.getBytes(order: image.ChannelOrder.rgba);
      final raster = _Raster.fromRgba(target, target, rgba);
      final rgb = switch (style) {
        CoverStyle.oneLastKiss => _oneLastKiss(raster),
        CoverStyle.lineArt => _lineArt(raster),
        CoverStyle.pencil => _pencil(raster),
        CoverStyle.emboss => _emboss(raster),
        CoverStyle.pixel => _pixel(raster),
        CoverStyle.ink => _ink(raster),
        CoverStyle.duotone => _duotone(raster),
        CoverStyle.film => _film(raster),
        CoverStyle.original => null,
      };
      if (rgb == null) return null;
      final output = image.Image.fromBytes(
        width: target,
        height: target,
        bytes: rgb.buffer,
        numChannels: 3,
      );
      return Uint8List.fromList(image.encodePng(output));
    } catch (_) {
      // 解码 / 像素处理失败一律返回 null：展示层保持原图。
      return null;
    }
  }
}

/// RGB 平面（alpha 已按纸白合成，避免透明 PNG 变黑块）。
class _Raster {
  _Raster(this.width, this.height, this.r, this.g, this.b);

  factory _Raster.fromRgba(int width, int height, Uint8List rgba) {
    final count = width * height;
    final r = Uint8List(count);
    final g = Uint8List(count);
    final b = Uint8List(count);
    for (var i = 0; i < count; i++) {
      final offset = i * 4;
      final alpha = rgba[offset + 3];
      if (alpha == 255) {
        r[i] = rgba[offset];
        g[i] = rgba[offset + 1];
        b[i] = rgba[offset + 2];
      } else {
        // 透明区域按纸白合成：后续所有风格都假定不透明输入。
        final inverse = 255 - alpha;
        r[i] = (rgba[offset] * alpha + 250 * inverse) ~/ 255;
        g[i] = (rgba[offset + 1] * alpha + 248 * inverse) ~/ 255;
        b[i] = (rgba[offset + 2] * alpha + 242 * inverse) ~/ 255;
      }
    }
    return _Raster(width, height, r, g, b);
  }

  final int width;
  final int height;
  final Uint8List r;
  final Uint8List g;
  final Uint8List b;

  int get length => width * height;

  int index(int x, int y) => y * width + x;
}

// 小图分界按 128 桶而不是 96px：缓存桶只有 64 / 128，40dp 列表封面在
// 2x / 3x 下会落进 128 桶；若仍按 96 判断，加粗线条 / 降细节永远不会触发。
Uint8List _oneLastKiss(_Raster src) {
  final maps = _edgeMaps(src, src.width);
  final gray = maps.gray;
  final edge = maps.edge;
  final output = Uint8List(src.length * 3);
  final width = src.width;
  final height = src.height;
  // 低阈值让铅笔线在明亮区域也能留下轮廓；暗部另走铅笔调子。
  final lineLow = width <= 128 ? 0.055 : 0.08;
  final lineHigh = width <= 128 ? 0.22 : 0.3;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = src.index(x, y);
      final line = _smoothStep(lineLow, lineHigh, edge[i] / 255);
      final shade = math.pow(1 - gray[i] / 255, 1.55).toDouble();
      final tone = math.max(line, shade * 0.62).clamp(0.0, 1.0);
      // 固定彩虹渐变（不依赖主题 / 封面主色）：横向为主、纵向轻微偏移。
      final hue = ((x / width) * 265 + (y / height) * 95 + 8) % 360;
      final ink = _hsvToRgb(hue, 0.58 + 0.3 * line, 0.76 - 0.12 * shade);
      final paperNoise = (_noise(x, y, 11) - 0.5) * 5;
      final paperR = 251 + paperNoise;
      final paperG = 249 + paperNoise;
      final paperB = 244 + paperNoise;
      final alpha = (tone * 0.94).clamp(0.0, 1.0);
      final offset = i * 3;
      output[offset] = _mixChannel(paperR, ink.$1, alpha);
      output[offset + 1] = _mixChannel(paperG, ink.$2, alpha);
      output[offset + 2] = _mixChannel(paperB, ink.$3, alpha);
    }
  }
  return output;
}

Uint8List _lineArt(_Raster src) {
  final maps = _edgeMaps(src, src.width);
  final edge = maps.edge;
  final output = Uint8List(src.length * 3);
  final width = src.width;
  final low = width <= 128 ? 0.06 : 0.1;
  final high = width <= 128 ? 0.24 : 0.33;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < width; x++) {
      final i = src.index(x, y);
      final line = _smoothStep(low, high, edge[i] / 255);
      // 纸白带极轻的纸纹；线条接近纯黑，中间只留一点点抗锯齿灰。
      final paper = 249 + (_noise(x, y, 23) - 0.5) * 4;
      final value = _mixChannel(paper, 12, line);
      final offset = i * 3;
      output[offset] = value;
      output[offset + 1] = value;
      output[offset + 2] = value;
    }
  }
  return output;
}

Uint8List _pencil(_Raster src) {
  final maps = _edgeMaps(src, src.width);
  final gray = maps.gray;
  final edge = maps.edge;
  final output = Uint8List(src.length * 3);
  final width = src.width;
  final low = width <= 128 ? 0.065 : 0.095;
  final high = width <= 128 ? 0.26 : 0.34;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < width; x++) {
      final i = src.index(x, y);
      final line = _smoothStep(low, high, edge[i] / 255);
      final shade = math.pow(1 - gray[i] / 255, 1.35).toDouble();
      final tone = math.max(line * 0.95, shade * 0.8).clamp(0.0, 1.0);
      final paper = 247 + (_noise(x, y, 37) - 0.5) * 6;
      // 斜向排线：只在暗面出现，让石墨调子看起来是手绘而不是灰块。
      final hatch = ((x + y) % 7 < 2 && shade > 0.16 && line < 0.9)
          ? shade * 0.13
          : 0.0;
      final graphite = 56 + (_noise(x, y, 41) - 0.5) * 24;
      final value = _mixChannel(paper, graphite, tone) - hatch * 150;
      final clamped = value.clamp(0, 255).toInt();
      final offset = i * 3;
      output[offset] = clamped;
      output[offset + 1] = clamped;
      output[offset + 2] = clamped;
    }
  }
  return output;
}

Uint8List _emboss(_Raster src) {
  final gray = _grayscale(src);
  final softened = _boxBlur(gray, src.width, src.height, 1);
  final output = Uint8List(src.length * 3);
  final width = src.width;
  final height = src.height;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = src.index(x, y);
      final lx = (x - 2).clamp(0, width - 1);
      final rx = (x + 2).clamp(0, width - 1);
      final ty = (y - 2).clamp(0, height - 1);
      final by = (y + 2).clamp(0, height - 1);
      // 强侧光（左上 → 右下）+ 局部高反差；压印面保留一点原图明暗。
      final relief = (gray[src.index(lx, ty)] - gray[src.index(rx, by)]) * 2.15;
      final local = (gray[i] - softened[i]) * 1.35;
      var value = 128 * 0.62 + gray[i] * 0.38 + relief + local;
      value = 128 + (value - 128) * 1.16;
      value += (_noise(x, y, 53) - 0.5) * 12;
      final clamped = value.clamp(16, 238).toInt();
      final offset = i * 3;
      output[offset] = clamped;
      output[offset + 1] = clamped;
      output[offset + 2] = clamped;
    }
  }
  return output;
}

const int _pixelPaletteSize = 24;
const List<int> _pixelPalette = [
  0x111318, // 墨黑
  0x3A3F4A, // 深灰
  0x7A8290, // 灰
  0xC8CDD6, // 浅灰
  0xFAFAF5, // 纸白
  0x1A2038, // 深海军蓝
  0x3B3F8F, // 靛蓝
  0x2F6FDC, // 蓝
  0x6FC3FF, // 天蓝
  0x1F8A70, // 水鸭绿
  0x8FE3C0, // 薄荷绿
  0x245B3C, // 森林绿
  0x7C8A3A, // 橄榄绿
  0xFFD93D, // 明黄
  0xF4A62A, // 琥珀
  0xE86A33, // 橙
  0xFF7F6B, // 珊瑚
  0xC9314A, // 红
  0xFF9EC4, // 粉
  0x8D5BD6, // 紫
  0xC8B6FF, // 薰衣草
  0x6B4B3A, // 棕
  0xE8D5B7, // 米色
  0xFFF4D6, // 奶油
];

Uint8List _pixel(_Raster src) {
  final width = src.width;
  final height = src.height;
  final targetBlocks = width <= 128
      ? 14
      : width <= 256
      ? 20
      : 28;
  final block = math.max(2, (width / targetBlocks).round());
  final output = Uint8List(src.length * 3);
  for (var by = 0; by < height; by += block) {
    final maxY = math.min(by + block, height);
    for (var bx = 0; bx < width; bx += block) {
      final maxX = math.min(bx + block, width);
      var sumR = 0;
      var sumG = 0;
      var sumB = 0;
      var count = 0;
      for (var y = by; y < maxY; y++) {
        for (var x = bx; x < maxX; x++) {
          final i = src.index(x, y);
          sumR += src.r[i];
          sumG += src.g[i];
          sumB += src.b[i];
          count++;
        }
      }
      if (count == 0) continue;
      final color = _nearestPalette(
        sumR ~/ count,
        sumG ~/ count,
        sumB ~/ count,
      );
      for (var y = by; y < maxY; y++) {
        for (var x = bx; x < maxX; x++) {
          final offset = src.index(x, y) * 3;
          output[offset] = color.$1;
          output[offset + 1] = color.$2;
          output[offset + 2] = color.$3;
        }
      }
    }
  }
  return output;
}

(int, int, int) _nearestPalette(int r, int g, int b) {
  var best = 0;
  var bestDistance = 1 << 30;
  for (var index = 0; index < _pixelPaletteSize; index++) {
    final value = _pixelPalette[index];
    final dr = r - ((value >> 16) & 0xFF);
    final dg = g - ((value >> 8) & 0xFF);
    final db = b - (value & 0xFF);
    // 人眼对绿色更敏感：加权距离比 RGB 欧氏距离更接近调色板观感。
    final distance = dr * dr * 3 + dg * dg * 5 + db * db * 2;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = value;
    }
  }
  return ((best >> 16) & 0xFF, (best >> 8) & 0xFF, best & 0xFF);
}

Uint8List _ink(_Raster src) {
  final gray = _grayscale(src);
  final softened = _boxBlur(
    gray,
    src.width,
    src.height,
    src.width <= 128 ? 1 : 2,
  );
  final output = Uint8List(src.length * 3);
  final width = src.width;
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < width; x++) {
      final i = src.index(x, y);
      // 印刷网点只看平滑后的明暗；颗粒把边界打碎，避免像纯阈值海报。
      final tone = (softened[i] * 0.78 + gray[i] * 0.22) / 255;
      final jitter = (_noise(x, y, 67) - 0.5) * 0.11;
      final value = tone + jitter;
      final channel = value < 0.32
          ? 12
          : value < 0.62
          ? 96
          : 246;
      final offset = i * 3;
      output[offset] = channel;
      output[offset + 1] = channel;
      output[offset + 2] = channel;
    }
  }
  return output;
}

// 固定大胆配色（不依赖主题色）：深靛蓝 + 暖黄，像两张油墨叠印。
const int _duotoneDarkR = 27;
const int _duotoneDarkG = 42;
const int _duotoneDarkB = 91;
const int _duotoneLightR = 242;
const int _duotoneLightG = 201;
const int _duotoneLightB = 76;

Uint8List _duotone(_Raster src) {
  final gray = _grayscale(src);
  final output = Uint8List(src.length * 3);
  final width = src.width;
  final height = src.height;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = src.index(x, y);
      final tone = (gray[i] / 255 - 0.5) * 1.45 + 0.5;
      // 第二块印版向右下偏移 1px：深墨边缘出现轻微套印错位。
      final offsetX = (x + 1).clamp(0, width - 1);
      final offsetY = (y + 1).clamp(0, height - 1);
      final shifted =
          (gray[src.index(offsetX, offsetY)] / 255 - 0.5) * 1.45 + 0.5;
      final dark = tone < 0.5 || shifted < 0.5;
      final offset = i * 3;
      if (dark) {
        output[offset] = _duotoneDarkR;
        output[offset + 1] = _duotoneDarkG;
        output[offset + 2] = _duotoneDarkB;
      } else {
        output[offset] = _duotoneLightR;
        output[offset + 1] = _duotoneLightG;
        output[offset + 2] = _duotoneLightB;
      }
    }
  }
  return output;
}

Uint8List _film(_Raster src) {
  final gray = _grayscale(src);
  final width = src.width;
  final height = src.height;
  final glowRadius = math.max(2, width ~/ 22);
  final glow = _boxBlur(gray, width, height, glowRadius);
  final output = Uint8List(src.length * 3);
  final centerX = (width - 1) / 2;
  final centerY = (height - 1) / 2;
  final radius = math.sqrt(centerX * centerX + centerY * centerY);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = src.index(x, y);
      final luma = gray[i] / 255;
      final highlight = ((glow[i] / 255 - 0.62) / 0.38).clamp(0.0, 1.0);
      final bloom = math.pow(highlight, 1.6).toDouble() * 82;
      // 暖色：高光偏琥珀、阴影略抬红；蓝通道整体收一点。
      var red = src.r[i] * 1.07 + 10 + bloom * 1.0;
      var green = src.g[i] * 1.02 + 5 + bloom * 0.72;
      var blue = src.b[i] * 0.9 + 2 + bloom * 0.36;
      if (luma < 0.32) {
        final lift = (0.32 - luma) * 26;
        red += lift;
        green += lift * 0.55;
      }
      final grain = (_noise(x, y, 89) - 0.5) * (width <= 128 ? 30 : 22);
      final dx = (x - centerX) / (radius <= 0 ? 1 : radius);
      final dy = (y - centerY) / (radius <= 0 ? 1 : radius);
      final distance = math.sqrt(dx * dx + dy * dy);
      final vignette = 1 - 0.58 * math.pow(distance, 1.75).toDouble();
      final offset = i * 3;
      output[offset] = ((red + grain) * vignette).clamp(0, 255).toInt();
      output[offset + 1] = ((green + grain * 0.9) * vignette)
          .clamp(0, 255)
          .toInt();
      output[offset + 2] = ((blue + grain * 0.75) * vignette)
          .clamp(0, 255)
          .toInt();
    }
  }
  return output;
}

Uint8List _grayscale(_Raster src) {
  final output = Uint8List(src.length);
  for (var i = 0; i < src.length; i++) {
    // 77/150/29 ≈ BT.601 亮度权重，整数运算避免每像素浮点开销。
    output[i] = (src.r[i] * 77 + src.g[i] * 150 + src.b[i] * 29) >> 8;
  }
  return output;
}

/// 亮度高频（局部明暗差）+ 索伯梯度，得到线稿强度。
({Uint8List gray, Uint8List edge}) _edgeMaps(_Raster src, int edgeWidth) {
  final gray = _grayscale(src);
  final width = src.width;
  final height = src.height;
  final radius = edgeWidth <= 128
      ? 1
      : edgeWidth <= 320
      ? 2
      : 3;
  final blurred = _boxBlur(gray, width, height, radius);
  var edge = Uint8List(src.length);
  for (var y = 0; y < height; y++) {
    final up = y > 0 ? y - 1 : y;
    final down = y < height - 1 ? y + 1 : y;
    for (var x = 0; x < width; x++) {
      final i = src.index(x, y);
      final left = gray[src.index(x > 0 ? x - 1 : x, y)];
      final right = gray[src.index(x < width - 1 ? x + 1 : x, y)];
      final top = gray[src.index(x, up)];
      final bottom = gray[src.index(x, down)];
      final highPass = (gray[i] - blurred[i]).abs() / 255;
      final gx = (right - left) / 255;
      final gy = (bottom - top) / 255;
      final gradient = math.sqrt(gx * gx + gy * gy);
      var value = highPass * 2.9 + gradient * 1.6;
      if (edgeWidth <= 128) value *= 1.15;
      edge[i] = (value.clamp(0.0, 1.0) * 255).round();
    }
  }
  // 小缩略图（64/128 桶）的线宽在物理像素上只有 1px，必须膨胀一次才看得见。
  if (edgeWidth <= 128) edge = _dilate(edge, width, height);
  return (gray: gray, edge: edge);
}

Uint8List _dilate(Uint8List src, int width, int height) {
  final output = Uint8List(src.length);
  for (var y = 0; y < height; y++) {
    final up = y > 0 ? y - 1 : y;
    final down = y < height - 1 ? y + 1 : y;
    for (var x = 0; x < width; x++) {
      final left = x > 0 ? x - 1 : x;
      final right = x < width - 1 ? x + 1 : x;
      var value = src[y * width + x];
      value = math.max(value, src[up * width + left]);
      value = math.max(value, src[up * width + x]);
      value = math.max(value, src[up * width + right]);
      value = math.max(value, src[y * width + left]);
      value = math.max(value, src[y * width + right]);
      value = math.max(value, src[down * width + left]);
      value = math.max(value, src[down * width + x]);
      value = math.max(value, src[down * width + right]);
      output[y * width + x] = value;
    }
  }
  return output;
}

/// 可分离盒式模糊（两次一维滑动窗口，O(n)）。半径越大线稿越粗、细节越少。
Uint8List _boxBlur(Uint8List src, int width, int height, int radius) {
  if (radius <= 0 || width <= 0 || height <= 0) return src;
  final window = radius * 2 + 1;
  final horizontal = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    var sum = 0;
    for (var k = -radius; k <= radius; k++) {
      sum += src[row + k.clamp(0, width - 1)];
    }
    for (var x = 0; x < width; x++) {
      horizontal[row + x] = sum ~/ window;
      final remove = row + (x - radius).clamp(0, width - 1);
      final add = row + (x + radius + 1).clamp(0, width - 1);
      sum += src[add] - src[remove];
    }
  }
  final output = Uint8List(width * height);
  for (var x = 0; x < width; x++) {
    var sum = 0;
    for (var k = -radius; k <= radius; k++) {
      sum += horizontal[k.clamp(0, height - 1) * width + x];
    }
    for (var y = 0; y < height; y++) {
      output[y * width + x] = sum ~/ window;
      final remove = (y - radius).clamp(0, height - 1) * width + x;
      final add = (y + radius + 1).clamp(0, height - 1) * width + x;
      sum += horizontal[add] - horizontal[remove];
    }
  }
  return output;
}

int _mixChannel(num from, num to, double amount) =>
    (from + (to - from) * amount).clamp(0, 255).toInt();

double _smoothStep(double low, double high, double value) {
  if (high <= low) return value >= high ? 1 : 0;
  final t = ((value - low) / (high - low)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// 确定性哈希噪声（0..1）：同一张图重复处理结果一致，测试可断言纹理。
double _noise(int x, int y, int seed) {
  var value = x * 0x1f1f1f1f ^ y * 0x27d4eb2d ^ seed * 0x165667b1;
  value = (value ^ (value >> 15)) * 0x85ebca6b;
  value = (value ^ (value >> 13)) * 0xc2b2ae35;
  value = value ^ (value >> 16);
  return (value & 0xFFFF) / 65535.0;
}

(int, int, int) _hsvToRgb(double hue, double saturation, double value) {
  final h = (hue % 360) / 60;
  final c = value * saturation;
  final x = c * (1 - ((h % 2) - 1).abs());
  final m = value - c;
  final (r, g, b) = switch (h.floor()) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  return (
    ((r + m) * 255).round(),
    ((g + m) * 255).round(),
    ((b + m) * 255).round(),
  );
}
