/// LLM 推荐 JSON 的容错解析。
///
/// 首选严格 `jsonDecode`；失败后只做结构恢复（代码围栏、前后说明、裸数组、
/// 常见包装键、尾逗号、截断后的完整对象），**不从纯文本里猜测歌曲**。
library;

import 'dart:convert';

import '../../domain/models/ai_dj.dart';
import 'ai_text.dart';

/// 一次解析结果：推荐列表 + 是否走了容错路径（诊断用）。
class AiRecommendationParseResult {
  const AiRecommendationParseResult({
    required this.recommendations,
    this.recovered = false,
    this.truncated = false,
  });

  static const AiRecommendationParseResult empty = AiRecommendationParseResult(
    recommendations: [],
  );

  final List<AiRecommendation> recommendations;

  /// 是否使用了代码围栏剥离 / 修复 / 截断对象抢救。
  final bool recovered;

  /// 是否检测到顶层 JSON 没有闭合（通常是输出被截断）。
  final bool truncated;
}

/// 解析 LLM 返回的推荐 JSON；[limit] 为最多接受的歌曲数。
AiRecommendationParseResult parseAiRecommendations(
  String content, {
  int limit = 20,
}) {
  if (limit <= 0) return AiRecommendationParseResult.empty;
  final text = _stripBom(content).trim();
  if (text.isEmpty) return AiRecommendationParseResult.empty;

  // 有些兼容实现会把整个 JSON 再包一层 JSON 字符串。
  final nestedText = _decodeJsonString(text);
  if (nestedText != null && nestedText.trim() != text) {
    final nested = parseAiRecommendations(nestedText, limit: limit);
    if (nested.recommendations.isNotEmpty) {
      return AiRecommendationParseResult(
        recommendations: nested.recommendations,
        recovered: true,
        truncated: nested.truncated,
      );
    }
  }

  final candidate = _extractJson(text);
  if (candidate == null) return AiRecommendationParseResult.empty;

  final direct = _decodeSongs(candidate.text, limit);
  if (direct.isNotEmpty) {
    return AiRecommendationParseResult(
      recommendations: direct,
      recovered: candidate.text != text,
      truncated: !candidate.complete,
    );
  }

  final repaired = _repairJson(candidate.text);
  if (repaired != candidate.text) {
    final songs = _decodeSongs(repaired, limit);
    if (songs.isNotEmpty) {
      return AiRecommendationParseResult(
        recommendations: songs,
        recovered: true,
        truncated: !candidate.complete,
      );
    }
  }

  final salvaged = _salvageSongs(candidate.text, limit);
  if (salvaged.isNotEmpty) {
    return AiRecommendationParseResult(
      recommendations: salvaged,
      recovered: true,
      truncated: !candidate.complete,
    );
  }
  return AiRecommendationParseResult(
    recommendations: const [],
    recovered: candidate.text != text || repaired != candidate.text,
    truncated: !candidate.complete,
  );
}

String _stripBom(String value) {
  var text = value;
  while (text.startsWith('\uFEFF')) {
    text = text.substring(1);
  }
  return text;
}

String? _decodeJsonString(String text) {
  if (!text.startsWith('"')) return null;
  try {
    final decoded = jsonDecode(text);
    return decoded is String ? decoded : null;
  } catch (_) {
    return null;
  }
}

class _Candidate {
  const _Candidate(this.text, {required this.complete});

  final String text;
  final bool complete;
}

/// 取出第一段 JSON：剥代码围栏、跳过前后说明；未闭合时返回剩余全文。
_Candidate? _extractJson(String text) {
  var source = text;
  final fence = RegExp(r'```(?:json|JSON)?\s*([\s\S]*?)```').firstMatch(source);
  if (fence != null) {
    source = fence.group(1)!.trim();
  }
  final start = _firstJsonStart(source);
  if (start < 0) return null;
  source = source.substring(start);
  final end = _balancedEnd(source);
  if (end == null) return _Candidate(source, complete: false);
  return _Candidate(source.substring(0, end), complete: true);
}

int _firstJsonStart(String text) {
  final object = text.indexOf('{');
  final array = text.indexOf('[');
  if (object < 0) return array;
  if (array < 0) return object;
  return object < array ? object : array;
}

/// 从字符串开头扫描到匹配的 `}` / `]`；忽略字符串内的括号。
int? _balancedEnd(String text) {
  if (text.isEmpty) return null;
  final first = text[0];
  if (first != '{' && first != '[') return null;
  final stack = <String>[];
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{' || ch == '[') {
      stack.add(ch);
    } else if (ch == '}' || ch == ']') {
      if (stack.isEmpty) return null;
      final expected = ch == '}' ? '{' : '[';
      if (stack.removeLast() != expected) return null;
      if (stack.isEmpty) return i + 1;
    }
  }
  return null;
}

