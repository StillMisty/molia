/// 听歌统计海报：固定 1440×1920 PNG，离线绘制，不读取封面网络图。
///
/// 调用方传入已本地化的文案、颜色角色与字体；本模块不读 provider / 主题 /
/// 语言，也不发起任何网络请求。空块直接省略，但画布尺寸保持固定。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme/poster_palette.dart';
import 'poster/poster_draw.dart';

/// 海报榜单行（已格式化）：主标题 + 可选的歌手 / 次数 / 时长说明。
class ListeningStatsPosterRow {
  const ListeningStatsPosterRow({required this.title, this.subtitle = ''});

  final String title;
  final String subtitle;
}

/// 海报展示数据（全部为渲染前的字符串 / 数值）。
class ListeningStatsPosterData {
  const ListeningStatsPosterData({
    required this.title,
    required this.rangeLabel,
    required this.listenedLabel,
    required this.listenedCaption,
    required this.playsLabel,
    required this.playsCaption,
    required this.tracksLabel,
    required this.tracksCaption,
    required this.completionLabel,
    required this.completionCaption,
    this.topTracksTitle = '',
    this.topTracks = const [],
    this.topArtistsTitle = '',
    this.topArtists = const [],
    this.weekdayHourTitle = '',
    this.weekdayLabels = const [],
    this.weekdayHour = const [],
    this.platformLabel,
  });

  final String title;
  final String rangeLabel;
  final String listenedLabel;
  final String listenedCaption;
  final String playsLabel;
  final String playsCaption;
  final String tracksLabel;
  final String tracksCaption;

  /// 完整播放率等百分比；由调用方格式化（例如 `78%`）。
  final String completionLabel;
  final String completionCaption;

  final String topTracksTitle;

  /// 已格式化的榜单行；最多取前 5 条。
  final List<ListeningStatsPosterRow> topTracks;
  final String topArtistsTitle;

  /// 已格式化的榜单行；最多取前 5 条。
  final List<ListeningStatsPosterRow> topArtists;

  /// 作息热力图标题；空则省略该块。
  final String weekdayHourTitle;

  /// 周一开头的 7 个星期缩写。
  final List<String> weekdayLabels;

  /// 7×24 行优先（weekday 0=周一）收听毫秒；长度不是 168 时省略热力图。
  final List<int> weekdayHour;

  /// 已格式化的「最常使用 …」行；空则省略。
  final String? platformLabel;
}

/// 固定海报尺寸（与年度 / 歌词海报同档，方便分享平台统一裁切）。
const int kListeningStatsPosterWidth = 1440;
const int kListeningStatsPosterHeight = 1920;

/// 设计稿边距 / 间距。海报没有 BuildContext，尺寸按固定画布取。
const double _margin = 96;
const double _columnGap = 48;
const double _footerHeight = 36;

typedef _PosterTextStyle = TextStyle Function(
  double size,
  Color color, {
  FontWeight? weight,
  double? lineHeight,
});

class ListeningStatsPosterService {
  const ListeningStatsPosterService();

  /// 渲染 PNG 字节；[palette] 复用既有海报配色角色，字体由调用方显式传入。
  Future<Uint8List> render({
    required ListeningStatsPosterData data,
    required PosterPalette palette,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    String watermarkText = 'Molia',
  }) async {
    final width = kListeningStatsPosterWidth.toDouble();
    final height = kListeningStatsPosterHeight.toDouble();
    final contentWidth = width - _margin * 2;

    ui.Image? brandIcon;
    try {
      brandIcon = await posterLoadAssetImage(
        'assets/icons/adaptive_icon_monochrome.png',
        targetWidth: 64,
      );
    } catch (_) {
      // 图标只是品牌点缀：资源缺失时退回纯文字水印，不影响分享。
      brandIcon = null;
    }

    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
      _paintBackground(canvas, width, height, palette);

      TextStyle style(
        double size,
        Color color, {
        FontWeight? weight,
        double? lineHeight,
      }) => TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: size,
        color: color,
        fontWeight: weight ?? FontWeight.w500,
        height: lineHeight ?? 1.25,
      );

      var y = _margin;

