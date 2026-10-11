import 'package:material_ui/material_ui.dart';

/// 歌词海报配色：单一角色映射（来源 scheme → 六个绘制色）。
///
/// 四套预设样式已移除：海报的取色来源（应用主题 / 封面 / 自定义色）由
/// 生成前的解析决定，本类只负责把方案映射为绘制角色，保证对比度成对。
/// 底色用 `primaryContainer` 观感更「海报」，正文一律容器前景色。
@immutable
class PosterPalette {
  const PosterPalette({
    required this.background,
    required this.title,
    required this.artist,
    required this.lyrics,
    required this.watermark,
    required this.separator,
  });

  /// 按方案派生：底色 + 容器前景 + 强调歌手名。
  factory PosterPalette.fromScheme(ColorScheme scheme) => PosterPalette(
        background: scheme.primaryContainer,
        title: scheme.onPrimaryContainer,
        artist: scheme.primary,
        lyrics: scheme.onPrimaryContainer,
        watermark: scheme.onPrimaryContainer,
        separator: scheme.outline.withValues(alpha: 0.3),
      );

  /// 海报底色。
  final Color background;

  /// 标题。
  final Color title;

  /// 歌手名（强调色）。
  final Color artist;

  /// 歌词正文。
  final Color lyrics;

  /// 底部水印（图标 + 品牌名）。
  final Color watermark;

  /// 分隔线（当前版本预留，canvas 层未使用）。
  final Color separator;
}
