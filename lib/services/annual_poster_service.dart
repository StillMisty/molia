/// 年度听歌海报：固定 1440×1920 PNG，离线绘制，不读取封面网络图。
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

/// 海报里的一首年度常听曲目。
///
/// 海报只展示歌名与歌手，不读取封面：年度报告可能包含多个平台的曲目，
/// 分享图不应为了封面再发起一批网络请求。
class AnnualPosterTrack {
  const AnnualPosterTrack({required this.title, this.artist = ''});

  final String title;
  final String artist;
}

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
    required this.monthlyTitle,
    required this.topTracksTitle,
    required this.topArtistsTitle,
    required this.months,
    this.yearNote,
    this.topArtists = const [],
    this.topTracks = const [],
    this.topPlatform,
  });

  final String yearLabel;
  final String subtitle;

  /// 年份旁的补充说明（例如「截至今天」）；空串不绘制。
  final String? yearNote;

  final String listenedLabel;
  final String listenedCaption;
  final String playsLabel;
  final String playsCaption;
  final String artistsLabel;
  final String artistsCaption;
  final String streakLabel;
  final String streakCaption;

  /// 分节标题由调用方本地化后传入，海报服务不读 l10n。
  final String monthlyTitle;
  final String topTracksTitle;
  final String topArtistsTitle;

  /// 12 个月收听时长（毫秒）；零填充。
  final List<int> months;
  final List<String> topArtists;
  final List<AnnualPosterTrack> topTracks;
  final String? topPlatform;
}

/// 固定海报尺寸（与歌词海报同档，方便分享平台统一裁切）。
const int kAnnualPosterWidth = 1440;
const int kAnnualPosterHeight = 1920;

/// 设计稿边距 / 间距。海报没有 BuildContext，尺寸按固定设计稿取。
const double _margin = 96;
const double _columnGap = 48;

/// 海报的固定排版样式工厂：字号 / 颜色由设计稿给，字重 / 行高可覆盖。
typedef _PosterTextStyle = TextStyle Function(
  double size,
  Color color, {
  FontWeight? weight,
  double? lineHeight,
});

class AnnualPosterService {
  /// 渲染 PNG 字节；[palette] 复用既有海报配色角色，字体由调用方显式传入。
  Future<Uint8List> render({
    required AnnualPosterData data,
    required PosterPalette palette,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    String watermarkText = 'Molia',
  }) async {
    final width = kAnnualPosterWidth.toDouble();
    final height = kAnnualPosterHeight.toDouble();
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
        height: lineHeight ?? 1.2,
      );

      var y = _margin;

      // 品牌行：左侧图标 + 品牌名，右侧年份备注。品牌行不抢年份的视觉重心。
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
      if (data.yearNote != null && data.yearNote!.isNotEmpty) {
        final notePainter = _layoutText(
          data.yearNote!,
          style(28, palette.extended),
          contentWidth,
        );
        notePainter.paint(
          canvas,
          Offset(width - _margin - notePainter.width, y),
        );
        notePainter.dispose();
      }
      brandPainter.dispose();
      y += math.max(brandHeight, 36) + 44;

      // 年份标题：年度报告的唯一主视觉，字号明显高于其他内容。
      y += posterPaintText(
        canvas,
        data.yearLabel,
        Offset(_margin, y),
        style(180, palette.title, weight: FontWeight.w700, lineHeight: 1),
        contentWidth,
      );
      y += 6;
      final subtitleStyle = style(40, palette.extended);
      y += posterPaintText(
        canvas,
        data.subtitle,
        Offset(_margin, y),
        subtitleStyle,
        contentWidth,
      );
      y += 36;

      // 主数字：年度总时长。
      y += posterPaintText(
        canvas,
        data.listenedLabel,
        Offset(_margin, y),
        style(96, palette.title, weight: FontWeight.w700, lineHeight: 1.08),
        contentWidth,
      );
      y += 8;
      y += posterPaintText(
        canvas,
        data.listenedCaption,
        Offset(_margin, y),
        style(30, palette.extended),
        contentWidth,
      );
      y += 44;