      // 品牌行：与年度海报同一位置，给分享图一个可识别的出处。
      final brandPainter = _layoutText(
        watermarkText,
        style(30, palette.watermark),
        contentWidth,
      );
      final brandHeight = posterDrawWatermark(
        canvas,
        icon: brandIcon,
        painter: brandPainter,
        leftX: _margin,
        centerY: y + brandPainter.height / 2,
        color: palette.watermark,
        iconTextSpacing: 12,
      );
      brandPainter.dispose();
      y += math.max(brandHeight, 36) + 44;

      // 标题与范围。标题只允许一行：固定标题不该在分享图里换行挤压主数字。
      y += posterPaintText(
        canvas,
        data.title,
        Offset(_margin, y),
        style(96, palette.title, weight: FontWeight.w700, lineHeight: 1.05),
        contentWidth,
        maxLines: 1,
      );
      y += 24;
      y += posterPaintText(
        canvas,
        data.rangeLabel,
        Offset(_margin, y),
        style(34, palette.extended),
        contentWidth,
        maxLines: 1,
      );
      y += 40;

      // 主数字：范围内总收听时长，字号明显高于标题。
      y += posterPaintText(
        canvas,
        data.listenedLabel,
        Offset(_margin, y),
        style(116, palette.title, weight: FontWeight.w700, lineHeight: 1.05),
        contentWidth,
        maxLines: 1,
      );
      y += 6;
      y += posterPaintText(
        canvas,
        data.listenedCaption,
        Offset(_margin, y),
        style(30, palette.extended),
        contentWidth,
      );
      y += 40;

      // 次数字卡：有效播放 / 曲目数 / 完整播放率。
      y = _paintStats(
        canvas,
        palette: palette,
        style: style,
        top: y,
        left: _margin,
        contentWidth: contentWidth,
        columns: [
          (data.playsLabel, data.playsCaption),
          (data.tracksLabel, data.tracksCaption),
          (data.completionLabel, data.completionCaption),
        ],
      );
      y += 40;

      final heatmapBottom = _paintWeekdayHour(
        canvas,
        data: data,
        palette: palette,
        style: style,
        top: y,
        left: _margin,
        contentWidth: contentWidth,
      );
      if (heatmapBottom != null) y = heatmapBottom + 40;

      // 页脚先算出上沿：榜单按实际高度锚定，短内容向下靠、长内容不压水印。
      final footerTop = height - _margin - _footerHeight;
      final columnWidth = (contentWidth - _columnGap) / 2;
      final tracks = data.topTracks.take(5).toList(growable: false);
      final artists = data.topArtists.take(5).toList(growable: false);
      final tracksHeight = _rankedHeight(
        title: data.topTracksTitle,
        rows: tracks,
        palette: palette,
        style: style,
        width: columnWidth,
      );
      final artistsHeight = _rankedHeight(
        title: data.topArtistsTitle,
        rows: artists,
        palette: palette,
        style: style,
        width: columnWidth,
      );
      final lowerHeight = math.max(tracksHeight, artistsHeight);
      final lowerTop = lowerHeight > 0
          ? math.max(y, footerTop - lowerHeight - 40)
          : y;

      final leftBottom = _paintRanked(
        canvas,
        palette: palette,
        style: style,
        top: lowerTop,
        left: _margin,
        width: columnWidth,
        title: data.topTracksTitle,
        rows: tracks,
      );
      final rightBottom = _paintRanked(
        canvas,
        palette: palette,
        style: style,
        top: lowerTop,
        left: _margin + columnWidth + _columnGap,
        width: columnWidth,
        title: data.topArtistsTitle,
        rows: artists,
      );
      final contentBottom = math.max(leftBottom, rightBottom);

      final footerY = contentBottom > 0
          ? math.max(contentBottom + 36, footerTop)
          : footerTop;
      _paintFooter(
        canvas,
        palette: palette,
        style: style,
        icon: brandIcon,
        text: watermarkText,
        top: footerY,
        left: _margin,
        maxWidth: contentWidth,
        platform: data.platformLabel,
      );

