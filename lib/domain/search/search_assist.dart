/// 搜索辅助的纯逻辑：建议排序与零结果纠错。
///
/// 不依赖 Flutter / provider / 网络 / 日志：输入是用户输入、按渠道隔离的本地
/// 历史与已缓存的热搜词，输出是确定性的候选列表。宿主只负责把结果渲染成
/// chips / 行，并显式提交用户选中的一项；本模块从不改写输入。
library;

/// 建议来源：本地历史优先于平台热搜词（同层级排序用）。
enum SearchSuggestionSource { history, hot }

/// 一条搜索建议。
class SearchSuggestion {
  const SearchSuggestion({required this.text, required this.source});

  /// 建议文本（保留来源里的原始大小写）。
  final String text;

  final SearchSuggestionSource source;

  @override
  bool operator ==(Object other) =>
      other is SearchSuggestion && other.text == text && other.source == source;

  @override
  int get hashCode => Object.hash(text, source);

  @override
  String toString() => 'SearchSuggestion(${source.name}: $text)';
}

/// 空关键词时的芯片分组：最近搜索 + 热搜词，各自最多显示几条。
class SearchAssistChips {
  const SearchAssistChips({required this.recent, required this.hot});

  static const SearchAssistChips empty = SearchAssistChips(recent: [], hot: []);

  /// 最近搜索（最多 4 条；热搜词不存在时最多 6 条）。
  final List<String> recent;

  /// 热搜词（最多 2 条；历史不存在时最多 6 条）。
  final List<String> hot;

  bool get isEmpty => recent.isEmpty && hot.isEmpty;
}

/// 建议列表上限：面板永远不超过 6 行。
const int kSearchAssistMaxItems = 6;

/// 空关键词芯片上限：历史最多 4 条 + 热搜词最多 2 条。
const int kSearchAssistMaxRecentChips = 4;
const int kSearchAssistMaxHotChips = 2;

/// 小写 + 去首尾空白 + 合并连续空白（中文不受影响）。
String normalizeSearchAssistText(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

int _tierOf(String candidate, String query) {
  if (candidate == query) return 0;
  if (candidate.startsWith(query)) return 1;
  if (candidate.contains(query)) return 2;
  return -1;
}

/// 空关键词芯片：两个来源都在时 `4 + 2`，只剩一个来源时最多填满 6 条。
SearchAssistChips buildSearchAssistChips({
  required List<String> history,
  required List<String> hotKeywords,
}) {
  final recent = <String>[];
  final hot = <String>[];
  final seen = <String>{};
  void add(String value, List<String> target) {
    final normalized = normalizeSearchAssistText(value);
    if (normalized.isEmpty || !seen.add(normalized)) return;
    target.add(value.trim());
  }

  if (history.isEmpty) {
    for (final value in hotKeywords) {
      if (hot.length >= kSearchAssistMaxItems) break;
      add(value, hot);
    }
    return SearchAssistChips(recent: const [], hot: List.unmodifiable(hot));
  }
  if (hotKeywords.isEmpty) {
    for (final value in history) {
      if (recent.length >= kSearchAssistMaxItems) break;
      add(value, recent);
    }
    return SearchAssistChips(recent: List.unmodifiable(recent), hot: const []);
  }
  for (final value in history) {
    if (recent.length >= kSearchAssistMaxRecentChips) break;
    add(value, recent);
  }
  for (final value in hotKeywords) {
    if (hot.length >= kSearchAssistMaxHotChips) break;
    // 历史已经展示的同词不再进热搜行（历史优先）。
    add(value, hot);
  }
  return SearchAssistChips(
    recent: List.unmodifiable(recent),
    hot: List.unmodifiable(hot),
  );
}

/// 输入过程中的建议：精确 → 前缀 → 包含；同层级历史优先于热搜词。
///
/// 返回最多 [limit] 条（默认 6），去重按规范化文本（保留历史条目的写法）。
/// 同步、无网络、无日志、无 Flutter 依赖。
List<SearchSuggestion> rankSearchSuggestions({
  required String query,
  required List<String> history,
  required List<String> hotKeywords,
  int limit = kSearchAssistMaxItems,
}) {
  final normalizedQuery = normalizeSearchAssistText(query);
  if (normalizedQuery.isEmpty || limit <= 0) return const [];

  final seen = <String>{};
  final ranked =
      <({SearchSuggestion suggestion, int tier, int priority, int order})>[];
  void collect(
    List<String> values,
    SearchSuggestionSource source,
    int priority,
  ) {
    for (var index = 0; index < values.length; index++) {
      final raw = values[index];
      final normalized = normalizeSearchAssistText(raw);
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      final tier = _tierOf(normalized, normalizedQuery);
      if (tier < 0) continue;
      ranked.add((
        suggestion: SearchSuggestion(text: raw.trim(), source: source),
        tier: tier,
        priority: priority,
        order: index,
      ));
    }
  }

  collect(history, SearchSuggestionSource.history, 0);
  collect(hotKeywords, SearchSuggestionSource.hot, 1);
  ranked.sort((a, b) {
    final byTier = a.tier.compareTo(b.tier);
    if (byTier != 0) return byTier;
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    return a.order.compareTo(b.order);
  });
  return List.unmodifiable([
    for (final entry in ranked.take(limit)) entry.suggestion,
  ]);
}

/// Damerau-Levenshtein 距离（相邻换位记 1 次编辑），按 Unicode 码点比较。
///
/// 超过 [maxDistance] 时返回 null（调用方按「不采用」处理）；用于纠错候选的
/// 预算判定，不追求通用编辑距离接口。
int? boundedDamerauLevenshtein(
  String source,
  String target, {
  required int maxDistance,
}) {
  final a = source.runes.toList(growable: false);
  final b = target.runes.toList(growable: false);
  if ((a.length - b.length).abs() > maxDistance) return null;
  final rows = a.length + 1;
  final cols = b.length + 1;
  final matrix = List.generate(rows, (_) => List<int>.filled(cols, 0));
  for (var i = 0; i < rows; i++) {
    matrix[i][0] = i;
  }
  for (var j = 0; j < cols; j++) {
    matrix[0][j] = j;
  }
  for (var i = 1; i < rows; i++) {
    for (var j = 1; j < cols; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var value = _min3(
        matrix[i - 1][j] + 1,
        matrix[i][j - 1] + 1,
        matrix[i - 1][j - 1] + cost,
      );
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
        final transposed = matrix[i - 2][j - 2] + 1;
        if (transposed < value) value = transposed;
      }
      matrix[i][j] = value;
    }
  }
  final distance = matrix[a.length][b.length];
  return distance <= maxDistance ? distance : null;
}

