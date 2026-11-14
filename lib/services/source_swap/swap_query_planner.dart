/// 换源查询规划：一次查询的关键词与候选音源。
///
/// 手动换源与自动换源对「搜什么、搜哪些源」必须给出同一份答案，两者只有
/// 排除集合不同（自动换源按 provenance 排除已尝试来源与种子源）。把关键词
/// 拼装与来源筛选收在这里，消费面不再各自判断能力位或 B 站 UP 主。
library;

import '../../domain/models/source.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/source_registry.dart';

/// 一次换源查询的输入：关键词 + 参与搜索的音源（注册表顺序）。
class SwapQueryPlan {
  SwapQueryPlan({
    required this.keyword,
    required List<SourceDescriptor> sources,
  }) : sources = List.unmodifiable(sources);

  final String keyword;

  /// 可参与本轮查询的音源；顺序即注册表的渠道顺序。
  final List<SourceDescriptor> sources;
}

/// 换源查询的唯一规划入口。
class SwapQueryPlanner {
  SwapQueryPlanner({required this._registry});

  final SourceRegistry _registry;

  /// 全部可参与换源的音源（注册表顺序，含种子源）。
  ///
  /// 手动换源保留种子源（同渠道可能有其它版本 / 投稿）；会话开始前 UI 也
  /// 用这份列表取来源展示名 / 判断空态。自动换源在 [plan] 里把种子源放进
  /// 排除集合。
  List<SourceDescriptor> get searchableSources => List.unmodifiable([
    for (final descriptor in _registry.descriptors)
      if (descriptor.enabled && descriptor.capabilities.search) descriptor,
  ]);

  /// 为 [seed] 生成查询计划。
  ///
  /// [excludedSourceKeys] 是调用方的排除集合（自动换源的 provenance 与
  /// 种子源）；手动换源不传，种子源因此仍参与候选。
  SwapQueryPlan plan(Track seed, {Set<String> excludedSourceKeys = const {}}) =>
      SwapQueryPlan(
        keyword: keywordFor(seed),
        sources: [
          for (final descriptor in searchableSources)
            if (!excludedSourceKeys.contains(descriptor.key)) descriptor,
        ],
      );

  /// 单个种子的换源关键词。
  ///
  /// 只取关键词的消费面（封面补取）用它，避免为拼词枚举 / 构建候选源。
  String keywordFor(Track seed) =>
      (_keywordPolicies[seed.id.sourceKey] ?? const _KeywordPolicy())
          .keywordFor(seed);
}

/// 单个音源与默认不同的关键词口径。
class _KeywordPolicy {
  const _KeywordPolicy({this.seedArtistIsUploader = false});

  /// 种子曲目的 artists 是否为 UP 主（而不是歌手）。
  final bool seedArtistIsUploader;

  /// 换源关键词：默认「标题 + 歌手」；UP 主型种子只用标题。
  ///
  /// 空段（标题为空 / 歌手名为空）不参与关键词。
  String keywordFor(Track seed) => [
    seed.title,
    if (!seedArtistIsUploader) ...seed.artists.map((artist) => artist.name),
  ].map((value) => value.trim()).where((value) => value.isNotEmpty).join(' ');
}

/// 只声明与默认不同的渠道；新渠道无需注册即继承默认口径。
///
/// B 站曲目的 artists 是投稿 UP 主：UP 主名不是这首歌的歌手，混进关键词
/// 会把搜索限定在该 UP 主的投稿上，反而降低其它平台的命中率。
const Map<String, _KeywordPolicy> _keywordPolicies = {
  'bili': _KeywordPolicy(seedArtistIsUploader: true),
};