      return await posterEncodePng(
        recorder,
        width: kListeningStatsPosterWidth,
        height: kListeningStatsPosterHeight,
      );
    } finally {
      brandIcon?.dispose();
    }
  }

  void _paintBackground(
    Canvas canvas,
    double width,
    double height,
    PosterPalette palette,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = palette.background,
    );
    // 右上角淡光晕与年度海报一致：给大数字一点空间感，同时不改变
    // 左上角背景色测试的采样点。
    final glowCenter = Offset(width - 120, 160);
    const glowRadius = 460.0;
    canvas.drawCircle(
      glowCenter,
      glowRadius,
      Paint()
        ..shader = ui.Gradient.radial(glowCenter, glowRadius, [
          palette.artist.withValues(alpha: 0.10),
          palette.artist.withValues(alpha: 0),
        ]),
    );
  }

  double _paintStats(
    Canvas canvas, {
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double top,
    required double left,
    required double contentWidth,
    required List<(String, String)> columns,
  }) {
    if (columns.isEmpty) return top;
    const cardGap = 24.0;
    const cardHeight = 160.0;
    final cardWidth =
        (contentWidth - cardGap * (columns.length - 1)) / columns.length;
    for (var index = 0; index < columns.length; index++) {
      final x = left + (cardWidth + cardGap) * index;
      final rect = Rect.fromLTWH(x, top, cardWidth, cardHeight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(24)),
        Paint()..color = palette.title.withValues(alpha: 0.05),
      );
      posterPaintText(
        canvas,
        columns[index].$1,
        Offset(x + 28, top + 24),
        style(58, palette.title, weight: FontWeight.w700, lineHeight: 1.05),
        cardWidth - 56,
        maxLines: 1,
      );
      posterPaintText(
        canvas,
        columns[index].$2,
        Offset(x + 28, top + 100),
        style(24, palette.extended),
        cardWidth - 56,
        maxLines: 2,
      );
    }
    return top + cardHeight;
  }

  /// 7×24 作息热力图；数据不完整或无标题时返回 null，后续板块继续上移。
  double? _paintWeekdayHour(
    Canvas canvas, {
    required ListeningStatsPosterData data,
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double top,
    required double left,
    required double contentWidth,
  }) {
    if (data.weekdayHour.length != 168 ||
        data.weekdayLabels.length < 7 ||
        data.weekdayHourTitle.isEmpty) {
      return null;
    }
    var y = top;
    y += posterPaintText(
      canvas,
      data.weekdayHourTitle,
      Offset(left, y),
      style(36, palette.artist, weight: FontWeight.w700),
      contentWidth,
    );
    y += 12;

    const padding = 24.0;
    const labelWidth = 48.0;
    const cellGap = 8.0;
    const hourLabelHeight = 22.0;
    final innerWidth = contentWidth - padding * 2;
    final cellSize = math.max(
      8.0,
      math.min(36.0, (innerWidth - labelWidth - 23 * cellGap) / 24),
    );
    final gridHeight = 7 * (cellSize + cellGap);
    final cardHeight = padding * 2 + hourLabelHeight + 8 + gridHeight;
    final rect = Rect.fromLTWH(left, y, contentWidth, cardHeight);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(24)),
      Paint()..color = palette.title.withValues(alpha: 0.04),
    );

    final hourStyle = style(20, palette.extended);
    for (var hour = 0; hour < 24; hour += 6) {
      final x = rect.left + padding + labelWidth + hour * (cellSize + cellGap);
      posterPaintText(
        canvas,
        '$hour',
        Offset(x, rect.top + padding),
        hourStyle,
        6 * (cellSize + cellGap),
        maxLines: 1,
      );
    }

    final maxValue = data.weekdayHour.fold<int>(
      0,
      (max, value) => math.max(max, value),
    );
    final gridTop = rect.top + padding + hourLabelHeight + 8;
    final cellPaint = Paint();
    final weekdayStyle = style(20, palette.extended);
    for (var weekday = 0; weekday < 7; weekday++) {
      final rowY = gridTop + weekday * (cellSize + cellGap);
      final labelPainter = _layoutText(
        data.weekdayLabels[weekday],
        weekdayStyle,
        labelWidth,
      );
      labelPainter.paint(
        canvas,
        Offset(
          rect.left + padding + labelWidth - labelPainter.width - 8,
          rowY + (cellSize - labelPainter.height) / 2,
        ),
      );
      labelPainter.dispose();

      for (var hour = 0; hour < 24; hour++) {
        final value = data.weekdayHour[weekday * 24 + hour];
        final x =
            rect.left + padding + labelWidth + hour * (cellSize + cellGap);
        final cellRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, rowY, cellSize, cellSize),
          Radius.circular(math.min(8, cellSize * 0.22)),
        );
        canvas.drawRRect(
          cellRect,
          cellPaint..color = _heatColor(palette, value, maxValue),
        );
      }
    }
    return y + cardHeight;
  }

  Color _heatColor(PosterPalette palette, int value, int maxValue) {
    if (value <= 0 || maxValue <= 0) {
      return palette.title.withValues(alpha: 0.06);
    }
    final ratio = (value / maxValue).clamp(0.0, 1.0);
    return palette.artist.withValues(alpha: 0.18 + 0.62 * math.sqrt(ratio));
  }

  double _rankedHeight({
    required String title,
    required List<ListeningStatsPosterRow> rows,
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double width,
  }) {
    if (rows.isEmpty) return 0;
    // 测量不关心颜色，用标题色保持「颜色只来自 palette」的契约。
    final metricColor = palette.title;
    var height = _textHeight(
      title,
      style(36, metricColor, weight: FontWeight.w700),
      width,
    );
    height += 10;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final rankHeight = _textHeight(
        '${index + 1}',
        style(30, metricColor, weight: FontWeight.w700, lineHeight: 1.15),
        48,
      );
      final titleHeight = _textHeight(
        row.title,
        style(32, metricColor, lineHeight: 1.15),
        width - 48,
        maxLines: 1,
      );
      var textHeight = titleHeight;
      if (row.subtitle.isNotEmpty) {
        textHeight +=
            4 +
            _textHeight(
              row.subtitle,
              style(22, metricColor),
              width - 48,
              maxLines: 1,
            );
      }
      height += math.max(rankHeight, textHeight);
      if (index < rows.length - 1) height += 12;
    }
    return height;
  }

  double _paintRanked(
    Canvas canvas, {
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double top,
    required double left,
    required double width,
    required String title,
    required List<ListeningStatsPosterRow> rows,
  }) {
    if (rows.isEmpty) return top;
    var y = top;
    y += posterPaintText(
      canvas,
      title,
      Offset(left, y),
      style(36, palette.artist, weight: FontWeight.w700),
      width,
    );
    y += 10;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final rankHeight = posterPaintText(
        canvas,
        '${index + 1}',
        Offset(left, y),
        style(30, palette.artist, weight: FontWeight.w700, lineHeight: 1.15),
        48,
      );
      final titleHeight = posterPaintText(
        canvas,
        row.title,
        Offset(left + 48, y),
        style(32, palette.lyrics, lineHeight: 1.15),
        width - 48,
        maxLines: 1,
      );
      var textHeight = titleHeight;
      if (row.subtitle.isNotEmpty) {
        textHeight +=
            4 +
            posterPaintText(
              canvas,
              row.subtitle,
              Offset(left + 48, y + titleHeight + 4),
              style(22, palette.extended),
              width - 48,
              maxLines: 1,
            );
      }
      y += math.max(rankHeight, textHeight);
      if (index < rows.length - 1) y += 12;
    }
    return y;
  }

  void _paintFooter(
    Canvas canvas, {
    required PosterPalette palette,
    required _PosterTextStyle style,
    required ui.Image? icon,
    required String text,
    required double top,
    required double left,
    required double maxWidth,
    required String? platform,
  }) {
    final painter = _layoutText(
      text,
      style(28, palette.watermark.withValues(alpha: 0.75)),
      maxWidth,
    );
    final centerY = top + painter.height / 2;
    posterDrawWatermark(
      canvas,
      icon: icon,
      painter: painter,
      leftX: left,
      centerY: centerY,
      color: palette.watermark.withValues(alpha: 0.75),
      iconTextSpacing: 10,
    );
    painter.dispose();

    final platformText = platform?.trim() ?? '';
    if (platformText.isEmpty) return;
    final platformPainter = _layoutText(
      platformText,
      style(24, palette.extended),
      math.min(maxWidth * 0.55, 640),
    );
    platformPainter.paint(
      canvas,
      Offset(
        left + maxWidth - platformPainter.width,
        centerY - platformPainter.height / 2,
      ),
    );
    platformPainter.dispose();
  }

  TextPainter _layoutText(
    String text,
    TextStyle style,
    double maxWidth, {
    int maxLines = 1,
  }) {
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
  }

  double _textHeight(
    String text,
    TextStyle style,
    double maxWidth, {
    int maxLines = 1,
  }) {
    if (text.isEmpty) return 0;
    final painter = _layoutText(text, style, maxWidth, maxLines: maxLines);
    final height = painter.height;
    painter.dispose();
    return height;
  }
}
