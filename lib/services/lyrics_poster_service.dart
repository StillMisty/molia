import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:logging/logging.dart';
import 'package:dio/dio.dart';

import '../data/http/app_dio.dart';
import '../managers/artwork_cache.dart';
import '../domain/models/poster_lyric_line.dart';
import 'poster/poster_draw.dart'
    show
        posterCoverCropRect,
        posterDecodeImage,
        posterDrawCover,
        posterDrawWatermark,
        posterPaintTextPainter;

final logger = Logger('molia.lyrics_poster_service');

/// 海报图片下载用的共享客户端：惰性创建——`Dio` 的默认适配器会抓
/// `HttpOverrides.current`，在 flutter_test 的 test zone 之外构造会抛异常
/// （同 `AnyListenApi` 的说明）。
Dio? _sharedDio;
Dio get _dio => _sharedDio ??= createAppDio();

/// 海报成品宽度：与年度 / 听歌统计海报同档，方便分享平台统一裁切。
const int kLyricsPosterWidth = 1440;

/// 单张 PNG 的像素高度上限：超过常见 GPU 纹理上限后 `Picture.toImage`
/// 会直接失败。内容更高时按比例缩小歌词字号 / 行距，而不是裁掉歌词。
const int kLyricsPosterMaxHeight = 16384;

/// 海报封面在 1440 宽成品里只占 200px 见方：解码到 256px 足够清晰，
/// 又能避免把 1000+ px 的原图整张解码进内存。
const int _albumImageTargetWidth = 256;

/// 水印图标与 40px 水印文字同高，解码到 64px 已覆盖 2x 渲染。
const int _watermarkImageTargetWidth = 64;

/// 换色 / 换字体触发的重生成不应重新下载封面：缓存原始压缩字节即可，
/// 解码仍按 [_albumImageTargetWidth] 有界进行。自定义封面每次替换都会
/// 写新文件名，因此 URL 命中不会拿到旧图。
final LinkedHashMap<String, Uint8List> _coverBytesCache = LinkedHashMap();
const int _coverBytesCacheLimit = 4;
const int _maxCachedCoverBytes = 2 * 1024 * 1024;

/// 水印图标是固定 asset，读一次即可；渲染时仍解码出独立 `ui.Image` 由
/// 单次绘制负责释放。
Uint8List? _watermarkBytes;

/// 方形封面在源图中的居中裁切区域（`BoxFit.cover` 语义，不拉伸）。
///
/// 海报头图是固定正方形；直接把整张源图铺满会把 16:9 封面压扁。这里按
/// 目标宽高比取源图中心区域，方形源图仍完整使用，非方形只裁不缩。
@visibleForTesting
Rect coverCropSourceRect({
  required double sourceWidth,
  required double sourceHeight,
  required double targetWidth,
  required double targetHeight,
}) => posterCoverCropRect(
  sourceWidth: sourceWidth,
  sourceHeight: sourceHeight,
  targetWidth: targetWidth,
  targetHeight: targetHeight,
);

/// 一次歌词排版的结果：绘制阶段按 painter 顺序画，量高阶段用同一个 height。
class _LyricLayout {
  _LyricLayout({
    required this.painters,
    required this.gaps,
    required this.height,
  });

  final List<TextPainter> painters;
  final List<double> gaps;
  final double height;

  void dispose() {
    for (final painter in painters) {
      painter.dispose();
    }
  }
}

class LyricsPosterService {
  /// [dio] 仅供测试注入；默认复用进程内共享客户端。
  ///
  /// [networkTimeout] 是封面下载的整次请求截止时间：CDN 长时间无响应时
  /// 不再无限期占住海报生成流程。
  LyricsPosterService({
    Dio? dio,
    Duration networkTimeout = const Duration(seconds: 15),
  }) : _http = dio ?? _dio,
       // 参数名保持公开的 networkTimeout，字段名按约定私有，无法用
       // initializing formal（会变成私有的命名参数）。
       // ignore: prefer_initializing_formals
       _networkTimeout = networkTimeout;

  final Dio _http;
  final Duration _networkTimeout;

  /// 清空封面 / 水印缓存；测试之间避免命中上一条用例的图片。
  @visibleForTesting
  static void debugClearImageCaches() {
    _coverBytesCache.clear();
    _watermarkBytes = null;
  }

