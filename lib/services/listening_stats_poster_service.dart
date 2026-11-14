/// 听歌统计海报：固定 1440×1920 PNG，离线绘制，不读取封面网络图。
///
/// 调用方传入已本地化的文案、颜色角色与字体；本模块不读 provider / 主题 /
/// 语言，也不发起任何网络请求。空块直接省略，但画布尺寸保持固定。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme/poster_palette.dart';
import 'poster/poster_draw.dart';

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
    this.topTracksTitle = '',
    this.topTracks = const [],
    this.topArtistsTitle = '',
    this.topArtists = const [],
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
  final String topTracksTitle;

  /// 已格式化的「曲名 — 歌手」行；最多取前 5 条。
  final List<String> topTracks;
  final String topArtistsTitle;

  /// 已格式化的歌手名；最多取前 5 条。
  final List<String> topArtists;

  /// 已格式化的「最常使用 …」行；空则省略。
  final String? platformLabel;
}

/// 固定海报尺寸（与年度 / 歌词海报同档，方便分享平台统一裁切）。
const int kListeningStatsPosterWidth = 1440;
const int kListeningStatsPosterHeight = 1920;

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
    const margin = 96.0;
    final contentWidth = width - margin * 2;

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
      double lineHeight = 1.25,
    }) => TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: lineHeight,
    );

    var y = margin + 24;
    y += posterPaintText(
      canvas,
      data.title,
      Offset(margin, y),
      style(110, palette.title, weight: FontWeight.w700, lineHeight: 1.05),
      contentWidth,
      maxLines: 2,
    );
    y += 8;
    y += posterPaintText(
      canvas,
      data.rangeLabel,
      Offset(margin, y),
      style(40, palette.extended),
      contentWidth,
    );
    y += 48;

    // 主数字：范围内总收听时长。
    y += posterPaintText(
      canvas,
      data.listenedLabel,
      Offset(margin, y),
      style(96, palette.title, weight: FontWeight.w700, lineHeight: 1.1),
      contentWidth,
    );
    y += 6;
    y += posterPaintText(
      canvas,
      data.listenedCaption,
      Offset(margin, y),
      style(30, palette.extended),
      contentWidth,
    );
    y += 44;

    // 次数字行：有效播放次数 / 去重曲目数。
    final columns = [
      (data.playsLabel, data.playsCaption),
      (data.tracksLabel, data.tracksCaption),
    ];
    const columnGap = 40.0;
    final columnWidth = (contentWidth - columnGap) / 2;
    var maxColumnHeight = 0.0;
    for (var index = 0; index < columns.length; index++) {
      final x = margin + (columnWidth + columnGap) * index;
      var columnY = y;
      columnY += posterPaintText(
        canvas,
        columns[index].$1,
        Offset(x, columnY),
        style(52, palette.title, weight: FontWeight.w700, lineHeight: 1.1),
        columnWidth,
      );
      columnY += 4;
      columnY += posterPaintText(
        canvas,
        columns[index].$2,
        Offset(x, columnY),
        style(24, palette.extended),
        columnWidth,
      );
      if (columnY - y > maxColumnHeight) maxColumnHeight = columnY - y;
    }
    y += maxColumnHeight + 52;

    final topTracks = data.topTracks.take(5).toList(growable: false);
    if (topTracks.isNotEmpty) {
      y += posterPaintText(
        canvas,
        data.topTracksTitle,
        Offset(margin, y),
        style(40, palette.artist, weight: FontWeight.w700),
        contentWidth,
      );
      y += 12;
      for (final (index, track) in topTracks.indexed) {
        y += posterPaintText(
          canvas,
          '${index + 1}  $track',
          Offset(margin, y),
          style(38, palette.lyrics),
          contentWidth,
        );
        y += 10;
      }
      y += 36;
    }

    final topArtists = data.topArtists.take(5).toList(growable: false);
    if (topArtists.isNotEmpty) {
      y += posterPaintText(
        canvas,
        data.topArtistsTitle,
        Offset(margin, y),
        style(40, palette.artist, weight: FontWeight.w700),
        contentWidth,
      );
      y += 12;
      for (final (index, artist) in topArtists.indexed) {
        y += posterPaintText(
          canvas,
          '${index + 1}  $artist',
          Offset(margin, y),
          style(34, palette.lyrics),
          contentWidth,
        );
        y += 8;
      }
      y += 30;
    }

    final platform = data.platformLabel?.trim() ?? '';
    if (platform.isNotEmpty) {
      posterPaintText(
        canvas,
        platform,
        Offset(margin, y),
        style(28, palette.extended),
        contentWidth,
      );
    }

    posterPaintText(
      canvas,
      watermarkText,
      Offset(margin, height - margin - 40),
      style(28, palette.watermark),
      contentWidth,
    );

    return posterEncodePng(
      recorder,
      width: kListeningStatsPosterWidth,
      height: kListeningStatsPosterHeight,
    );
  }
}
