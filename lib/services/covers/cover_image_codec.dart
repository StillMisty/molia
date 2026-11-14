/// 自定义封面图片的归一化（解码 → 摆正方向 → 缩放 → JPEG）。
///
/// 选图来源不可控（相册原图可能带 EXIF 方向、边长数千像素、格式各异）：
/// 在写入本地存储前统一成「最长边 ≤ [maxEdge] 的 JPEG」，让 Flutter 图片
/// 缓存 / 取色 LRU 拿到的是可预期的有界图，而不是按原图尺寸解码。
///
/// GIF / WebP 例外：动图一旦解码再编码就会丢掉后续帧，因此这两种格式
/// 原样保留（只做体积上限检查），让 Flutter 的 `Image` 直接播放动画。
/// 同步接受 JPEG / GIF / WebP 并携带实际 MIME（见
/// `CustomCoverStore.canSyncImageBytes`），各端落地后显示一致。
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

  /// 动图原样保留的字节上限。动图不能缩放 / 重编码，只能限制落盘体积；
  /// 超过上限拒绝，避免把几十 MB 的 GIF 写进封面目录。
  ///
  /// 必须与同步上限保持一致：能落盘的动图也必须能进同步记录，否则会出现
  /// 「本机看得到、其它端没有」的不一致。上限同时受增量日志 4MB 窗口约束
  /// （base64 后约 2.7MB，留出键与记录开销）。
  static const int maxAnimatedBytes = 2 * 1024 * 1024;

  /// 是否为需要原样保留的动图容器格式（GIF / WebP）。
  static bool isAnimationCapableFormat(Uint8List bytes) =>
      _isGif(bytes) || _isWebp(bytes);

  /// 图片字节的 MIME；未知 / 损坏返回 null。
  static String? mimeOf(Uint8List bytes) {
    if (_isGif(bytes)) return 'image/gif';
    if (_isWebp(bytes)) return 'image/webp';
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    return null;
  }

  /// 落盘文件扩展名（必须与实际字节一致：Flutter 靠内容解码，
  /// 但封面查看器「保存原图」与外部打开会按扩展名处理）。
  static String extensionOf(Uint8List bytes) {
    if (_isGif(bytes)) return '.gif';
    if (_isWebp(bytes)) return '.webp';
    return '.jpg';
  }

  static bool _isGif(Uint8List bytes) {
    if (bytes.length < 6) return false;
    final header = String.fromCharCodes(bytes, 0, 6);
    return header == 'GIF87a' || header == 'GIF89a';
  }

  static bool _isWebp(Uint8List bytes) {
    if (bytes.length < 12) return false;
    return String.fromCharCodes(bytes, 0, 4) == 'RIFF' &&
        String.fromCharCodes(bytes, 8, 12) == 'WEBP';
  }

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
    // 动图：只检查体积，不碰帧数据。静态 GIF / WebP 也走这条，
    // 保持「容器格式原样落盘」的简单规则。
    if (isAnimationCapableFormat(bytes)) {
      if (bytes.length > maxAnimatedBytes) {
        throw const CoverImageException('animated image too large');
      }
      return bytes;
    }
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