  /// 生成 PNG 字节（导出 / 保存路径）。
  ///
  /// 预览页应调用 [renderPosterImage] 直接拿 `ui.Image`，避免每次换样式都
  /// 编码 PNG；本方法只是渲染 + 编码的兼容包装。
  Future<Uint8List> generatePosterData({
    required String lyrics,
    List<PosterLyricLine>? posterLyricLines,
    required String trackTitle,
    required String artistName,
    String? albumCoverUrl,
    required Color backgroundColor,
    required Color titleColor,
    required Color artistColor,
    required Color lyricsColor,
    required Color extendedColor,
    required Color watermarkColor,
    required Color separatorColor,
    String? fontFamily,
    List<String>? fontFamilyFallback,

    /// 海报水印品牌名（Molia）。
    String watermarkText = 'Molia',
  }) async {
    final image = await renderPosterImage(
      lyrics: lyrics,
      posterLyricLines: posterLyricLines,
      trackTitle: trackTitle,
      artistName: artistName,
      albumCoverUrl: albumCoverUrl,
      backgroundColor: backgroundColor,
      titleColor: titleColor,
      artistColor: artistColor,
      lyricsColor: lyricsColor,
      extendedColor: extendedColor,
      watermarkColor: watermarkColor,
      separatorColor: separatorColor,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      watermarkText: watermarkText,
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// 渲染海报位图；返回的 `ui.Image` 由调用方负责 `dispose`。
  ///
  /// 一次 layout 同时用于量高与绘制（标题 / 歌手 / 歌词都只排一次），
  /// 所有 TextPainter 在 finally 释放，避免原生 paragraph 常驻。
  Future<ui.Image> renderPosterImage({
    required String lyrics,
    List<PosterLyricLine>? posterLyricLines,
    required String trackTitle,
    required String artistName,
    String? albumCoverUrl,
    required Color backgroundColor,
    required Color titleColor,
    required Color artistColor,
    required Color lyricsColor,
    required Color extendedColor,
    required Color watermarkColor,
    required Color separatorColor,
    String? fontFamily,
    List<String>? fontFamilyFallback,

    /// 海报水印品牌名（Molia）。
    String watermarkText = 'Molia',
  }) async {
    const double scaleFactor = 2.0;
    const double baseWidth = 720;
    const double width = baseWidth * scaleFactor;
    const double horizontalMargin = 32.0 * scaleFactor;
    const double contentWidth = width - 2 * horizontalMargin;

    const double titleFontSize = 28.0 * scaleFactor;
    // 歌手名比标题低一档，避免两行同字号看起来像同一层级。
    const double artistFontSize = 20.0 * scaleFactor;
    const double lyricsFontSize = 40.0 * scaleFactor;
    const double watermarkFontSize = 20.0 * scaleFactor;

    const double topMargin = 40.0 * scaleFactor;
    const double bottomMargin = 40.0 * scaleFactor;
    const double elementSpacing = 24.0 * scaleFactor;
    const double interTextSpacing = 8.0 * scaleFactor;
    const double albumArtSize = 100.0 * scaleFactor;
    const double albumCornerRadius = 8.0 * scaleFactor;
    const double headerSpacing = 20.0 * scaleFactor;
    const double separatorThickness = 1.0 * scaleFactor;

    final titleStyle = TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: titleFontSize,
      color: titleColor,
      fontWeight: FontWeight.w700,
    );
    final artistStyle = TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: artistFontSize,
      color: artistColor,
      fontWeight: FontWeight.w500,
    );
    final watermarkStyle = TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: watermarkFontSize,
      color: watermarkColor,
      fontWeight: FontWeight.w400,
    );

    final List<PosterLyricLine> lyricEntries =
        (posterLyricLines != null && posterLyricLines.isNotEmpty)
        ? posterLyricLines
        : lyrics
              .split('\n')
              .map((line) => PosterLyricLine(text: line))
              .toList();

    final bool hasNonEmptyLyric = lyricEntries.any(
      (entry) => entry.text.trim().isNotEmpty,
    );

    ui.Image? loadedAlbumImage;
    ui.Image? watermarkIcon;
    final List<TextPainter> fixedPainters = [];
    _LyricLayout? lyricLayout;

