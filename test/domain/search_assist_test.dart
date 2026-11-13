import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/search/search_assist.dart';

/// 搜索辅助纯逻辑：建议排序 / 空词芯片 / 纠错预算与确定性。
void main() {
  group('空关键词芯片', () {
    test('历史 4 条 + 热搜 2 条，两个来源都在时按此上限', () {
      final chips = buildSearchAssistChips(
        history: ['a', 'b', 'c', 'd', 'e', 'f'],
        hotKeywords: ['h1', 'h2', 'h3'],
      );
      expect(chips.recent, ['a', 'b', 'c', 'd']);
      expect(chips.hot, ['h1', 'h2']);
    });

    test('只有历史时填满 6 条；只有热搜时同理', () {
      final historyOnly = buildSearchAssistChips(
        history: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
        hotKeywords: const [],
      );
      expect(historyOnly.recent, ['a', 'b', 'c', 'd', 'e', 'f']);
      expect(historyOnly.hot, isEmpty);

      final hotOnly = buildSearchAssistChips(
        history: const [],
        hotKeywords: ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'h7'],
      );
      expect(hotOnly.recent, isEmpty);
      expect(hotOnly.hot, ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']);
    });

    test('跨来源去重时历史优先，空值被丢弃', () {
      final chips = buildSearchAssistChips(
        history: ['Hello', ' '],
        hotKeywords: ['hello', 'World'],
      );
      expect(chips.recent, ['Hello']);
      expect(chips.hot, ['World']);
    });
  });

  group('输入建议', () {
    test('精确 → 前缀 → 包含；同层级历史优先', () {
      final suggestions = rankSearchSuggestions(
        query: 'love',
        history: ['lovely', 'love', 'beloved'],
        hotKeywords: ['lover', 'love story'],
      );
      expect(suggestions.map((entry) => entry.text), [
        'love',
        'lovely',
        'lover',
        'love story',
        'beloved',
      ]);
    });

    test('历史与热搜重复时保留历史条目', () {
      final suggestions = rankSearchSuggestions(
        query: '歌',
        history: ['歌手'],
        hotKeywords: ['歌手', '歌曲'],
      );
      expect(suggestions.map((entry) => entry.text), ['歌手', '歌曲']);
      expect(suggestions.first.source, SearchSuggestionSource.history);
    });

    test('最多 6 条，大小写与空白规范化后匹配', () {
      final suggestions = rankSearchSuggestions(
        query: '  HELLO   world ',
        history: ['hello world', 'Hello World 2', 'nope'],
        hotKeywords: ['hello world', 'HELLO WORLD 3'],
      );
      expect(suggestions, hasLength(3));
      expect(suggestions.first.text, 'hello world');
    });

    test('中文、中英混合与稳定排序', () {
      final first = rankSearchSuggestions(
        query: '周杰',
        history: ['周杰伦', '周杰伦 晴天', '林俊杰'],
        hotKeywords: ['周杰伦'],
      );
      final second = rankSearchSuggestions(
        query: '周杰',
        history: ['周杰伦', '周杰伦 晴天', '林俊杰'],
        hotKeywords: ['周杰伦'],
      );
      expect(first.map((entry) => entry.text), ['周杰伦', '周杰伦 晴天']);
      expect(first, second);
    });

    test('空查询不产生输入建议', () {
      expect(
        rankSearchSuggestions(query: '   ', history: ['a'], hotKeywords: ['b']),
        isEmpty,
      );
    });
  });

  group('零结果纠错', () {
    test('单字符查询不纠错', () {
      expect(
        rankTypoCorrection(query: 'a', history: ['ab'], hotKeywords: const []),
        isNull,
      );
    });

    test('短查询 1 次编辑；长查询 2 次编辑', () {
      expect(
        rankTypoCorrection(
          query: 'qing',
          history: ['qin'],
          hotKeywords: const [],
        ),
        'qin',
        reason: '4 字查询允许 1 次编辑',
      );
      expect(
        rankTypoCorrection(
          query: 'qing',
          history: ['qingtian'],
          hotKeywords: const [],
        ),
        isNull,
        reason: '长度差超过预算',
      );
      expect(
        rankTypoCorrection(
          query: '晴天之歌啊',
          history: ['晴天之夜吧'],
          hotKeywords: const [],
        ),
        '晴天之夜吧',
        reason: '长查询允许 2 次编辑',
      );
    });

    test('英文与中文字符级替换 / 换位', () {
      expect(
        rankTypoCorrection(
          query: 'beautful',
          history: ['beautiful'],
          hotKeywords: const [],
        ),
        'beautiful',
      );
      expect(
        rankTypoCorrection(
          query: 'teh',
          history: ['the'],
          hotKeywords: const [],
        ),
        'the',
        reason: '相邻换位记 1 次编辑',
      );
      expect(
        rankTypoCorrection(
          query: '周杰仑',
          history: ['周杰伦'],
          hotKeywords: const [],
        ),
        '周杰伦',
      );
    });

    test('拒绝自身、拒绝过远候选、并列确定', () {
      expect(
        rankTypoCorrection(
          query: 'hello',
          history: ['hello'],
          hotKeywords: const [],
        ),
        isNull,
      );
      expect(
        rankTypoCorrection(
          query: 'hello',
          history: ['zzzzz'],
          hotKeywords: const [],
        ),
        isNull,
      );
      final first = rankTypoCorrection(
        query: 'hello',
        history: ['hallo', 'hullo'],
        hotKeywords: const [],
      );
      final second = rankTypoCorrection(
        query: 'hello',
        history: ['hallo', 'hullo'],
        hotKeywords: const [],
      );
      expect(first, 'hallo', reason: '同距离时按来源顺序稳定取第一条');
      expect(first, second);
    });
  });
}
