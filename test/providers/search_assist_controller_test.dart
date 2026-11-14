import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/source.dart' show SourceCapabilities;
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/search/search_assist.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_assist_controller.dart';
import 'package:molia/providers/search_provider.dart';

import '../support/fake_music_source.dart';
import '../support/fakes.dart';

Track _track(String sourceKey, String id) => Track(
  id: TrackId(sourceKey, id),
  title: 'Title $id',
  artists: const [],
  album: 'Album',
  duration: const Duration(seconds: 30),
  origin: TrackOrigin.lx,
  qualities: const [],
  payload: {'songmid': id},
);

Future<void> _waitUntil(bool Function() predicate) async {
  for (var index = 0; index < 500 && !predicate(); index++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue, reason: '等待条件超时');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeMusicSource kw;
  late FakeMusicSource tx;
  late FakeSourceRegistry registry;
  late ChannelSelection selection;
  late SearchProvider provider;
  late SearchAssistController assist;
  late PlaybackProvider playback;

  setUp(() {
    kw =
        FakeMusicSource(
            'kw',
            capabilities: const SourceCapabilities(
              search: true,
              pagination: true,
            ),
          )
          ..onSearch = (query) async => SearchResult(
            items: [
              if (query.keyword != 'missing' && query.keyword != '晴天之夜')
                _track('kw', query.keyword),
            ],
          );
    tx =
        FakeMusicSource(
            'tx',
            capabilities: const SourceCapabilities(
              search: true,
              pagination: true,
            ),
          )
          ..onSearch = (query) async => SearchResult(
            items: [
              if (query.keyword != 'missing' && query.keyword != '晴天之夜')
                _track('tx', query.keyword),
            ],
          );
    registry = FakeSourceRegistry({'kw': kw, 'tx': tx});
    selection = ChannelSelection(
      validKeys: () => ['kw', 'tx'],
      defaultKey: () => 'kw',
    );
    playback = buildTestPlaybackProvider();
    provider = SearchProvider(
      playback,
      selection: selection,
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
    );
    assist = SearchAssistController(
      search: provider,
      hotKeywords: () => provider.activeSourceKey == 'tx'
          ? const ['QQ 热词']
          : const ['晴天', '稻香', '夜曲', '晴天之歌'],
    );
    assist.setFocused(true);
  });

  tearDown(() {
    assist.dispose();
    provider.dispose();
    playback.dispose();
    selection.dispose();
  });

  test('空词聚焦显示热搜芯片；失焦后隐藏', () async {
    assist.setFocused(false);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(assist.value.showChips, isFalse);
    assist.setFocused(true);
    expect(assist.value.showChips, isTrue);
    expect(assist.value.chips.hot, ['晴天', '稻香', '夜曲', '晴天之歌']);
  });

  test('输入关键词用热搜做建议；清空回到热搜芯片', () async {
    provider.updateSearchQuery('晴');
    expect(assist.value.showSuggestions, isTrue);
    expect(
      assist.value.suggestions.map((suggestion) => suggestion.text),
      contains('晴天'),
    );

    provider.clearSearch();
    expect(assist.value.showChips, isTrue);
  });

  test('选中建议立即搜索，高亮随建议变化重置', () async {
    provider.updateSearchQuery('晴');
    expect(assist.value.showSuggestions, isTrue);
    expect(assist.value.suggestions, isNotEmpty);
    assist.moveHighlight(1);
    expect(assist.value.highlightedIndex, 0);

    provider.updateSearchQuery('晴');
    // 同一关键词下列表不变：高亮保留；换词后重置。
    provider.updateSearchQuery('晴x');
    expect(assist.value.highlightedIndex, -1);

    assist.selectSuggestion(const SearchSuggestion(text: '晴天'));
    await _waitUntil(() => !provider.isSearchBusy);
    expect(provider.songResults.items.single.title, 'Title 晴天');
  });

  test('切换渠道后热搜芯片跟着渠道刷新', () async {
    expect(assist.value.chips.hot.first, '晴天');
    selection.select('tx');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(assist.value.chips.hot, ['QQ 热词']);
  });

  test('纠错只在成功的单曲零结果时出现', () async {
    provider.submitSearch('晴天之夜');
    expect(assist.value.correction, isNull, reason: '加载中不提示');
    await _waitUntil(() => !provider.isSearchBusy);
    expect(provider.songResults.items, isEmpty);
    expect(assist.value.correction, '晴天之歌');

    // 有结果时不触发纠错。
    provider.submitSearch('稻香');
    await _waitUntil(() => !provider.isSearchBusy);
    expect(assist.value.correction, isNull);
  });
}