    try {
      // 封面下载是整条管线最慢的一步；水印图标同时开始读，别串行等。
      final coverFuture = _tryLoadCover(albumCoverUrl);
      final watermarkFuture = _tryLoadWatermarkIcon();
      loadedAlbumImage = await coverFuture;
      watermarkIcon = await watermarkFuture;

      final bool hasCover = loadedAlbumImage != null;
      final double headerTextWidth = hasCover
          ? contentWidth - albumArtSize - headerSpacing
          : contentWidth;

      // maxLines 固定后超长标题 / 歌手不会把海报头部撑成半页。
      final titlePainter = _layoutText(
        trackTitle,
        titleStyle,
        headerTextWidth,
        maxLines: 2,
      );
      final artistPainter = _layoutText(
        artistName,
        artistStyle,
        headerTextWidth,
        maxLines: 1,
      );
      fixedPainters.addAll([titlePainter, artistPainter]);

      final bool hasArtist = artistName.trim().isNotEmpty;
      final double textTotalHeight =
          titlePainter.height +
          (hasArtist ? interTextSpacing + artistPainter.height : 0);
      final double headerHeight = hasCover
          ? math.max(albumArtSize, textTotalHeight)
          : textTotalHeight;

      final watermarkPainter = _layoutText(
        watermarkText,
        watermarkStyle,
        contentWidth,
      );
      fixedPainters.add(watermarkPainter);
      final double watermarkHeight = watermarkPainter.height;

      _LyricLayout layoutLyrics(double mainFontSize) {
        final spacingScale = mainFontSize / lyricsFontSize;
        final lyricsStyle = TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          fontSize: mainFontSize,
          color: lyricsColor,
          height: 1.35,
          fontWeight: FontWeight.w700,
        );
        // 扩展行（翻译 / 罗马音）：与歌词页同层级（主行下、次级文本）。
        final extendedLyricsStyle = TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          fontSize: mainFontSize * 0.7,
          color: extendedColor,
          height: 1.3,
          fontWeight: FontWeight.w500,
        );
        final extendedSpacing = 4.0 * scaleFactor * spacingScale;
        final extendedLineSpacing = 2.0 * scaleFactor * spacingScale;

        final painters = <TextPainter>[];
        final gaps = <double>[];
        double height = 0;

        if (lyricEntries.isNotEmpty && hasNonEmptyLyric) {
          for (final entry in lyricEntries) {
            painters.add(
              _layoutText(
                entry.text.isEmpty ? ' ' : entry.text,
                lyricsStyle,
                contentWidth,
              ),
            );
            final extendedTexts = <String>[
              if (entry.translation.trim().isNotEmpty) entry.translation,
              if (entry.roma.trim().isNotEmpty) entry.roma,
            ];
            gaps.add(extendedTexts.isEmpty ? 0.0 : extendedSpacing);
            for (var i = 0; i < extendedTexts.length; i++) {
              painters.add(
                _layoutText(
                  extendedTexts[i],
                  extendedLyricsStyle,
                  contentWidth,
                ),
              );
              gaps.add(
                i == extendedTexts.length - 1 ? 0.0 : extendedLineSpacing,
              );
            }
          }
        } else {
          painters.add(_layoutText(' ', lyricsStyle, contentWidth));
          gaps.add(0);
        }