      // 次数字行：三张统计卡，避免裸排三列在空白背景上显得轻。
      y = _paintStats(
        canvas,
        palette: palette,
        style: style,
        top: y,
        left: _margin,
        contentWidth: contentWidth,
        columns: [
          (data.playsLabel, data.playsCaption),
          (data.artistsLabel, data.artistsCaption),
          (data.streakLabel, data.streakCaption),
        ],
      );
      y += 44;

      y = _paintMonthly(
        canvas,
        palette: palette,
        style: style,
        top: y,
        left: _margin,
        contentWidth: contentWidth,
        title: data.monthlyTitle,
        months: data.months,
      );
      y += 40;

      final footerTop = height - _margin - 22;
      final columnWidth = (contentWidth - _columnGap) / 2;
      final topTracks = data.topTracks.take(3).toList(growable: false);
      final topArtists = data.topArtists.take(3).toList(growable: false);
      final lowerHeight = math.max(
        _topTracksHeight(
          palette: palette,
          style: style,
          width: columnWidth,
          title: data.topTracksTitle,
          tracks: topTracks,
        ),
        _topArtistsHeight(
          palette: palette,
          style: style,
          width: columnWidth,
          title: data.topArtistsTitle,
          artists: topArtists,
          platform: data.topPlatform,
        ),
      );
      // 先把榜单区实际高度量出来，再把它压到页脚上方：短内容不会在页脚
      // 前留一大条空白，长歌名也不会压到水印。
      final lowerTop = lowerHeight > 0
          ? math.max(y, footerTop - lowerHeight - 32)
          : y;
      final leftBottom = _paintTopTracks(
        canvas,
        palette: palette,
        style: style,
        top: lowerTop,
        left: _margin,
        width: columnWidth,
        title: data.topTracksTitle,
        tracks: topTracks,
      );
      final rightBottom = _paintTopArtists(
        canvas,
        palette: palette,
        style: style,
        top: lowerTop,
        left: _margin + columnWidth + _columnGap,
        width: columnWidth,
        title: data.topArtistsTitle,
        artists: topArtists,
        platform: data.topPlatform,
      );
      // 两个榜单高度不同；页脚只按最低的一条内容留白，不强行拉伸。
      final contentBottom = math.max(leftBottom, rightBottom);

      _paintFooter(
        canvas,
        palette: palette,
        style: style,
        icon: brandIcon,
        text: watermarkText,
        top: math.max(contentBottom + 36, footerTop - 24),
        left: _margin,
        maxWidth: contentWidth,
      );

