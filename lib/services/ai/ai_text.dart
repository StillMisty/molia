/// AI 推歌文本工具：曲名/艺人规范化（匹配与去重共用）。
///
/// 规范化只用于**比较**，不改变展示与入库的原始文本：
/// - 大小写、全角/半角统一；
/// - 去掉括号内容（`(live)` / `【remix】` 等版本后缀）与空白、常见标点。
library;

/// 规范化曲名/艺人文本。
String normalizeAiText(String value) {
  final lowered = value.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lowered.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      // 全角 ASCII → 半角。
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  var text = buffer.toString();
  // 括号内容（版本/feat 后缀）。
  text = text.replaceAll(RegExp(r'[\(\[（【][^\)\]）】]*[\)\]）】]'), '');
  text = text.replaceAll(RegExp(r'\s+'), '');
  text = text.replaceAll(RegExp('''[-–—·,，.。!！?？'"“”‘’~〜]'''), '');
  return text;
}

/// 曲目去重/排除键：`规范化(title)|规范化(artist)`。
String aiTrackKey(String title, String artist) =>
    '${normalizeAiText(title)}|${normalizeAiText(artist)}';