        for (var i = 0; i < painters.length; i++) {
          height += painters[i].height + gaps[i];
        }
        return _LyricLayout(painters: painters, gaps: gaps, height: height);
      }

      // 固定区块（头图 + 水印 + 边距）先占位，剩余高度交给歌词。
      final double fixedHeight =
          topMargin +
          headerHeight +
          elementSpacing +
          elementSpacing +
          watermarkHeight +
          bottomMargin;

      var currentLyricsFontSize = lyricsFontSize;
      var activeLyricLayout = layoutLyrics(currentLyricsFontSize);
      lyricLayout = activeLyricLayout;
      var totalHeight = fixedHeight + activeLyricLayout.height;
      var attempts = 0;
      while (totalHeight > kLyricsPosterMaxHeight &&
          currentLyricsFontSize > 1 &&
          attempts++ < 20) {
        final available = kLyricsPosterMaxHeight - fixedHeight;
        final ratio = available <= 0
            ? 0.5
            : (available / activeLyricLayout.height).clamp(0.1, 0.95);
        currentLyricsFontSize = (currentLyricsFontSize * ratio)
            .clamp(1.0, currentLyricsFontSize)
            .toDouble();
        activeLyricLayout.dispose();
        activeLyricLayout = layoutLyrics(currentLyricsFontSize);
        lyricLayout = activeLyricLayout;
        totalHeight = fixedHeight + activeLyricLayout.height;
      }

      final double finalPosterHeight = math.max(totalHeight, 400.0);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, width, finalPosterHeight),
      );

      canvas.drawRect(
        Rect.fromLTWH(0, 0, width, finalPosterHeight),
        Paint()..color = backgroundColor,
      );

      double currentY = topMargin;

      final double textStartX = hasCover
          ? horizontalMargin + albumArtSize + headerSpacing
          : horizontalMargin;
      final double textStartY = hasCover
          ? currentY + (albumArtSize - textTotalHeight) / 2
          : currentY;

      if (hasCover) {
        posterDrawCover(
          canvas,
          loadedAlbumImage,
          Rect.fromLTWH(horizontalMargin, currentY, albumArtSize, albumArtSize),
          cornerRadius: albumCornerRadius,
        );
      }

      titlePainter.paint(canvas, Offset(textStartX, textStartY));
      if (hasArtist) {
        artistPainter.paint(
          canvas,
          Offset(
            textStartX,
            textStartY + titlePainter.height + interTextSpacing,
          ),
        );
      }

      currentY += headerHeight + elementSpacing;
      _drawSeparator(
        canvas,
        horizontalMargin,
        contentWidth,
        currentY - elementSpacing / 2,
        separatorThickness,
        separatorColor,
      );

      for (var i = 0; i < activeLyricLayout.painters.length; i++) {
        final painter = activeLyricLayout.painters[i];
        posterPaintTextPainter(
          canvas,
          painter,
          Offset(horizontalMargin, currentY + painter.height / 2),
          TextAlign.left,
        );
        currentY += painter.height + activeLyricLayout.gaps[i];
      }

      currentY += elementSpacing;
      _drawSeparator(
        canvas,
        horizontalMargin,
        contentWidth,
        currentY - elementSpacing / 2,
        separatorThickness,
        separatorColor,
      );

      final watermarkY = currentY + watermarkHeight / 2;
      posterDrawWatermark(
        canvas,
        icon: watermarkIcon,
        painter: watermarkPainter,
        leftX: horizontalMargin,
        centerY: watermarkY,
        color: watermarkColor,
        iconTextSpacing: 8.0 * scaleFactor,
      );

      final picture = recorder.endRecording();
      try {
        return await picture.toImage(
          kLyricsPosterWidth,
          finalPosterHeight.toInt(),
        );
      } finally {
        picture.dispose();
      }
    } finally {
      for (final painter in fixedPainters) {
        painter.dispose();
      }
      lyricLayout?.dispose();
      loadedAlbumImage?.dispose();
      watermarkIcon?.dispose();
    }
  }

  Future<void> sharePosterFile(String imagePath, String textToShare) async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(imagePath)], text: textToShare),
      );
      logger.fine('Poster shared successfully from file: $imagePath');
    } catch (e) {
      logger.severe('Error sharing poster from file: $e');
      rethrow;
    }
  }

  /// 绘制一条与 `elementSpacing` 居中的弱分隔线。
  void _drawSeparator(
    Canvas canvas,
    double left,
    double width,
    double centerY,
    double thickness,
    Color color,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(left, centerY - thickness / 2, width, thickness),
      Paint()..color = color,
    );
  }

  TextPainter _layoutText(
    String text,
    TextStyle style,
    double maxWidth, {
    int? maxLines,
  }) {
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    )..layout(maxWidth: maxWidth);
  }

  Future<ui.Image?> _tryLoadCover(String? url) async {
    if (url == null || url.isEmpty) return null;
    try {
      return await _loadNetworkImage(url);
    } catch (e) {
      logger.warning('Failed to load album cover for poster: $e');
      return null;
    }
  }

  Future<ui.Image?> _tryLoadWatermarkIcon() async {
    try {
      return await _loadAssetImage('assets/icons/adaptive_icon_monochrome.png');
    } catch (e) {
      logger.warning('Failed to load watermark icon: $e');
      return null;
    }
  }

  // 加载网络图片（统一浏览器 UA + 平台 Referer，修 CDN 403）
  Future<ui.Image> _loadNetworkImage(String url) async {
    final bytes = await _loadImageBytes(url);
    return posterDecodeImage(bytes, targetWidth: _albumImageTargetWidth);
  }

  /// 读封面字节：本地文件直接读盘，网络走共享客户端；命中缓存不再下载。
  Future<Uint8List> _loadImageBytes(String url) async {
    final cached = _coverBytesCache.remove(url);
    if (cached != null) {
      // 重新插入到末尾，维持「最近使用」顺序。
      _coverBytesCache[url] = cached;
      return cached;
    }

    Uint8List bytes;
    final localFile = _localFileFor(url);
    if (localFile != null) {
      bytes = await localFile.readAsBytes();
    } else {
      final response = await _http
          .getUri(
            Uri.parse(url),
            options: Options(headers: ArtworkCache.headersFor(url)),
          )
          .timeout(_networkTimeout);
      if (response.statusCode != 200) {
        throw Exception('Failed to load image from $url');
      }
      bytes = bodyBytes(response);
    }

    if (bytes.isNotEmpty && bytes.length <= _maxCachedCoverBytes) {
      _coverBytesCache[url] = bytes;
      while (_coverBytesCache.length > _coverBytesCacheLimit) {
        _coverBytesCache.remove(_coverBytesCache.keys.first);
      }
    }
    return bytes;
  }

  /// 本地封面 URL → 文件；非本地地址返回 null。
  File? _localFileFor(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'file') return File.fromUri(uri);
    if (uri == null || uri.scheme.isEmpty) {
      final file = File(url);
      return file;
    }
    return null;
  }

  Future<ui.Image> _loadAssetImage(String assetPath) async {
    final bytes = _watermarkBytes ??= await _readAssetBytes(assetPath);
    return posterDecodeImage(bytes, targetWidth: _watermarkImageTargetWidth);
  }

  Future<Uint8List> _readAssetBytes(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
