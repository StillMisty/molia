/// 自定义封面图片的归一化（解码 → 摆正方向 → 缩放 → WebP）。
///
/// 选图来源不可控（相册原图可能带 EXIF 方向、边长数千像素、格式各异，
/// 也可能是 GIF / 动画 WebP）：在写入本地存储前统一成「最长边 ≤ 1024px 的
/// 静态 WebP」或「最长边 ≤ 512px 的动画 WebP」，让 Flutter 图片缓存 / 取色
/// LRU 拿到的是可预期的有界图，而不是按原图尺寸解码。
///
/// 为什么是 WebP 而不是 AVIF：
/// - Flutter 官方保证解码 JPEG / PNG / GIF / Animated GIF / WebP /
///   Animated WebP；AVIF 只走平台解码器，桌面与旧系统并不一致，动图 AVIF
///   更不可靠；
/// - `package:image` 能纯 Dart 编码动画 WebP，不需要引入原生编解码依赖；
/// - WebP 同时覆盖静态、透明与动画，同步记录可以固定一个 MIME（`image/webp`），
///   另一台设备拿到的是**同一份字节**，不会因平台重新编码而变样。
///
/// 归一化只发生在选图 / 导入时一次；同步落盘不再重编码。这样封面内容哈希、
/// 取色 seed 与显示结果在设备间保持一致。
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'cover_image_format.dart';

/// 无法解码 / 编码图片（UI 只显示「无法读取这张图片」，不暴露异常文本）。
class CoverImageException implements Exception {
  const CoverImageException(this.message);

  final String message;

  @override
  String toString() => 'CoverImageException: $message';
}

/// 归一化产物：字节 + 由字节识别出的格式元数据。
class NormalizedCoverImage {
  const NormalizedCoverImage({required this.bytes, required this.info});

  final Uint8List bytes;
  final CoverImageInfo info;

  String get mimeType => info.mimeType;
  String get extension => info.extension;
  bool get animated => info.animated;
  int? get width => info.width;
  int? get height => info.height;
}

/// 自定义封面归一化参数（唯一口径）。
class CoverImageCodec {
  const CoverImageCodec._();

  /// 静态封面最长边：封面展示最大约 480dp，1024px 已足够 2x 屏。
  static const int maxEdge = 1024;

  /// 动图最长边：帧数多时像素预算增长很快；512px 在播放页 / 歌词海报
  /// 的展示尺寸下仍足够，也把编码与同步体积压在可控范围。
  static const int maxAnimatedEdge = 512;

  /// 静态 WebP 质量：与 JPEG 85 观感接近，体积通常更小。
  static const int webpQuality = 85;

  /// 动图 WebP 质量：帧间内容变化大，75 在体积与观感之间更稳。
  static const int animatedWebpQuality = 75;

  /// 最多保留的动画帧数。超过时按时间均匀抽帧并把被抽掉帧的时长合并到
  /// 保留帧，循环总时长不变（不是简单截断前 N 帧）。
  static const int maxAnimationFrames = 90;

  /// 解码像素预算（所有帧合计）：防止小体积恶意 GIF 声明超大画布。
  static const int maxDecodePixels = 32 * 1024 * 1024;

  /// 压缩重试的最低参数（仍超过同步上限时抛 [CoverImageException]）。
  static const int _minQuality = 55;
  static const int _minAnimatedEdge = 256;
  static const int _minAnimationFrames = 24;

  /// 归一化图片（CPU 密集，放到独立 isolate）。
  ///
  /// 失败抛 [CoverImageException]（调用方映射成友好文案）。
  static Future<Uint8List> normalize(Uint8List bytes) =>
      normalizeImage(bytes).then((result) => result.bytes);

  /// 归一化并返回格式元数据（测试 / 诊断使用；生产写入只需要字节）。
  static Future<NormalizedCoverImage> normalizeImage(Uint8List bytes) {
    if (bytes.isEmpty) {
      return Future.error(const CoverImageException('empty image'));
    }
    return Isolate.run(() => normalizeSync(bytes));
  }

