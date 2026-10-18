import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:logging/logging.dart';
import 'package:dio/dio.dart';
import 'package:gal/gal.dart';
import '../data/http/app_dio.dart';
import '../managers/artwork_cache.dart';
import '../models/poster_lyric_line.dart';

final logger = Logger('molia.lyrics_poster_service');

/// 海报图片下载用的共享客户端：惰性创建——`Dio` 的默认适配器会抓
/// `HttpOverrides.current`，在 flutter_test 的 test zone 之外构造会抛异常
/// （同 `AnyListenApi` 的说明）。
Dio? _sharedDio;
Dio get _dio => _sharedDio ??= createAppDio();

class LyricsPosterService {
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
    /// 海报水印品牌名（Molia）。
    String watermarkText = 'Molia',
  }) async {
    const double scaleFactor = 2.0;
    const double baseWidth = 720;
    const double width = baseWidth * scaleFactor;
    const double horizontalMargin = 32.0 * scaleFactor;
    const double contentWidth = width - 2 * horizontalMargin;

    const double titleFontSize = 28.0 * scaleFactor;
    const double artistFontSize = 28.0 * scaleFactor;
    const double lyricsFontSize = 40 * scaleFactor;
    const double watermarkFontSize = 20.0 * scaleFactor;

    const double topMargin = 40.0 * scaleFactor;
    const double bottomMargin = 40.0 * scaleFactor;
    const double elementSpacing = 24.0 * scaleFactor;
    const double interTextSpacing = 8.0 * scaleFactor;
    const double albumArtSize = 100.0 * scaleFactor;
    const double albumCornerRadius = 8.0 * scaleFactor;
    const double headerSpacing = 20.0 * scaleFactor;

    double calculatedHeight = 0;
    calculatedHeight += topMargin;

    ui.Image? loadedAlbumImage;
    double headerHeight = 0;

    if (albumCoverUrl != null && albumCoverUrl.isNotEmpty) {
      try {
        loadedAlbumImage = await _loadNetworkImage(albumCoverUrl);
        final titleStyle = TextStyle(
            fontFamily: fontFamily,
            fontSize: titleFontSize,
            color: titleColor,
            fontWeight: FontWeight.w600);
        final titlePainter = TextPainter(
          text: TextSpan(text: trackTitle, style: titleStyle),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
        );
        final artistStyle = TextStyle(
            fontFamily: fontFamily,
            fontSize: artistFontSize,
            color: artistColor,
            fontWeight: FontWeight.w400);
        final artistPainter = TextPainter(
          text: TextSpan(text: artistName, style: artistStyle),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
        );

        final maxTextWidth = contentWidth - albumArtSize - headerSpacing;
        titlePainter.layout(maxWidth: maxTextWidth);
        artistPainter.layout(maxWidth: maxTextWidth);

        final textTotalHeight =
            titlePainter.height + interTextSpacing + artistPainter.height;
        headerHeight =
            albumArtSize > textTotalHeight ? albumArtSize : textTotalHeight;
        calculatedHeight += headerHeight + elementSpacing;
      } catch (e) {
        logger.warning('Failed to load album cover for height calculation: $e');
        final titleStyle = TextStyle(
            fontFamily: fontFamily,
            fontSize: titleFontSize,
            color: titleColor,
            fontWeight: FontWeight.w400);
        final titlePainter = TextPainter(
          text: TextSpan(text: trackTitle, style: titleStyle),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
        );
        titlePainter.layout(maxWidth: contentWidth);
        headerHeight += titlePainter.height + interTextSpacing;

        final artistStyle = TextStyle(
            fontFamily: fontFamily,
            fontSize: artistFontSize,
            color: artistColor,
            fontWeight: FontWeight.w400);
        final artistPainter = TextPainter(
          text: TextSpan(text: artistName, style: artistStyle),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
        );
        artistPainter.layout(maxWidth: contentWidth);
        headerHeight += artistPainter.height;
        calculatedHeight += headerHeight + elementSpacing;
      }
    } else {
      final titleStyle = TextStyle(
          fontFamily: fontFamily,
          fontSize: titleFontSize,
          color: titleColor,
          fontWeight: FontWeight.w600);
      final titlePainter = TextPainter(
        text: TextSpan(text: trackTitle, style: titleStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      );
      titlePainter.layout(maxWidth: contentWidth);
      headerHeight += titlePainter.height + interTextSpacing;

      final artistStyle = TextStyle(
          fontFamily: fontFamily,
          fontSize: artistFontSize,
          color: artistColor,
          fontWeight: FontWeight.w400);
      final artistPainter = TextPainter(
        text: TextSpan(text: artistName, style: artistStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      );
      artistPainter.layout(maxWidth: contentWidth);
      headerHeight += artistPainter.height;
      calculatedHeight += headerHeight + elementSpacing;
    }

    final lyricsStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: lyricsFontSize,
      color: lyricsColor,
      height: 1.3,
      fontWeight: FontWeight.w700,
    );
    // 扩展行（翻译 / 罗马音）：与歌词页同层级（主行下、次级文本），海报
    // 字号基数大，比例略收到 0.7 更接近观感层级。
    final extendedLyricsStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: lyricsFontSize * 0.7,
      color: extendedColor,
      height: 1.25,
      fontWeight: FontWeight.w500,
    );
    const double lyricExtendedSpacing = 4.0 * scaleFactor;
    const double lyricExtendedLineSpacing = 2.0 * scaleFactor;
    final List<PosterLyricLine> lyricEntries =
        (posterLyricLines != null && posterLyricLines.isNotEmpty)
            ? posterLyricLines
            : lyrics
                .split('\n')
                .map((line) => PosterLyricLine(text: line))
                .toList();

    final List<TextPainter> lyricLinePainters = [];

    /// 每个 painter 之后要额外留出的间距（主行→扩展行 / 扩展行→扩展行）。
    final List<double> lyricLineGaps = [];
    double totalLyricsBlockHeight = 0;
    final bool hasNonEmptyLyric =
        lyricEntries.any((entry) => entry.text.trim().isNotEmpty);

    TextPainter layoutLine(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      );
      painter.layout(maxWidth: contentWidth);
      return painter;
    }

    if (lyricEntries.isNotEmpty && hasNonEmptyLyric) {
      for (final entry in lyricEntries) {
        lyricLinePainters.add(
          layoutLine(entry.text.isEmpty ? ' ' : entry.text, lyricsStyle),
        );
        final extendedTexts = <String>[
          if (entry.translation.trim().isNotEmpty) entry.translation,
          if (entry.roma.trim().isNotEmpty) entry.roma,
        ];
        lyricLineGaps
            .add(extendedTexts.isEmpty ? 0.0 : lyricExtendedSpacing);
        for (var i = 0; i < extendedTexts.length; i++) {
          lyricLinePainters.add(layoutLine(extendedTexts[i], extendedLyricsStyle));
          lyricLineGaps.add(
            i == extendedTexts.length - 1 ? 0.0 : lyricExtendedLineSpacing,
          );
        }
      }
      for (var i = 0; i < lyricLinePainters.length; i++) {
        totalLyricsBlockHeight += lyricLinePainters[i].height + lyricLineGaps[i];
      }
    } else {
      final emptyLyricPainter = TextPainter(
          text: TextSpan(text: ' ', style: lyricsStyle),
          textDirection: TextDirection.ltr);
      emptyLyricPainter.layout(maxWidth: contentWidth);
      totalLyricsBlockHeight = emptyLyricPainter.height;
      lyricLinePainters.add(emptyLyricPainter);
      lyricLineGaps.add(0);
    }
    calculatedHeight += totalLyricsBlockHeight;
    if (lyricLinePainters.isNotEmpty) calculatedHeight += elementSpacing;

    final watermarkStyle = TextStyle(
        fontFamily: fontFamily,
        fontSize: watermarkFontSize,
        color: watermarkColor,
        fontWeight: FontWeight.w400);
    final watermarkPainter = TextPainter(
      text: TextSpan(text: watermarkText, style: watermarkStyle),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );
    watermarkPainter.layout(maxWidth: contentWidth);

    ui.Image? watermarkIcon;
    try {
      watermarkIcon =
          await _loadAssetImage('assets/icons/adaptive_icon_monochrome.png');
    } catch (e) {
      logger.warning('Failed to load watermark icon: $e');
    }

    final double iconSize = watermarkPainter.height;
    const double iconTextSpacing = 8.0 * scaleFactor;
    double watermarkHeight = watermarkPainter.height;
    if (watermarkIcon != null) {
      watermarkHeight = watermarkHeight > iconSize ? watermarkHeight : iconSize;
    }

    calculatedHeight += watermarkHeight;

    calculatedHeight += bottomMargin;
    final double finalPosterHeight =
        (calculatedHeight < 400) ? 400 : calculatedHeight;

    final recorder = ui.PictureRecorder();
    final canvas =
        Canvas(recorder, Rect.fromLTWH(0, 0, width, finalPosterHeight));

    final backgroundPaint = Paint()..color = backgroundColor;
    canvas.drawRect(
        Rect.fromLTWH(0, 0, width, finalPosterHeight), backgroundPaint);

    double currentY = topMargin;

    if (loadedAlbumImage != null) {
      final titleStyle = TextStyle(
          fontFamily: fontFamily,
          fontSize: titleFontSize,
          color: titleColor,
          fontWeight: FontWeight.w400);
      final titlePainter = TextPainter(
        text: TextSpan(text: trackTitle, style: titleStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      );
      final artistStyle = TextStyle(
          fontFamily: fontFamily,
          fontSize: artistFontSize,
          color: artistColor,
          fontWeight: FontWeight.w400);
      final artistPainter = TextPainter(
        text: TextSpan(text: artistName, style: artistStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      );

      final maxTextWidth = contentWidth - albumArtSize - headerSpacing;
      titlePainter.layout(maxWidth: maxTextWidth);
      artistPainter.layout(maxWidth: maxTextWidth);

      final albumX = horizontalMargin;
      final albumRect =
          Rect.fromLTWH(albumX, currentY, albumArtSize, albumArtSize);
      final albumRRect = RRect.fromRectAndRadius(
          albumRect, const Radius.circular(albumCornerRadius));

      canvas.save();
      canvas.clipRRect(albumRRect);
      canvas.drawImageRect(
        loadedAlbumImage,
        Rect.fromLTWH(0, 0, loadedAlbumImage.width.toDouble(),
            loadedAlbumImage.height.toDouble()),
        albumRect,
        Paint(),
      );
      canvas.restore();

      final textStartX = albumX + albumArtSize + headerSpacing;

      final textTotalHeight =
          titlePainter.height + interTextSpacing + artistPainter.height;
      final textStartY = currentY + (albumArtSize - textTotalHeight) / 2;

      titlePainter.paint(canvas, Offset(textStartX, textStartY));

      artistPainter.paint(
          canvas,
          Offset(
              textStartX, textStartY + titlePainter.height + interTextSpacing));

      currentY += headerHeight + elementSpacing;
    } else {
      final titleStyle = TextStyle(
          fontFamily: fontFamily,
          fontSize: titleFontSize,
          color: titleColor,
          fontWeight: FontWeight.w400);
      final artistStyle = TextStyle(
          fontFamily: fontFamily,
          fontSize: artistFontSize,
          color: artistColor,
          fontWeight: FontWeight.w400);

      final titlePainter = TextPainter(
        text: TextSpan(text: trackTitle, style: titleStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      );
      titlePainter.layout(maxWidth: contentWidth);

      final artistPainter = TextPainter(
        text: TextSpan(text: artistName, style: artistStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      );
      artistPainter.layout(maxWidth: contentWidth);

      _drawText(
          canvas,
          trackTitle,
          Offset(horizontalMargin, currentY + titlePainter.height / 2),
          titleStyle,
          contentWidth,
          TextAlign.left);
      currentY += titlePainter.height + interTextSpacing;

      _drawText(
          canvas,
          artistName,
          Offset(horizontalMargin, currentY + artistPainter.height / 2),
          artistStyle,
          contentWidth,
          TextAlign.left);
      currentY += artistPainter.height + elementSpacing;
    }

    for (int i = 0; i < lyricLinePainters.length; i++) {
      final painter = lyricLinePainters[i];
      _drawTextPainter(
          canvas,
          painter,
          Offset(horizontalMargin, currentY + painter.height / 2),
          TextAlign.left);
      currentY += painter.height + lyricLineGaps[i];
    }
    if (lyricLinePainters.isNotEmpty) {
      currentY += elementSpacing;
    }

    final watermarkY = currentY + (watermarkHeight / 2);

    if (watermarkIcon != null) {
      final watermarkStartX = horizontalMargin;

      final iconY =
          watermarkY - (watermarkHeight / 2) + (watermarkHeight - iconSize) / 2;
      canvas.drawImageRect(
        watermarkIcon,
        Rect.fromLTWH(0, 0, watermarkIcon.width.toDouble(),
            watermarkIcon.height.toDouble()),
        Rect.fromLTWH(watermarkStartX, iconY, iconSize, iconSize),
        Paint()
          ..colorFilter =
              ColorFilter.mode(watermarkColor, BlendMode.srcIn),
      );

      final textX = watermarkStartX + iconSize + iconTextSpacing;
      final textY = watermarkY -
          (watermarkHeight / 2) +
          (watermarkHeight - watermarkPainter.height) / 2;
      watermarkPainter.paint(canvas, Offset(textX, textY));
    } else {
      _drawText(canvas, watermarkText, Offset(horizontalMargin, watermarkY),
          watermarkStyle, contentWidth, TextAlign.left);
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), finalPosterHeight.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);

    return byteData!.buffer.asUint8List();
  }

  Future<String?> savePosterFromBytes(
      Uint8List imageBytes, String trackTitle) async {
    try {
      final name =
          "lyrics_poster_${trackTitle.replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}";
      if (!await Gal.hasAccess()) {
        await Gal.requestAccess();
      }
      await Gal.putImageBytes(imageBytes, name: name);
      logger.fine('Poster saved to gallery: $name');
      return name;
    } catch (e) {
      logger.severe('Error saving poster to gallery: $e');
      rethrow;
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

  // 加载网络图片（统一浏览器 UA + 平台 Referer，修 CDN 403）
  Future<ui.Image> _loadNetworkImage(String url) async {
    final response = await _dio.getUri(
      Uri.parse(url),
      options: Options(headers: ArtworkCache.headersFor(url)),
    );
    if (response.statusCode == 200) {
      final bytes = bodyBytes(response);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } else {
      throw Exception('Failed to load image from $url');
    }
  }

  Future<ui.Image> _loadAssetImage(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset position, // x 为对齐基准（左/中/右），y 为垂直中心
    TextStyle style,
    double maxWidth,
    TextAlign textAlign,
  ) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
    );
    textPainter.layout(maxWidth: maxWidth);

    double dx = position.dx;
    if (textAlign == TextAlign.center) {
      dx -= textPainter.width / 2;
    } else if (textAlign == TextAlign.right) {
      dx -= textPainter.width;
    }
    final offsetY = position.dy - textPainter.height / 2;

    textPainter.paint(canvas, Offset(dx, offsetY));
  }

  void _drawTextPainter(Canvas canvas, TextPainter textPainter, Offset position,
      TextAlign textAlign) {
    double dx = position.dx;
    if (textAlign == TextAlign.center) {
      dx -= textPainter.width / 2;
    } else if (textAlign == TextAlign.right) {
      dx -= textPainter.width;
    }
    final offsetY = position.dy - textPainter.height / 2;
    textPainter.paint(canvas, Offset(dx, offsetY));
  }
}