int _min3(int a, int b, int c) {
  final min = a < b ? a : b;
  return min < c ? min : c;
}

/// 零结果纠错：只返回一个候选，绝不自动改写输入。
///
/// 预算：查询 ≤4 个码点时允许 1 次编辑，否则 2 次；候选与查询等长差超过预算、
/// 距离超过较长串长度的 40%、以及单字符查询都不采用。并列按
/// 来源（历史优先）→ 距离 → 来源顺序 → 候选长度 → 码元顺序确定。
String? rankTypoCorrection({
  required String query,
  required List<String> history,
  required List<String> hotKeywords,
}) {
  final normalizedQuery = normalizeSearchAssistText(query);
  final queryRunes = normalizedQuery.runes.length;
  if (queryRunes <= 1) return null;
  final budget = queryRunes <= 4 ? 1 : 2;

  final seen = <String>{};
  final candidates =
      <({String text, int distance, int priority, int order, int runes})>[];
  void collect(List<String> values, int priority) {
    for (var index = 0; index < values.length; index++) {
      final raw = values[index].trim();
      final normalized = normalizeSearchAssistText(raw);
      if (normalized.isEmpty || normalized == normalizedQuery) continue;
      if (!seen.add(normalized)) continue;
      final candidateRunes = normalized.runes.length;
      if ((candidateRunes - queryRunes).abs() > budget) continue;
      final distance = boundedDamerauLevenshtein(
        normalizedQuery,
        normalized,
        maxDistance: budget,
      );
      if (distance == null) continue;
      final longer = candidateRunes > queryRunes ? candidateRunes : queryRunes;
      // 40% 是「看起来像同一个词」的上限；整数比较避免浮点误差。
      if (distance * 10 > longer * 4) continue;
      candidates.add((
        text: raw,
        distance: distance,
        priority: priority,
        order: index,
        runes: candidateRunes,
      ));
    }
  }

  collect(history, 0);
  collect(hotKeywords, 1);
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    final byDistance = a.distance.compareTo(b.distance);
    if (byDistance != 0) return byDistance;
    final byOrder = a.order.compareTo(b.order);
    if (byOrder != 0) return byOrder;
    final byLength = a.runes.compareTo(b.runes);
    if (byLength != 0) return byLength;
    return a.text.compareTo(b.text);
  });
  return candidates.first.text;
}
