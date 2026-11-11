import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/source_swap/swap_query_planner.dart';

import '../support/fake_music_source.dart';

/// 换源查询规划：关键词口径 / 候选来源 / 排除集合。
void main() {
  Track track(
    String sourceKey,
    String id, {
    String title = '晴天',
    List<String> artists = const ['周杰伦'],
  }) => Track(
    id: TrackId(sourceKey, id),
    title: title,
    artists: [for (final name in artists) Artist(name: name)],
    origin: TrackOrigin.builtin,
    payload: {'songmid': id, 'source': sourceKey},
  );

  test('关键词：默认标题 + 全部歌手，过滤空段并 trim', () {
    final planner = SwapQueryPlanner(
      registry: FakeSourceRegistry({'wy': FakeMusicSource('wy')}),
    );

    final plan = planner.plan(
      track('wy', '1', title: ' 晴天 ', artists: [' 周杰伦 ', '', '  ']),
    );

    expect(plan.keyword, '晴天 周杰伦');
  });

  test('关键词：B 站种子的 artists 是 UP 主，只搜标题', () {
    final planner = SwapQueryPlanner(
      registry: FakeSourceRegistry({'bili': FakeMusicSource('bili')}),
    );

    final plan = planner.plan(track('bili', 'BV1', artists: ['某UP主']));

    expect(plan.keyword, '晴天');
  });

  test('keywordFor：只拼关键词，不枚举音源', () {
    final planner = SwapQueryPlanner(registry: _NoDescriptorRegistry());

    expect(planner.keywordFor(track('bili', 'BV1', artists: ['某UP主'])), '晴天');
  });

  test('候选源：只含启用且可搜索的源，种子源默认保留', () {
    final sources = {
      'wy': FakeMusicSource('wy'),
      'kg': FakeMusicSource('kg'),
      'tx': FakeMusicSource(
        'tx',
        capabilities: const SourceCapabilities(resolveUrl: true),
      ),
      'bili': FakeMusicSource('bili'),
    };
    final planner = SwapQueryPlanner(
      registry: FakeSourceRegistry(sources, disabled: {'kg'}),
    );

    final plan = planner.plan(track('wy', '1'));

    expect(plan.sources.map((descriptor) => descriptor.key), [
      'wy',
      'bili',
    ], reason: '停用（kg）与非搜索（tx）不参与；种子源 wy 保留');
    expect(planner.searchableSources.map((descriptor) => descriptor.key), [
      'wy',
      'bili',
    ]);
  });

  test('排除集合：按 key 裁剪候选源，关键词不变', () {
    final sources = {
      'wy': FakeMusicSource('wy'),
      'kg': FakeMusicSource('kg'),
      'bili': FakeMusicSource('bili'),
    };
    final planner = SwapQueryPlanner(registry: FakeSourceRegistry(sources));

    final plan = planner.plan(
      track('wy', '1'),
      excludedSourceKeys: {'wy', 'bili'},
    );

    expect(plan.sources.map((descriptor) => descriptor.key), ['kg']);
    expect(plan.keyword, '晴天 周杰伦');
  });
}

/// 读取 descriptors 即失败的注册表：证明 [SwapQueryPlanner.keywordFor]
/// 不依赖候选源枚举（封面补取只取关键词）。
class _NoDescriptorRegistry extends FakeSourceRegistry {
  _NoDescriptorRegistry() : super({});

  @override
  List<SourceDescriptor> get descriptors =>
      throw StateError('keywordFor 不应枚举音源');
}
