/// 汽水音乐原生歌词（`GET /luna/h5/seo_track?track_id=`）。
///
/// 匿名接口里唯一带歌词的端点：响应 `lyric.content` 是 KRC 原文
/// （`[行开始ms,行时长ms]<词相对ms,词时长ms,0>词...`）。
///
/// 输出两份：
/// - `lyric`：行级 LRC（`[mm:ss.mmm]原文`），供没有逐字渲染的出口；
/// - `lxlyric`：同一份 KRC 转成 LX 逐字格式（`<相对开始ms,时长ms>`），
///   歌词页的词级高亮直接用。
///
/// 平台不返回翻译 / 罗马音，二者留空。
library;

import 'lyric_result.dart';
import 'qs_api.dart';

class QsLyric {
  QsLyric._();

  /// KRC 行头：`[2260,3270]`。
  static final RegExp _lineTag = RegExp(r'^\[(\d+),(\d+)\]');

  /// KRC 词标签：`<0,350,0>`（第三个字段是 KRC 的保留位，LX 格式不要）。
  static final RegExp _wordTag = RegExp(r'<(\d+),(\d+),\d+>');

  static Future<BuiltinLyricResult?> fetch(Map<String, dynamic> raw) async {
    final trackId = raw['track_id']?.toString() ?? raw['id']?.toString() ?? '';
    if (trackId.isEmpty) return null;
    final response = await QsApi.getJson(
      '/luna/h5/seo_track',
      query: {'track_id': trackId},
    );
    if (response is! Map) return null;
    return parse(response['lyric']);
  }

  /// `lyric` 节点 → 统一歌词结果；空歌词返回 null（交给上层回退）。
  static BuiltinLyricResult? parse(Object? lyric) {
    if (lyric is! Map) return null;
    final content = lyric['content']?.toString() ?? '';
    if (content.trim().isEmpty) return null;
    return parseContent(content);
  }

  /// KRC 原文 → `lyric` + `lxlyric`。
  static BuiltinLyricResult? parseContent(String content) {
    final lyricLines = <String>[];
    final lxLines = <String>[];
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      final lineMatch = _lineTag.firstMatch(line);
      if (lineMatch == null) continue;
      final lineStart = int.parse(lineMatch.group(1)!);
      final rest = line.substring(lineMatch.end);
      final text = rest.replaceAll(_wordTag, '');
      if (text.trim().isEmpty) continue;
      final timestamp = msFormat(lineStart);
      lyricLines.add('$timestamp$text');
      final words = _wordSegments(rest);
      if (words != null) lxLines.add('$timestamp$words');
    }

    if (lyricLines.isEmpty) {
      // 结构变化时兜底：原样交给上层（至少不丢歌词）。
      return BuiltinLyricResult(lyric: content.trim());
    }
    return BuiltinLyricResult(
      lyric: lyricLines.join('\n'),
      lxlyric: lxLines.isEmpty ? null : lxLines.join('\n'),
    );
  }

  /// 一行里的词段 → `<相对开始ms,时长ms>词`；没有词标签返回 null。
  static String? _wordSegments(String lineText) {
    final matches = _wordTag.allMatches(lineText).toList();
    if (matches.isEmpty) return null;
    final buffer = StringBuffer();
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final start = int.parse(match.group(1)!);
      final duration = int.parse(match.group(2)!);
      final textEnd = index + 1 < matches.length
          ? matches[index + 1].start
          : lineText.length;
      final text = lineText.substring(match.end, textEnd);
      if (text.isEmpty) continue;
      buffer.write('<$start,$duration>$text');
    }
    return buffer.isEmpty ? null : buffer.toString();
  }
}
