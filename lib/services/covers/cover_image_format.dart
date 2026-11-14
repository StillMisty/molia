/// 封面图片格式识别：字节是唯一事实源。
///
/// 本地文件、同步记录与下载边车都可能带错扩展名 / MIME（历史 JPEG、
/// 第三方改名的 WebP、远端异常载荷）。写入与同步一律按魔数识别，避免
/// 「声明是 JPEG、实际是 WebP」导致另一台设备按错误扩展名落盘或拒绝。
///
/// 只接受 Flutter 各平台都能稳定解码的格式（JPEG / PNG / GIF / WebP）；
/// AVIF 不在内：Flutter 只把无法识别的格式交给平台解码器，桌面与旧系统
/// 不一定支持，动图 AVIF 更不稳定。封面归一化统一产出 WebP（见
/// `cover_image_codec.dart`），这里保留其他格式是为了读取既有本地文件与
/// 旧同步记录，不把用户已选的封面弄丢。
library;

import 'dart:typed_data';

/// 单张封面可进入同步记录的字节上限。
///
/// 动图 WebP 比静态封面大，但归一化会按这个预算逐级降质量 / 边长 / 帧数；
/// 超过预算的正常动图不会被静默截成一张静态图。base64 后约 2MB，仍低于
/// 增量日志 8MB 的窗口上限。
const int kCoverSyncMaxBytes = 1536 * 1024;

/// 封面文件格式（MIME 与扩展名的唯一映射）。
enum CoverImageFormat {
  jpeg('image/jpeg', 'jpg'),
  png('image/png', 'png'),
  gif('image/gif', 'gif'),
  webp('image/webp', 'webp');

  const CoverImageFormat(this.mimeType, this.extension);

  final String mimeType;
  final String extension;

  /// 从扩展名（带或不带点）解析；未知返回 null。
  static CoverImageFormat? fromExtension(String? extension) {
    if (extension == null) return null;
    final value = extension.toLowerCase().replaceFirst('.', '');
    return switch (value) {
      'jpg' || 'jpeg' => jpeg,
      'png' => png,
      'gif' => gif,
      'webp' => webp,
      _ => null,
    };
  }
}

/// 一次格式识别的结果。
class CoverImageInfo {
  const CoverImageInfo({
    required this.format,
    required this.animated,
    this.width,
    this.height,
  });

  final CoverImageFormat format;

  /// 是否多帧动画（GIF / APNG / 动画 WebP）。
  final bool animated;

  /// 画布尺寸（能廉价解析出来时给出；用于诊断与记录元数据）。
  final int? width;
  final int? height;

  String get mimeType => format.mimeType;
  String get extension => format.extension;
}

/// 按魔数识别图片格式；未知 / AVIF / 损坏字节返回 null。
abstract final class CoverImageFormats {
  /// 识别字节格式（不依赖文件扩展名，不完整解码）。
  static CoverImageInfo? detect(Uint8List bytes) {
    if (bytes.length < 12) {
      // 有些格式（JPEG / GIF）允许更短的表头；下面各自再判断。
      if (_isJpeg(bytes)) {
        return const CoverImageInfo(
          format: CoverImageFormat.jpeg,
          animated: false,
        );
      }
      return null;
    }
    if (_isJpeg(bytes)) {
      return CoverImageInfo(
        format: CoverImageFormat.jpeg,
        animated: false,
        width: _jpegWidth(bytes),
        height: _jpegHeight(bytes),
      );
    }
    if (_isPng(bytes)) return _pngInfo(bytes);
    if (_isGif(bytes)) return _gifInfo(bytes);
    if (_isWebp(bytes)) return _webpInfo(bytes);
    return null;
  }

  /// 是否在同步记录允许的大小内且格式受支持。
  ///
  /// 大小上限由调用方（`CustomCoverStore.maxSyncBytes`）定义；这里只做
  /// 格式判定，便于本地读取路径复用同一识别逻辑。
  static CoverImageInfo? detectSyncable(
    Uint8List bytes, {
    required int maxBytes,
  }) {
    if (bytes.isEmpty || bytes.length > maxBytes) return null;
    return detect(bytes);
  }

  static bool _isJpeg(Uint8List b) =>
      b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

  static bool _isPng(Uint8List b) =>
      b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A;

  static bool _isGif(Uint8List b) =>
      b.length >= 6 &&
      b[0] == 0x47 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x38 &&
      (b[4] == 0x37 || b[4] == 0x39) &&
      b[5] == 0x61;

  static bool _isWebp(Uint8List b) =>
      b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50;

