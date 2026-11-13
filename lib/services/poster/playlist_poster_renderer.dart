/// 列表分享海报渲染：1440×1920 PNG，3×3 封面马赛克 + 名称 / 描述 / 数量 /
/// 前五首 + Molia 水印。
///
/// 离线：只解码调用方提供的本机封面字节，不发网络请求、不读路径；马赛克槽位
/// 按缩略图目标尺寸解码（不是九张全分辨率封面），所有图像在返回前释放。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../theme/poster_palette.dart';
import 'playlist_poster_layout.dart';
import 'poster_draw.dart';

class PlaylistPosterRenderer {
  const PlaylistPosterRenderer();

  /// 马赛克单格解码宽度：1440 成品里单格约 240px，2x 取 480 足够。
  static const int _thumbTargetWidth = 480;

  Future<Uint8List> render({
    required PlaylistShareContent content,
    required List<Uint8List?> covers,
    required PosterPalette palette,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    String watermarkText = 'Molia',
  }) async {
    final width = kPlaylistPosterWidth.toDouble();
    final height = kPlaylistPosterMaxHeight.toDouble();
    const margin = 96.0;
    final contentWidth = width - margin * 2;
    const mosaicCell = 240.0;
    const mosaicGap = 12.0;

    final images = <ui.Image?>[];
    ui.Image? mark;
    try {
      try {
        mark = await posterLoadAssetImage(
          'assets/icons/adaptive_icon_monochrome.png',
          targetWidth: 64,
        );
      } catch (_) {
        // 水印图标缺失只影响品牌图形，文字水印仍然保留。
      }
      for (var index = 0; index < kPlaylistPosterMosaicSlots; index++) {
        final bytes = index < covers.length ? covers[index] : null;
        if (bytes == null || bytes.isEmpty) {
          images.add(null);
          continue;
        }
        try {
          images.add(
            await posterDecodeImage(bytes, targetWidth: _thumbTargetWidth),
          );
        } catch (_) {
          // 损坏封面只让这一格变中性，不影响整张海报。
          images.add(null);
        }
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width, height),
        Paint()..color = palette.background,
      );

      TextStyle style(
        double size,
        Color color, {
        FontWeight weight = FontWeight.w500,
        double height = 1.25,
      }) => TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: size,
        color: color,
        fontWeight: weight,
        height: height,
      );

      var y = margin;
      for (var index = 0; index < kPlaylistPosterMosaicSlots; index++) {
        final column = index % 3;
        final row = index ~/ 3;
        final rect = Rect.fromLTWH(
          margin + column * (mosaicCell + mosaicGap),
          y + row * (mosaicCell + mosaicGap),
          mosaicCell,
          mosaicCell,
        );
        final image = images[index];
        if (image != null) {
          posterDrawCover(canvas, image, rect, cornerRadius: 18);
        } else {
          canvas.save();
          canvas.clipRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(18)),
          );
          canvas.drawRect(
            rect,
            Paint()..color = palette.watermark.withValues(alpha: 0.10),
          );
          final note = TextPainter(
            text: TextSpan(
              text: '♪',
              style: style(
                72,
                palette.watermark.withValues(alpha: 0.35),
                weight: FontWeight.w400,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          note.paint(
            canvas,
            Offset(
              rect.center.dx - note.width / 2,
              rect.center.dy - note.height / 2,
            ),
          );
          note.dispose();
          canvas.restore();
        }
      }
      y += mosaicCell * 3 + mosaicGap * 2 + 48;

      y += posterPaintText(
        canvas,
        content.name,
        Offset(margin, y),
        style(64, palette.title, weight: FontWeight.w700, height: 1.15),
        contentWidth,
        maxLines: 2,
      );
      if (content.description.trim().isNotEmpty) {
        y += 12;
        y += posterPaintText(
          canvas,
          content.description,
          Offset(margin, y),
          style(32, palette.extended, height: 1.35),
          contentWidth,
          maxLines: 2,
        );
      }
      y += 24;
      y += posterPaintText(
        canvas,
        content.trackCountLabel,
        Offset(margin, y),
        style(28, palette.artist, weight: FontWeight.w700),
        contentWidth,
      );
      y += 28;

      for (final track in content.posterTracks) {
        y += posterPaintText(
          canvas,
          track.label,
          Offset(margin, y),
          style(30, palette.lyrics, height: 1.3),
          contentWidth,
        );
        y += 12;
      }
      if (content.posterExtraCount > 0) {
        y += 8;
        posterPaintText(
          canvas,
          content.andMoreLabel(content.posterExtraCount),
          Offset(margin, y),
          style(26, palette.extended),
          contentWidth,
        );
      }

      // 水印固定底部：内容再长也不会把品牌挤出画布。
      final watermark = TextPainter(
        text: TextSpan(
          text: watermarkText,
          style: style(28, palette.watermark, weight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: contentWidth);
      posterDrawWatermark(
        canvas,
        icon: mark,
        painter: watermark,
        leftX: margin,
        centerY: height - margin - 14,
        color: palette.watermark,
      );
      watermark.dispose();

      return await posterEncodePng(
        recorder,
        width: kPlaylistPosterWidth,
        height: kPlaylistPosterMaxHeight,
      );
    } finally {
      mark?.dispose();
      for (final image in images) {
        image?.dispose();
      }
    }
  }
}
