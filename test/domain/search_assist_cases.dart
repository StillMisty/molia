import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/search/search_assist.dart';

/// 搜索辅助纯逻辑：热搜芯片 / 建议排序 / 纠错预算与确定性。
void main() {
  group('空关键词芯片', () {
    test('热搜去重后最多 6 条', () {
      final chips = buildSearchAssistChips(
        hotKeywords: ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'h7'],
      );
      expect(chips.hot, ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']);
    });

    test('大小写去重、空值被丢弃', () {
      final chips = buildSearchAssistChips(
        hotKeywords: ['Hello', ' ', 'hello', 'World'],
      );
      expect(chips.hot, ['Hello', 'World']);
    });
  });

  group('输入建议', () {
    test('精确 → 前缀 → 包含', () {
      final suggestions = rankSearchSuggestions(
        query: 'love',
        hotKeywords: ['lovely', 'love', 'beloved', 'lover', 'love story'],
      );
      expect(suggestions.map((entry) => entry.text), [
        'love',
        'lovely',
        'lover',
        'love story',
        'beloved',
      ]);
    });

    test('最多 6 条，大小写与空白规范化后匹配', () {
      final suggestions = rankSearchSuggestions(
        query: '  HELLO   world ',
        hotKeywords: ['hello world', 'Hello World 2', 'nope'],
      );
      expect(suggestions, hasLength(2));
      expect(suggestions.first.text, 'hello world');
    });

    test('中文、中英混合与稳定排序', () {
      final first = rankSearchSuggestions(
        query: '周杰',
        hotKeywords: ['周杰伦', '周杰伦 晴天', '林俊杰'],
      );
      final second = rankSearchSuggestions(
        query: '周杰',
        hotKeywords: ['周杰伦', '周杰伦 晴天', '林俊杰'],
      );
      expect(first.map((entry) => entry.text), ['周杰伦', '周杰伦 晴天']);
      expect(first, second);
    });

    test('空查询不产生输入建议', () {
      expect(rankSearchSuggestions(query: '   ', hotKeywords: ['b']), isEmpty);
    });
  });

  group('零结果纠错', () {
    test('单字符查询不纠错', () {
      expect(rankTypoCorrection(query: 'a', hotKeywords: ['ab']), isNull);
    });

    test('短查询 1 次编辑；长查询 2 次编辑', () {
      expect(
        rankTypoCorrection(query: 'qing', hotKeywords: ['qin']),
        'qin',
        reason: '4 字查询允许 1 次编辑',
      );
      expect(
        rankTypoCorrection(query: 'qing', hotKeywords: ['qingtian']),
        isNull,
        reason: '长度差超过预算',
      );
      expect(
        rankTypoCorrection(query: '晴天之歌啊', hotKeywords: ['晴天之夜吧']),
        '晴天之夜吧',
        reason: '长查询允许 2 次编辑',
      );
    });

    test('英文与中文字符级替换 / 换位', () {
      expect(
        rankTypoCorrection(query: 'beautful', hotKeywords: ['beautiful']),
        'beautiful',
      );
      expect(
        rankTypoCorrection(query: 'teh', hotKeywords: ['the']),
        'the',
        reason: '相邻换位记 1 次编辑',
      );
      expect(rankTypoCorrection(query: '周杰仑', hotKeywords: ['周杰伦']), '周杰伦');
    });

    test('拒绝自身、拒绝过远候选、并列确定', () {
      expect(
        rankTypoCorrection(query: 'hello', hotKeywords: ['hello']),
        isNull,
      );
      expect(
        rankTypoCorrection(query: 'hello', hotKeywords: ['zzzzz']),
        isNull,
      );
      final first = rankTypoCorrection(
        query: 'hello',
        hotKeywords: ['hallo', 'hullo'],
      );
      final second = rankTypoCorrection(
        query: 'hello',
        hotKeywords: ['hallo', 'hullo'],
      );
      expect(first, 'hallo', reason: '同距离时按来源顺序稳定取第一条');
      expect(first, second);
    });
  });
}