  static CoverImageInfo _pngInfo(Uint8List b) {
    int? width;
    int? height;
    if (b.length >= 24) {
      width = _be32(b, 16);
      height = _be32(b, 20);
    }
    // APNG 的 acTL 块（出现在 IDAT 之前）。只做字节探测，避免完整解码。
    var animated = false;
    for (var i = 8; i + 4 <= b.length; i++) {
      if (b[i] == 0x61 &&
          b[i + 1] == 0x63 &&
          b[i + 2] == 0x54 &&
          b[i + 3] == 0x4C) {
        animated = true;
        break;
      }
    }
    return CoverImageInfo(
      format: CoverImageFormat.png,
      animated: animated,
      width: width,
      height: height,
    );
  }

  static CoverImageInfo _gifInfo(Uint8List b) {
    final width = b.length >= 8 ? b[6] | (b[7] << 8) : null;
    final height = b.length >= 10 ? b[8] | (b[9] << 8) : null;
    // Graphis Control Extension（21 F9 04）通常一帧一个；两次出现视为动画。
    // 只用于记录元数据，不影响解码 / 落盘。
    var controls = 0;
    for (var i = 0; i + 3 <= b.length; i++) {
      if (b[i] == 0x21 && b[i + 1] == 0xF9 && b[i + 2] == 0x04) {
        controls++;
        if (controls > 1) break;
      }
    }
    return CoverImageInfo(
      format: CoverImageFormat.gif,
      animated: controls > 1,
      width: width,
      height: height,
    );
  }

  static CoverImageInfo _webpInfo(Uint8List b) {
    var animated = false;
    int? width;
    int? height;
    var offset = 12;
    while (offset + 8 <= b.length) {
      final fourcc = _fourCc(b, offset);
      final size = _le32(b, offset + 4);
      final data = offset + 8;
      if (fourcc == 'VP8X' && data + 10 <= b.length) {
        final flags = b[data];
        animated = flags & 0x02 != 0;
        width = 1 + _le24(b, data + 4);
        height = 1 + _le24(b, data + 7);
      } else if (fourcc == 'ANIM' && data + 6 <= b.length) {
        animated = true;
      } else if (fourcc == 'VP8 ' && data + 10 <= b.length) {
        // lossy 帧头：3 字节 start code + 14 位宽 + 14 位高。
        width ??= _le16(b, data + 6) & 0x3FFF;
        height ??= _le16(b, data + 8) & 0x3FFF;
      } else if (fourcc == 'VP8L' && data + 5 <= b.length && b[data] == 0x2F) {
        // lossless 帧头：signature 后 4 字节交错存宽高。
        final b1 = b[data + 1];
        final b2 = b[data + 2];
        final b3 = b[data + 3];
        final b4 = b[data + 4];
        width ??= 1 + ((b1 | (b2 << 8)) & 0x3FFF);
        height ??= 1 + (((b2 >> 6) | (b3 << 2) | (b4 << 10)) & 0x3FFF);
      }
      if (size < 0) break;
      offset = data + size + (size & 1);
    }
    return CoverImageInfo(
      format: CoverImageFormat.webp,
      animated: animated,
      width: width,
      height: height,
    );
  }

  static String _fourCc(Uint8List b, int offset) => String.fromCharCodes([
    b[offset],
    b[offset + 1],
    b[offset + 2],
    b[offset + 3],
  ]);

  static int _le16(Uint8List b, int offset) => b[offset] | (b[offset + 1] << 8);

  static int _le24(Uint8List b, int offset) =>
      b[offset] | (b[offset + 1] << 8) | (b[offset + 2] << 16);

  static int _le32(Uint8List b, int offset) =>
      b[offset] |
      (b[offset + 1] << 8) |
      (b[offset + 2] << 16) |
      (b[offset + 3] << 24);

  static int _be32(Uint8List b, int offset) =>
      (b[offset] << 24) |
      (b[offset + 1] << 16) |
      (b[offset + 2] << 8) |
      b[offset + 3];

  static int? _jpegWidth(Uint8List b) => _jpegDimension(b, width: true);

  static int? _jpegHeight(Uint8List b) => _jpegDimension(b, width: false);

  /// 扫 JPEG 的 SOFn 段取尺寸；解析失败返回 null（只用于元数据）。
  static int? _jpegDimension(Uint8List b, {required bool width}) {
    var offset = 2;
    while (offset + 4 <= b.length) {
      if (b[offset] != 0xFF) return null;
      final marker = b[offset + 1];
      offset += 2;
      if (marker == 0xD8 || marker == 0xD9) continue;
      if (marker == 0xDA) return null; // SOS 之前没找到 SOF。
      if (offset + 2 > b.length) return null;
      final length = (b[offset] << 8) | b[offset + 1];
      if (length < 2 || offset + length > b.length) return null;
      final isSof =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (length < 7) return null;
        final height = (b[offset + 3] << 8) | b[offset + 4];
        final w = (b[offset + 5] << 8) | b[offset + 6];
        return width ? w : height;
      }
      offset += length;
    }
    return null;
  }
}
