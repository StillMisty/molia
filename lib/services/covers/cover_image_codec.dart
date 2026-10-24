/// 自定义封面图片的归一化（解码 → 摆正方向 → 缩放 → JPEG）。
///
/// 选图来源不可控（相册原图可能带 EXIF 方向、边长数千像素、格式各异）：
/// 在写入本地存储前统一成「最长边 ≤ [maxEdge] 的 JPEG」，让 Flutter 图片
/// 缓存 / 取色 LRU 拿到的是可预期的有界图，而不是按原图尺寸解码。
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// 无法解码 / 编码图片（UI 只显示「无法读取这张图片」，不暴露异常文本）。
class CoverImageException implements Exception {
  const CoverImageException(this.message);

  final String message;

  @override
  String toString() => 'CoverImageException: $message';
}

/// 自定义封面归一化参数（唯一口径）。
class CoverImageCodec {
  const CoverImageCodec._();

  /// 最长边上限：封面展示最大约 480dp，1024px 已足够 2x 屏。
  static const int maxEdge = 1024;

  /// JPEG 质量：85 在封面观感与文件大小之间折中。
  static const int jpegQuality = 85;

  /// 归一化图片（CPU 密集，放到独立 isolate）。
  ///
  /// 失败抛 [CoverImageException]（调用方映射成友好文案）。
  static Future<Uint8List> normalize(Uint8List bytes) {
    if (bytes.isEmpty) {
      return Future.error(const CoverImageException('empty image'));
    }
    return Isolate.run(() => normalizeSync(bytes));
  }

  /// 同步实现（测试 / 已在小 isolate 内时使用）。
  static Uint8List normalizeSync(Uint8List bytes) {
    final decoded = image.decodeImage(bytes);
    if (decoded == null) {
      throw const CoverImageException('unsupported or corrupted image');
    }
    final oriented = image.bakeOrientation(decoded);
    final longest = oriented.width > oriented.height
        ? oriented.width
        : oriented.height;
    final resized = longest <= maxEdge
        ? oriented
        : image.copyResize(
            oriented,
            width: oriented.width >= oriented.height ? maxEdge : null,
            height: oriented.height > oriented.width ? maxEdge : null,
            interpolation: image.Interpolation.linear,
          );
    final encoded = image.encodeJpg(resized, quality: jpegQuality);
    if (encoded.isEmpty) {
      throw const CoverImageException('failed to encode image');
    }
    return encoded;
  }
}
