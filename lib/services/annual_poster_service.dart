/// 年度听歌海报：固定 1440×1920 PNG，离线绘制，不读取封面网络图。
///
/// 调用方传入已本地化的文案、颜色角色与字体；本模块不读 provider / 主题 /
/// 语言，也不发起任何网络请求。空块直接省略，但画布尺寸保持固定。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme/poster_palette.dart';

/// 海报展示数据（全部为渲染前的字符串 / 数值）。
class AnnualPosterData {
  const AnnualPosterData({
    required this.yearLabel,
    required this.subtitle,
    required this.listenedLabel,
    required this.listenedCaption,
    required this.playsLabel,
    required this.playsCaption,
    required this.artistsLabel,
    required this.artistsCaption,
    required this.streakLabel,
    required this.streakCaption,
    required this.months,
    this.topArtists = const [],
    this.topTracks = const [],
    this.topPlatform,
  });

  final String yearLabel;
  final String subtitle;
  final String listenedLabel;
  final String listenedCaption;
  final String playsLabel;
  final String playsCaption;
  final String artistsLabel;
  final String artistsCaption;
  final String streakLabel;
  final String streakCaption;

  /// 12 个月收听时长（毫秒）；零填充。
  final List<int> months;
  final List<String> topArtists;
  final List<String> topTracks;
  final String? topPlatform;
}

/// 固定海报尺寸（与歌词海报同档，方便分享平台统一裁切）。
const int kAnnualPosterWidth = 1440;
const int kAnnualPosterHeight = 1920;

class AnnualPosterService {
  /// 渲染 PNG 字节；[palette] 复用既有海报配色角色，字体由调用方显式传入。
  Future<Uint8List> render({
    required AnnualPosterData data,
    required PosterPalette palette,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    String watermarkText = 'Molia',
  }) async {
    const width = 1440.0;
    const height = 1920.0;
    const margin = 96.0;
    final contentWidth = width - margin * 2;

    ui.Picture? picture;
    ui.Image? image;
    try {
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
        double? lineHeight,
      }) => TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: size,
        color: color,
        fontWeight: weight,
        height: lineHeight,
      );

      var y = margin + 24;
      y += _paint(
        canvas,
        data.yearLabel,
        Offset(margin, y),
        style(150, palette.title, weight: FontWeight.w700, lineHeight: 1.05),
        contentWidth,
      );
      y += 8;
      y += _paint(
        canvas,
        data.subtitle,
        Offset(margin, y),
        style(38, palette.extended),
        contentWidth,
      );
      y += 56;

      // 主数字：年度总时长。
      y += _paint(
        canvas,
        data.listenedLabel,
        Offset(margin, y),
        style(96, palette.title, weight: FontWeight.w700, lineHeight: 1.1),
        contentWidth,
      );
      y += 6;
      y += _paint(
        canvas,
        data.listenedCaption,
        Offset(margin, y),
        style(30, palette.extended),
        contentWidth,
      );
      y += 48;

      // 次数字行：播放次数 / 歌手数 / 连续天数。
      final columns = [
        (data.playsLabel, data.playsCaption),
        (data.artistsLabel, data.artistsCaption),
        (data.streakLabel, data.streakCaption),
      ];
      const columnGap = 28.0;
      final columnWidth = (contentWidth - columnGap * 2) / 3;
      var maxColumnHeight = 0.0;
      for (var index = 0; index < columns.length; index++) {
        final x = margin + (columnWidth + columnGap) * index;
        var columnY = y;
        columnY += _paint(
          canvas,
          columns[index].$1,
          Offset(x, columnY),
          style(52, palette.title, weight: FontWeight.w700, lineHeight: 1.1),
          columnWidth,
        );
        columnY += 4;
        columnY += _paint(
          canvas,
          columns[index].$2,
          Offset(x, columnY),
          style(24, palette.extended),
          columnWidth,
        );
        if (columnY - y > maxColumnHeight) maxColumnHeight = columnY - y;
      }
      y += maxColumnHeight + 56;

      if (data.topTracks.isNotEmpty) {
        for (final (index, track) in data.topTracks.take(3).indexed) {
          y += _paint(
            canvas,
            '${index + 1}  $track',
            Offset(margin, y),
            style(
              36,
              palette.lyrics,
              weight: FontWeight.w500,
              lineHeight: 1.25,
            ),
            contentWidth,
            maxLines: 2,
          );
          y += 12;
        }
        y += 36;
      }

      if (data.topArtists.isNotEmpty) {
        y += _paint(
          canvas,
          data.topArtists.join(' · '),
          Offset(margin, y),
          style(32, palette.artist, weight: FontWeight.w500),
          contentWidth,
          maxLines: 2,
        );
        y += 44;
      }

      if (data.topPlatform != null) {
        y += _paint(
          canvas,
          data.topPlatform!,
          Offset(margin, y),
          style(28, palette.extended),
          contentWidth,
        );
        y += 36;
      }

      _paintMonthBars(
        canvas,
        data.months,
        rect: Rect.fromLTWH(margin, height - margin - 220, contentWidth, 120),
        color: palette.watermark,
        mutedColor: palette.separator,
      );

      _paint(
        canvas,
        watermarkText,
        Offset(margin, height - margin - 52),
        style(28, palette.watermark),
        contentWidth,
      );

      picture = recorder.endRecording();
      image = await picture.toImage(kAnnualPosterWidth, kAnnualPosterHeight);
      final dataBytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return dataBytes!.buffer.asUint8List();
    } finally {
      image?.dispose();
      picture?.dispose();
    }
  }

  /// 绘制一段文本并返回它占用的高度。
  double _paint(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style,
    double maxWidth, {
    int maxLines = 1,
  }) {
    if (text.isEmpty) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
      textAlign: TextAlign.left,
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  void _paintMonthBars(
    Canvas canvas,
    List<int> months, {
    required Rect rect,
    required Color color,
    required Color mutedColor,
  }) {
    if (months.isEmpty) return;
    final values = List<int>.filled(12, 0);
    for (var index = 0; index < 12 && index < months.length; index++) {
      values[index] = months[index];
    }
    final maxValue = values.fold<int>(
      0,
      (max, value) => value > max ? value : max,
    );
    const gap = 10.0;
    final barWidth = (rect.width - gap * 11) / 12;
    for (var index = 0; index < 12; index++) {
      final x = rect.left + (barWidth + gap) * index;
      final ratio = maxValue <= 0 ? 0.0 : values[index] / maxValue;
      final barHeight = rect.height * ratio;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, rect.bottom - rect.height, barWidth, rect.height),
          const Radius.circular(6),
        ),
        Paint()..color = mutedColor.withValues(alpha: 0.35),
      );
      if (barHeight > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, rect.bottom - barHeight, barWidth, barHeight),
            const Radius.circular(6),
          ),
          Paint()..color = color,
        );
      }
    }
  }
}
