/// 歌词获取结果
///
/// 封装歌词文本与来源信息；[translation] / [roma] 为可选扩展行（LRC 或纯文本），
/// 缺失表示该来源没有对应内容。
class LyricsResult {
  /// 歌词文本（LRC 格式或纯文本）
  final String lyric;

  /// 翻译歌词（可选）
  final String? translation;

  /// 罗马音歌词（可选）
  final String? roma;

  /// 歌词提供者名称：'netease', 'qq', 'lrclib'
  final String provider;

  const LyricsResult({
    required this.lyric,
    this.translation,
    this.roma,
    required this.provider,
  });

  @override
  String toString() =>
      'LyricsResult(provider: $provider, lyric: ${lyric.length} chars, '
      'translation: ${translation?.length ?? 0} chars, '
      'roma: ${roma?.length ?? 0} chars)';
}