List<AiRecommendation> _decodeSongs(String text, int limit) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const [];
  }
  // 有些兼容实现会把 JSON 再包一层字符串。
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {
      return const [];
    }
  }
  return _songsFrom(decoded, limit);
}

List<AiRecommendation> _songsFrom(dynamic value, int limit) {
  final result = <AiRecommendation>[];
  final seen = <String>{};

  void add(AiRecommendation? song) {
    if (song == null || result.length >= limit) return;
    final key = aiTrackKey(song.title, song.artist);
    if (seen.add(key)) result.add(song);
  }

  void visit(dynamic node, int depth) {
    if (node == null || result.length >= limit || depth > 4) return;
    if (node is List) {
      for (final entry in node) {
        if (entry is Map) add(_recommendationFromMap(entry));
      }
      return;
    }
    if (node is! Map) return;

    var wrapped = false;
    for (final key in const [
      'songs',
      'recommendations',
      'tracks',
      'items',
      'data',
      'result',
      'playlist',
      'list',
    ]) {
      if (node.containsKey(key)) {
        wrapped = true;
        visit(node[key], depth + 1);
      }
    }
    if (wrapped) return;

    final direct = _recommendationFromMap(node);
    if (direct != null) {
      add(direct);
      return;
    }
    // `{"0": {...}, "1": {...}}` 这类按序号包一层的实现。
    for (final entry in node.values) {
      if (entry is Map && _recommendationFromMap(entry) != null) {
        visit(entry, depth + 1);
      }
    }
  }

  visit(value, 0);
  return result;
}

AiRecommendation? _recommendationFromMap(Map map) {
  final title = _stringValue(
    _firstValue(map, const [
      'title',
      'name',
      'song',
      'track',
      'songName',
      'song_name',
    ]),
  );
  if (title == null) return null;
  final artist = _artistValue(
    _firstValue(map, const [
      'artist',
      'artists',
      'singer',
      'performer',
      'artistName',
      'artist_name',
    ]),
  );
  final reason =
      _stringValue(
        _firstValue(map, const ['reason', 'why', 'note', 'comment']),
      ) ??
      '';
  return AiRecommendation(title: title, artist: artist, reason: reason);
}

Object? _firstValue(Map map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value != null) return value;
  }
  return null;
}

String? _stringValue(Object? value) {
  if (value is String) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }
  if (value is num) return value.toString();
  if (value is Map) {
    return _stringValue(value['name'] ?? value['title']);
  }
  return null;
}

String _artistValue(Object? value) {
  if (value is List) {
    final names = <String>[];
    for (final entry in value) {
      final name = _stringValue(entry);
      if (name != null) names.add(name);
    }
    return names.join('、');
  }
  return _stringValue(value) ?? '';
}

/// 常见模型手误：尾逗号、中文引号、截断后缺闭合括号。
String _repairJson(String text) {
  var result = _removeTrailingCommas(text);
  result = result.replaceAll('“', '"').replaceAll('”', '"');
  result = _closeOpenStructures(result);
  return result;
}

String _removeTrailingCommas(String text) {
  final buffer = StringBuffer();
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      buffer.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
      buffer.write(ch);
      continue;
    }
    if (ch == ',') {
      var next = i + 1;
      while (next < text.length && _isWhitespace(text[next])) {
        next++;
      }
      if (next < text.length && (text[next] == '}' || text[next] == ']')) {
        continue;
      }
    }
    buffer.write(ch);
  }
  return buffer.toString();
}

String _closeOpenStructures(String text) {
  final stack = <String>[];
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{' || ch == '[') {
      stack.add(ch);
    } else if (ch == '}' || ch == ']') {
      if (stack.isNotEmpty) stack.removeLast();
    }
  }
  var result = text;
  if (inString) {
    if (result.endsWith('\\')) {
      result = result.substring(0, result.length - 1);
    }
    result += '"';
  }
  result = result.trimRight();
  if (result.endsWith(',')) {
    result = result.substring(0, result.length - 1);
  }
  for (var i = stack.length - 1; i >= 0; i--) {
    result += stack[i] == '{' ? '}' : ']';
  }
  return result;
}

/// 截断 / 外层损坏时，逐段扫描完整对象抢救歌曲。
List<AiRecommendation> _salvageSongs(String text, int limit) {
  final result = <AiRecommendation>[];
  final seen = <String>{};

  void collect(String source) {
    for (
      var start = source.indexOf('{');
      start >= 0 && result.length < limit;
      start = source.indexOf('{', start + 1)
    ) {
      final end = _balancedEnd(source.substring(start));
      if (end == null) continue;
      final fragment = source.substring(start, start + end);
      for (final song in _decodeSongs(fragment, limit - result.length)) {
        final key = aiTrackKey(song.title, song.artist);
        if (seen.add(key)) result.add(song);
        if (result.length >= limit) break;
      }
    }
  }

  collect(text);
  if (result.isEmpty) collect(_repairJson(text));
  return result;
}

bool _isWhitespace(String ch) =>
    ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