      return await posterEncodePng(
        recorder,
        width: kAnnualPosterWidth,
        height: kAnnualPosterHeight,
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
    // 右上角一团很淡的强调色光晕，给大年份一点空间感；远离左上角，
    // 不改变背景色测试的采样点。
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
    const cardGap = 24.0;
    const cardHeight = 168.0;
    final cardWidth = (contentWidth - cardGap * 2) / 3;
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
        Offset(x + 28, top + 28),
        style(60, palette.title, weight: FontWeight.w700, lineHeight: 1.05),
        cardWidth - 56,
      );
      posterPaintText(
        canvas,
        columns[index].$2,
        Offset(x + 28, top + 108),
        style(26, palette.extended),
        cardWidth - 56,
        maxLines: 2,
      );
    }
    return top + cardHeight;
  }

  double _paintMonthly(
    Canvas canvas, {
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double top,
    required double left,
    required double contentWidth,
    required String title,
    required List<int> months,
  }) {
    var y = top;
    y += posterPaintText(
      canvas,
      title,
      Offset(left, y),
      style(40, palette.artist, weight: FontWeight.w700),
      contentWidth,
    );
    y += 12;

    const cardHeight = 380.0;
    final cardRect = Rect.fromLTWH(left, y, contentWidth, cardHeight);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cardRect, const Radius.circular(24)),
      Paint()..color = palette.title.withValues(alpha: 0.04),
    );

    final values = List<int>.filled(12, 0);
    for (var index = 0; index < 12 && index < months.length; index++) {
      values[index] = months[index];
    }
    final maxValue = values.fold<int>(
      0,
      (max, value) => value > max ? value : max,
    );
    var peakIndex = -1;
    if (maxValue > 0 &&
        values.where((value) => value == maxValue).length == 1) {
      peakIndex = values.indexOf(maxValue);
    }

    final chart = Rect.fromLTWH(left + 32, y + 34, contentWidth - 64, 266);
    final baselinePaint = Paint()
      ..color = palette.separator.withValues(alpha: 0.7)
      ..strokeWidth = 1.5;
    canvas.drawLine(chart.bottomLeft, chart.bottomRight, baselinePaint);

    const gap = 12.0;
    final barWidth = (chart.width - gap * 11) / 12;
    for (var index = 0; index < 12; index++) {
      final x = chart.left + (barWidth + gap) * index;
      final ratio = maxValue <= 0 ? 0.0 : values[index] / maxValue;
      final barHeight = ratio <= 0 ? 0.0 : math.max(6.0, chart.height * ratio);
      final trackRect = Rect.fromLTWH(x, chart.top, barWidth, chart.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(trackRect, const Radius.circular(8)),
        Paint()..color = palette.title.withValues(alpha: 0.06),
      );
      if (barHeight > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, chart.bottom - barHeight, barWidth, barHeight),
            const Radius.circular(8),
          ),
          Paint()
            ..color = index == peakIndex
                ? palette.artist
                : palette.artist.withValues(alpha: 0.55),
        );
      }
      posterPaintTextAligned(
        canvas,
        '${index + 1}',
        Offset(x + barWidth / 2, chart.bottom + 28),
        style(22, palette.extended),
        barWidth,
        TextAlign.center,
      );
    }
    return y + cardHeight;
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

  /// 榜单区高度只用来决定起点，不参与绘制；与绘制逻辑共用同一批字号 / 行高。
  double _topTracksHeight({
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double width,
    required String title,
    required List<AnnualPosterTrack> tracks,
  }) {
    if (tracks.isEmpty) return 0;
    // 测量不关心颜色，用海报标题色保持「颜色只来自 palette」的契约。
    final metricColor = palette.title;
    var height = _textHeight(
      title,
      style(38, metricColor, weight: FontWeight.w700),
      width,
    );
    height += 16;
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index];
      final rankHeight = _textHeight(
        '${index + 1}',
        style(32, metricColor, weight: FontWeight.w700),
        44,
      );
      final titleHeight = _textHeight(
        track.title,
        style(38, metricColor, lineHeight: 1.2),
        width - 48,
        maxLines: 2,
      );
      var rowHeight = math.max(rankHeight, titleHeight);
      if (track.artist.isNotEmpty) {
        rowHeight +=
            4 + _textHeight(track.artist, style(26, metricColor), width - 48);
      }
      height += rowHeight;
      if (index < tracks.length - 1) height += 22;
    }
    return height;
  }

  double _topArtistsHeight({
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double width,
    required String title,
    required List<String> artists,
    required String? platform,
  }) {
    final metricColor = palette.title;
    final platformText = platform?.trim() ?? '';
    if (artists.isEmpty && platformText.isEmpty) return 0;
    var height = 0.0;
    if (artists.isNotEmpty) {
      height += _textHeight(
        title,
        style(38, metricColor, weight: FontWeight.w700),
        width,
      );
      height += 16;
      for (var index = 0; index < artists.length; index++) {
        final rankHeight = _textHeight(
          '${index + 1}',
          style(32, metricColor, weight: FontWeight.w700),
          44,
        );
        final nameHeight = _textHeight(
          artists[index],
          style(38, metricColor),
          width - 48,
        );
        height += math.max(rankHeight, nameHeight);
        if (index < artists.length - 1) height += 22;
      }
    }
    if (platformText.isNotEmpty) {
      if (artists.isNotEmpty) height += 30;
      height +=
          _textHeight(platformText, style(28, metricColor), width - 48) + 28;
    }
    return height;
  }

  double _paintTopTracks(
    Canvas canvas, {
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double top,
    required double left,
    required double width,
    required String title,
    required List<AnnualPosterTrack> tracks,
  }) {
    if (tracks.isEmpty) return top;
    var y = top;
    y += posterPaintText(
      canvas,
      title,
      Offset(left, y),
      style(38, palette.artist, weight: FontWeight.w700),
      width,
    );
    y += 16;
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index];
      final rankHeight = posterPaintText(
        canvas,
        '${index + 1}',
        Offset(left, y + 2),
        style(32, palette.artist, weight: FontWeight.w700),
        44,
      );
      final textLeft = left + 48;
      final textWidth = width - 48;
      final titleHeight = posterPaintText(
        canvas,
        track.title,
        Offset(textLeft, y),
        style(38, palette.lyrics, lineHeight: 1.2),
        textWidth,
        maxLines: 2,
      );
      var rowHeight = math.max(rankHeight, titleHeight);
      if (track.artist.isNotEmpty) {
        rowHeight += 4;
        rowHeight += posterPaintText(
          canvas,
          track.artist,
          Offset(textLeft, y + rowHeight - 4),
          style(26, palette.extended),
          textWidth,
        );
      }
      y += rowHeight;
      if (index < tracks.length - 1) y += 22;
    }
    return y;
  }

  double _paintTopArtists(
    Canvas canvas, {
    required PosterPalette palette,
    required _PosterTextStyle style,
    required double top,
    required double left,
    required double width,
    required String title,
    required List<String> artists,
    required String? platform,
  }) {
    final platformText = platform?.trim() ?? '';
    if (artists.isEmpty && platformText.isEmpty) return top;
    var y = top;
    if (artists.isNotEmpty) {
      y += posterPaintText(
        canvas,
        title,
        Offset(left, y),
        style(38, palette.artist, weight: FontWeight.w700),
        width,
      );
      y += 16;
      for (var index = 0; index < artists.length; index++) {
        final rankHeight = posterPaintText(
          canvas,
          '${index + 1}',
          Offset(left, y + 2),
          style(32, palette.artist, weight: FontWeight.w700),
          44,
        );
        final nameHeight = posterPaintText(
          canvas,
          artists[index],
          Offset(left + 48, y),
          style(38, palette.lyrics),
          width - 48,
        );
        y += math.max(rankHeight, nameHeight);
        if (index < artists.length - 1) y += 22;
      }
    }

    if (platformText.isNotEmpty) {
      y += 30;
      final painter = _layoutText(
        platformText,
        style(28, palette.title),
        width - 48,
      );
      final pill = Rect.fromLTWH(
        left,
        y,
        math.min(width, painter.width + 48),
        painter.height + 28,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(pill, const Radius.circular(24)),
        Paint()..color = palette.artist.withValues(alpha: 0.12),
      );
      painter.paint(canvas, Offset(pill.left + 24, pill.top + 14));
      painter.dispose();
      y += pill.height;
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
  }) {
    final painter = _layoutText(
      text,
      style(28, palette.watermark.withValues(alpha: 0.75)),
      maxWidth,
    );
    posterDrawWatermark(
      canvas,
      icon: icon,
      painter: painter,
      leftX: left,
      centerY: top + painter.height / 2,
      color: palette.watermark.withValues(alpha: 0.75),
      iconTextSpacing: 10,
    );
    painter.dispose();
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
}
