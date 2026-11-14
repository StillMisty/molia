/// 搜索辅助的瞬态状态：焦点、建议高亮与可见性规则。
///
/// 两个搜索宿主（Ctrl+F 遮罩 / 资料库搜索 tab）共用同一份控制器与呈现模块：
/// 宿主只把焦点与布局差异告诉本类，选择任何候选都经 [SearchProvider] 的显式
/// 提交命令，从而复用唯一的记录策略（输入防抖永不记录）。
library;

import 'package:flutter/foundation.dart';

import '../domain/models/catalog.dart' show SearchKind;
import '../domain/search/search_assist.dart';
import 'search_provider.dart';

/// 搜索辅助块的一次投影。
@immutable
class SearchAssistViewModel {
  const SearchAssistViewModel({
    required this.query,
    required this.focused,
    required this.chips,
    required this.suggestions,
    required this.highlightedIndex,
    required this.correction,
    required this.showChips,
    required this.showSuggestions,
  });

  static const SearchAssistViewModel empty = SearchAssistViewModel(
    query: '',
    focused: false,
    chips: SearchAssistChips.empty,
    suggestions: [],
    highlightedIndex: -1,
    correction: null,
    showChips: false,
    showSuggestions: false,
  );

  final String query;
  final bool focused;
  final SearchAssistChips chips;
  final List<SearchSuggestion> suggestions;
  final int highlightedIndex;

  /// 零结果时的纠错候选（只提示，不自动改写输入）。
  final String? correction;

  final bool showChips;
  final bool showSuggestions;

  bool get isVisible => showChips || showSuggestions;

  SearchSuggestion? get highlightedSuggestion {
    if (highlightedIndex < 0 || highlightedIndex >= suggestions.length) {
      return null;
    }
    return suggestions[highlightedIndex];
  }
}

class SearchAssistController extends ChangeNotifier {
  SearchAssistController({
    required SearchProvider search,
    required List<String> Function() hotKeywords,
  }) : // 公开参数名保持 search / hotKeywords，字段按本类惯例私有。
       // ignore: prefer_initializing_formals
       _search = search,
       // ignore: prefer_initializing_formals
       _hotKeywords = hotKeywords {
    _search.session.addListener(_onChanged);
    _recompute();
  }

  final SearchProvider _search;
  final List<String> Function() _hotKeywords;

  bool _focused = false;
  int _highlightedIndex = -1;
  String _lastSignature = '';
  SearchAssistViewModel _value = SearchAssistViewModel.empty;

  SearchAssistViewModel get value => _value;

  /// 宿主输入框焦点变化：只有聚焦时才出现热搜 / 建议。
  void setFocused(bool value) {
    if (_focused == value) return;
    _focused = value;
    _recompute();
  }

  /// ↑ / ↓：仅在建议可见时移动高亮（-1 = 未选中）。
  void moveHighlight(int delta) {
    final suggestions = _value.suggestions;
    if (!_value.showSuggestions || suggestions.isEmpty) return;
    var index = _highlightedIndex;
    if (index < 0) {
      index = delta > 0 ? -1 : suggestions.length;
    }
    final next = (index + delta).clamp(0, suggestions.length - 1);
    if (next == _highlightedIndex) return;
    _highlightedIndex = next;
    _recompute(keepHighlight: true);
  }

  /// Enter：高亮存在时提交高亮项；否则 no-op（由宿主保留原行为）。
  bool selectHighlighted() {
    final suggestion = _value.highlightedSuggestion;
    if (suggestion == null) return false;
    selectSuggestion(suggestion);
    return true;
  }

  /// 选中一条建议：立即按当前渠道搜索。
  void selectSuggestion(SearchSuggestion suggestion) {
    _search.submitSearch(suggestion.text);
  }

  /// 采用零结果纠错候选：与显式提交同一条路径。
  void acceptCorrection() {
    final correction = _value.correction;
    if (correction == null) return;
    _search.submitSearch(correction);
  }

  void _onChanged() => _recompute();

  void _recompute({bool keepHighlight = false}) {
    final session = _search.session;
    final query = session.query;
    final trimmed = query.trim();
    final channelKey = session.activeSourceKey;
    final hot = _hotKeywords();

    final chips = trimmed.isEmpty
        ? buildSearchAssistChips(hotKeywords: hot)
        : SearchAssistChips.empty;
    final suggestions = trimmed.isEmpty
        ? const <SearchSuggestion>[]
        : rankSearchSuggestions(query: trimmed, hotKeywords: hot);

    final showChips = _focused && trimmed.isEmpty && !chips.isEmpty;
    // 当前类型还没有成功首屏时显示建议；结果一到达就让位给结果面。
    final showSuggestions =
        _focused && trimmed.isNotEmpty && session.currentResults.page == 0;

    final correction = _correctionFor(session, trimmed, hot);

    final signature = [
      channelKey,
      query,
      for (final suggestion in suggestions) suggestion.text,
    ].join('\u0000');
    final listChanged = signature != _lastSignature;
    _lastSignature = signature;
    if (listChanged && !keepHighlight) {
      _highlightedIndex = -1;
    }
    if (_highlightedIndex >= suggestions.length) _highlightedIndex = -1;
    if (!showSuggestions) _highlightedIndex = -1;

    _value = SearchAssistViewModel(
      query: query,
      focused: _focused,
      chips: chips,
      suggestions: showSuggestions ? suggestions : const [],
      highlightedIndex: _highlightedIndex,
      correction: correction,
      showChips: showChips,
      showSuggestions: showSuggestions && suggestions.isNotEmpty,
    );
    notifyListeners();
  }

  /// 纠错只在「成功的单曲搜索首屏、零结果」时出现。
  String? _correctionFor(
    SearchSession session,
    String trimmed,
    List<String> hot,
  ) {
    if (session.kind != SearchKind.song) return null;
    if (trimmed.isEmpty) return null;
    final results = session.currentResults;
    if (results.failure != null ||
        results.page <= 0 ||
        results.items.isNotEmpty) {
      return null;
    }
    if (session.isBusy) return null;
    return rankTypoCorrection(query: trimmed, hotKeywords: hot);
  }

  @override
  void dispose() {
    _search.session.removeListener(_onChanged);
    super.dispose();
  }
}
