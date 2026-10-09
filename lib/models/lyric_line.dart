/// 一行歌词（时间戳 + 文本）。不可变：选中态属于 UI，不放进模型。
class LyricLine {
  const LyricLine(this.timestamp, this.text);

  final Duration timestamp;
  final String text;
}

/// 统一的 LRC 时间标签正则（解析与「是否有时间轴」判断共用同一契约）。
///
/// 允许 1–3 位分钟（`[1:02.34]` 与 `[01:02.345]` 都算），
/// 秒后分隔符 `.` 或 `:`；不再要求标签必须位于行首。
final RegExp lrcTimeTagRegex =
    RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{2,3}))?\]');

/// 是否含至少一个 LRC 时间标签（与 [parseLyrics] 同一正则，不会互相漂移）。
bool hasLyricTimestamps(String rawLyrics) =>
    lrcTimeTagRegex.hasMatch(rawLyrics);

/// 解析 LRC：时间标签（1–3 位分钟 + 2/3 位毫秒）+ 常见 HTML 实体解码；
/// 无时间标签 / 文本为空的行忽略，单行解析失败不影响其余行。
List<LyricLine> parseLyrics(String rawLyrics) {
  final result = <LyricLine>[];
  for (final line in rawLyrics.split('\n')) {
    final match = lrcTimeTagRegex.firstMatch(line);
    if (match == null) continue;
    try {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final millisecondsStr = match.group(3);
      var milliseconds = 0;
      if (millisecondsStr != null) {
        // 2 位为厘秒（×10），3 位为毫秒。
        milliseconds = millisecondsStr.length == 2
            ? int.parse(millisecondsStr) * 10
            : int.parse(millisecondsStr);
      }

      // 一行可能带多个时间标签（同一句重复时间轴）：全部剥离后取文本。
      final text = _decodeEntities(line.replaceAll(lrcTimeTagRegex, '').trim());
      if (text.isEmpty) continue;
      result.add(LyricLine(
        Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        ),
        text,
      ));
    } catch (_) {
      // 单行解析失败：跳过该行。
    }
  }
  // 保险：按时间戳排序（二分查找当前行依赖有序）。
  result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return result;
}

/// 无时间戳歌词 → 每行一个伪时间戳（用于未同步歌词的展示与滚动）。
List<LyricLine> buildUnsyncedLyrics(String rawLyrics) {
  final lines = rawLyrics
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  return [
    for (var i = 0; i < lines.length; i++)
      LyricLine(Duration(milliseconds: i), lines[i]),
  ];
}

/// 把扩展歌词（翻译 / 罗马音）对齐到主行列表。
///
/// 返回与 [lines] 等长的文本列表：'' 表示该行没有对应扩展文本。
/// 扩展歌词按同一时间契约解析（带时间轴走 [parseLyrics]，纯文本走
/// [buildUnsyncedLyrics] 的伪时间戳）；同时间戳多条合并为一个字符串。
/// [rawExtended] 为空（或 [lines] 为空）时返回空列表，调用方按「无扩展行」处理。
List<String> alignExtendedLines(List<LyricLine> lines, String? rawExtended) {
  if (lines.isEmpty || rawExtended == null || rawExtended.trim().isEmpty) {
    return const [];
  }
  final parsed = hasLyricTimestamps(rawExtended)
      ? parseLyrics(rawExtended)
      : buildUnsyncedLyrics(rawExtended);
  if (parsed.isEmpty) return const [];

  final byTimestamp = <int, List<String>>{};
  for (final line in parsed) {
    byTimestamp
        .putIfAbsent(line.timestamp.inMilliseconds, () => [])
        .add(line.text);
  }
  return [
    for (final line in lines)
      byTimestamp[line.timestamp.inMilliseconds]?.join(' ') ?? '',
  ];
}

/// 当前行索引：最后一行 timestamp ≤ [position]；早于首行 / 无行返回 -1。
int lyricLineIndexAt(List<LyricLine> lines, Duration position) {
  if (lines.isEmpty) return -1;
  if (position < lines.first.timestamp) return -1;

  var low = 0;
  var high = lines.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (lines[mid].timestamp <= position) {
      final isLastMatch =
          mid == lines.length - 1 || lines[mid + 1].timestamp > position;
      if (isLastMatch) return mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return -1;
}

String _decodeEntities(String text) => text
    .replaceAll('&apos;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');
