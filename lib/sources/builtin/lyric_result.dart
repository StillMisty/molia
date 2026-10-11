/// builtin 平台原生取词的统一结果（对照 LX `lyric.js` 返回的 `info`）。
///
/// - [lyric]：原文 LRC（行级，`[mm:ss.xxx]` 标签）；
/// - [tlyric] / [rlyric]：翻译 / 罗马音（可选，通常已按原文时间轴对齐）；
/// - [lxlyric]：逐字歌词（LX 扩展格式 `<相对开始ms,时长ms>`），可选。
class BuiltinLyricResult {
  final String lyric;
  final String? tlyric;
  final String? rlyric;
  final String? lxlyric;

  const BuiltinLyricResult({
    required this.lyric,
    this.tlyric,
    this.rlyric,
    this.lxlyric,
  });

  bool get isEmpty => lyric.trim().isEmpty;
}

/// 毫秒 → `[mm:ss.mmm]`（LX 各平台 `msFormat` 的通用形态）。
String msFormat(int timeMs) {
  final ms = (timeMs % 1000).toString().padLeft(3, '0');
  var time = timeMs / 1000;
  final m = (time / 60).floor().toString().padLeft(2, '0');
  time %= 60;
  final s = time.floor().toString().padLeft(2, '0');
  return '[$m:$s.$ms]';
}
