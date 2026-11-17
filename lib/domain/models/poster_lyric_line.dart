/// 海报歌词行：主文本 + 与歌词页一致的扩展行（翻译 / 罗马音）。
///
/// 扩展行与主行同一份时间戳对齐结果（`LyricsState.translations/romas`），
/// 空串表示该行没有对应文本、不占位。
class PosterLyricLine {
  final String text;

  /// 翻译（空串 = 无 / 歌词页未开启翻译）。
  final String translation;

  /// 罗马音（空串 = 无 / 歌词页未开启罗马音）。
  final String roma;

  const PosterLyricLine({
    required this.text,
    this.translation = '',
    this.roma = '',
  });

  /// 是否有任一扩展行：绘制侧据此决定主行后的间距。
  bool get hasExtended => translation.isNotEmpty || roma.isNotEmpty;
}
