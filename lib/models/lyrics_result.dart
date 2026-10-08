/// 歌词获取结果
///
/// 封装歌词文本与来源信息
class LyricsResult {
  /// 歌词文本（LRC 格式或纯文本）
  final String lyric;

  /// 歌词提供者名称：'netease', 'qq', 'lrclib'
  final String provider;

  const LyricsResult({
    required this.lyric,
    required this.provider,
  });

  @override
  String toString() =>
      'LyricsResult(provider: $provider, lyric: ${lyric.length} chars)';
}
