/// 换源行为的按音源策略。
///
/// 换源关键词在不同平台并不一样（B 站 artists 是 UP 主）；把差异收敛到
/// 这里（而不是在 provider 里散落 `if (sourceKey == 'bili')`），新渠道默认
/// 继承标准行为，需要时再声明覆盖。种子源本身始终参与候选，不再按策略排除。
library;

import '../../domain/models/track.dart';

/// 单个音源的换源行为。
class SourceSwapStrategy {
  const SourceSwapStrategy({
    this.seedArtistIsUploader = false,
  });

  /// 种子曲目的 artists 是否为 UP 主（而不是歌手）。
  ///
  /// B 站的 artist 字段是投稿 UP 主：UP 主名不是这首歌的歌手，混进关键词
  /// 会把搜索限定在该 UP 主的投稿上，反而降低其它平台的命中率。
  final bool seedArtistIsUploader;

  /// 换源关键词：默认「标题 + 歌手」；UP 主型种子只用标题。
  ///
  /// 空段过滤（标题为空 / 歌手名为空）与历史行为一致。
  String keywordFor(Track seed) => [
        seed.title,
        if (!seedArtistIsUploader) ...seed.artists.map((artist) => artist.name),
      ]
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .join(' ');
}

/// 按音源 key 查策略；未声明的渠道走默认策略。
class SourceSwapStrategies {
  const SourceSwapStrategies({this.byKey = const {}});

  /// 内置平台的换源口径（只声明与默认不同的音源）。
  static const standard = SourceSwapStrategies(byKey: {
    'bili': SourceSwapStrategy(seedArtistIsUploader: true),
  });

  final Map<String, SourceSwapStrategy> byKey;

  SourceSwapStrategy of(String sourceKey) =>
      byKey[sourceKey] ?? const SourceSwapStrategy();
}