  /// 同步实现（测试 / 已在小 isolate 内时使用）。
  static NormalizedCoverImage normalizeSync(Uint8List bytes) {
    final decoded = _decode(bytes);
    final oriented = image.bakeOrientation(decoded);
    final animated = oriented.numFrames > 1;
    final capped = animated ? _capAnimationFrames(oriented) : oriented;
    var prepared = _resize(capped, animated ? maxAnimatedEdge : maxEdge);

    var quality = animated ? animatedWebpQuality : webpQuality;
    var edge = animated ? maxAnimatedEdge : maxEdge;
    var frameLimit = animated ? maxAnimationFrames : 1;
    var attempts = 0;
    while (true) {
      attempts++;
      final encoded = image.encodeWebP(
        prepared,
        lossless: false,
        quality: quality,
        method: animated ? 3 : 4,
        exact: false,
        alphaQuality: 100,
      );
      if (encoded.isEmpty) {
        throw const CoverImageException('failed to encode image');
      }
      final info = CoverImageFormats.detect(encoded);
      if (info == null || info.format != CoverImageFormat.webp) {
        throw const CoverImageException('failed to encode webp');
      }
      if (animated && !info.animated) {
        throw const CoverImageException('animation lost while encoding');
      }
      if (encoded.length <= _maxBytes || attempts >= 12) {
        if (encoded.length > _maxBytes) {
          throw const CoverImageException('image exceeds sync budget');
        }
        return NormalizedCoverImage(bytes: encoded, info: info);
      }
      // 逐级降参数：先质量、再边长、最后动图帧数。每次重编码都从当前
      // prepared 图继续，不重新解码原图。
      if (quality > _minQuality) {
        quality = _clampInt(quality - 10, _minQuality, quality);
        continue;
      }
      if (edge > _minEdgeFor(animated)) {
        edge = _clampInt(edge * 3 ~/ 4, _minEdgeFor(animated), edge);
        prepared = _resize(prepared, edge);
        continue;
      }
      if (animated && prepared.numFrames > _minAnimationFrames) {
        frameLimit = _clampInt(
          prepared.numFrames * 2 ~/ 3,
          _minAnimationFrames,
          prepared.numFrames - 1,
        );
        prepared = _capAnimationFrames(prepared, maxFrames: frameLimit);
        continue;
      }
      throw const CoverImageException('image exceeds sync budget');
    }
  }

  /// 同步预算与存储层共用同一常量，避免两处上限漂移。
  static int get _maxBytes => kCoverSyncMaxBytes;

  static int _minEdgeFor(bool animated) => animated ? _minAnimatedEdge : 256;

  static int _clampInt(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);

  static image.Image _decode(Uint8List bytes) {
    final info = CoverImageFormats.detect(bytes);
    final image.Image? decoded = switch (info?.format) {
      // PNG / JPEG 的 maxPixels 是构造参数（final），必须按格式重建解码器；
      // GIF / WebP 是可变字段，可以设完再解码。
      CoverImageFormat.png => image.PngDecoder(
        maxPixels: maxDecodePixels,
      ).decode(bytes),
      CoverImageFormat.jpeg => image.JpegDecoder(
        maxPixels: maxDecodePixels,
      ).decode(bytes),
      CoverImageFormat.gif =>
        (image.GifDecoder()..maxPixels = maxDecodePixels).decode(bytes),
      CoverImageFormat.webp =>
        (image.WebPDecoder()..maxPixels = maxDecodePixels).decode(bytes),
      _ => null,
    };
    if (decoded == null) {
      throw const CoverImageException('unsupported or corrupted image');
    }
    return decoded;
  }

  /// 按时间均匀抽帧，保留循环总时长与首尾帧。
  ///
  /// 每个保留帧的时长 = 从该帧到下一保留帧之前所有原帧时长之和；原帧时长
  /// 为 0（常见 GIF）按 100ms 计，避免生成 0 时长导致解码器不受控地抢帧。
  static image.Image _capAnimationFrames(
    image.Image source, {
    int maxFrames = maxAnimationFrames,
  }) {
    final frames = source.frames;
    if (frames.length <= maxFrames) return source;
    final selected = <int>[];
    for (var i = 0; i < maxFrames; i++) {
      final index = (i * (frames.length - 1) / (maxFrames - 1)).round();
      if (selected.isEmpty || selected.last != index) selected.add(index);
    }
    int durationBetween(int from, int toExclusive) {
      var total = 0;
      for (var i = from; i < toExclusive && i < frames.length; i++) {
        total += _frameDurationMs(frames[i]);
      }
      return total;
    }

    final first = _cloneFrame(frames[selected.first]);
    first.frameDuration = durationBetween(
      selected.first,
      selected.length > 1 ? selected[1] : frames.length,
    );
    final out =
        image.Image.fromResized(
            first,
            width: first.width,
            height: first.height,
            noAnimation: true,
          )
          ..loopCount = source.loopCount
          ..backgroundColor = source.backgroundColor
          ..frameDuration = first.frameDuration;
    for (var i = 1; i < selected.length; i++) {
      final frame = _cloneFrame(frames[selected[i]]);
      frame.frameDuration = durationBetween(
        selected[i],
        i + 1 < selected.length ? selected[i + 1] : frames.length,
      );
      out.addFrame(frame);
    }
    return out;
  }

  static image.Image _cloneFrame(image.Image frame) => image.Image.fromResized(
    frame,
    width: frame.width,
    height: frame.height,
    noAnimation: true,
  )..frameDuration = frame.frameDuration;

  static int _frameDurationMs(image.Image frame) =>
      frame.frameDuration > 0 ? frame.frameDuration : 100;

  static image.Image _resize(image.Image source, int maxEdge) {
    final longest = source.width > source.height ? source.width : source.height;
    if (longest <= maxEdge) return source;
    return image.copyResize(
      source,
      width: source.width >= source.height ? maxEdge : null,
      height: source.height > source.width ? maxEdge : null,
      interpolation: image.Interpolation.linear,
    );
  }
}
