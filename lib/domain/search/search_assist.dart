/// 搜索辅助的纯逻辑：热搜建议排序与零结果纠错。
///
/// 不依赖 Flutter / provider / 网络 / 日志：输入是用户输入与已缓存的热搜词，
/// 输出是确定性的候选列表。宿主只负责把结果渲染成 chips / 行，并显式提交
/// 用户选中的一项；本模块从不改写输入。
library;

/// 一条搜索建议。
class SearchSuggestion {
  const SearchSuggestion({required this.text});

  /// 建议文本（保留来源里的原始大小写）。
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SearchSuggestion && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'SearchSuggestion($text)';
}

/// 空关键词时的热搜芯片：最多显示 6 条。
class SearchAssistChips {
  const SearchAssistChips({required this.hot});

  static const SearchAssistChips empty = SearchAssistChips(hot: []);

  /// 热搜词。
  final List<String> hot;

  bool get isEmpty => hot.isEmpty;
}

/// 建议列表上限：面板永远不超过 6 行。
const int kSearchAssistMaxItems = 6;

/// 小写 + 去首尾空白 + 合并连续空白（中文不受影响）。
String normalizeSearchAssistText(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

int _tierOf(String candidate, String query) {
  if (candidate == query) return 0;
  if (candidate.startsWith(query)) return 1;
  if (candidate.contains(query)) return 2;
  return -1;
}

/// 空关键词芯片：热搜词去重后最多 6 条。
SearchAssistChips buildSearchAssistChips({required List<String> hotKeywords}) {
  final hot = <String>[];
  final seen = <String>{};
  for (final value in hotKeywords) {
    if (hot.length >= kSearchAssistMaxItems) break;
    final normalized = normalizeSearchAssistText(value);
    if (normalized.isEmpty || !seen.add(normalized)) continue;
    hot.add(value.trim());
  }
  return SearchAssistChips(hot: List.unmodifiable(hot));
}

/// 输入过程中的建议：精确 → 前缀 → 包含。
///
/// 返回最多 [limit] 条（默认 6），去重按规范化文本。同步、无网络、无日志、
/// 无 Flutter 依赖。
List<SearchSuggestion> rankSearchSuggestions({
  required String query,
  required List<String> hotKeywords,
  int limit = kSearchAssistMaxItems,
}) {
  final normalizedQuery = normalizeSearchAssistText(query);
  if (normalizedQuery.isEmpty || limit <= 0) return const [];

  final seen = <String>{};
  final ranked = <({SearchSuggestion suggestion, int tier, int order})>[];
  for (var index = 0; index < hotKeywords.length; index++) {
    final raw = hotKeywords[index];
    final normalized = normalizeSearchAssistText(raw);
    if (normalized.isEmpty || !seen.add(normalized)) continue;
    final tier = _tierOf(normalized, normalizedQuery);
    if (tier < 0) continue;
    ranked.add((
      suggestion: SearchSuggestion(text: raw.trim()),
      tier: tier,
      order: index,
    ));
  }
  ranked.sort((a, b) {
    final byTier = a.tier.compareTo(b.tier);
    if (byTier != 0) return byTier;
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
/// 距离超过较长串长度的 40%、以及单字符查询都不采用。并列按距离 → 来源顺序
/// → 候选长度 → 码元顺序确定。
String? rankTypoCorrection({
  required String query,
  required List<String> hotKeywords,
}) {
  final normalizedQuery = normalizeSearchAssistText(query);
  final queryRunes = normalizedQuery.runes.length;
  if (queryRunes <= 1) return null;
  final budget = queryRunes <= 4 ? 1 : 2;

  final seen = <String>{};
  final candidates = <({String text, int distance, int order, int runes})>[];
  for (var index = 0; index < hotKeywords.length; index++) {
    final raw = hotKeywords[index].trim();
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
      order: index,
      runes: candidateRunes,
    ));
  }

  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
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
