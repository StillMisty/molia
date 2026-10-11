/// 自动换源：播放失败后跨音源**严格**找回同一首歌。
///
/// 原则：**宁可不换，也不换错**——
/// - 匹配用 `song_match.dart` 严格模式（时长 ±5s、归一化歌名/歌手/专辑、
///   版本词一致），无命中返回 null；
/// - 单源搜索失败静默跳过（与手动换源的失败隔离一致）；结果复用
///   [CatalogService] 的 5min 缓存，级联重试时不会重复打网络；
/// - 排除 [excludeSourceKeys]（已尝试来源由调用方按 provenance 维护）。
library;

import '../../data/catalog/catalog_service.dart';
import '../../domain/models/catalog.dart';
import '../../domain/models/source.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/source_registry.dart';
import '../song_match.dart';

class AutoSourceSwapService {
  AutoSourceSwapService({
    required CatalogService catalog,
    required SourceRegistry registry,
    this.perSourceLimit = 20,
  })  : _catalog = catalog,
        _registry = registry;

  final CatalogService _catalog;
  final SourceRegistry _registry;

  /// 每个音源的搜索上限（与手动弹窗同量级，自动只取最优一首）。
  final int perSourceLimit;

  /// 在其它可搜索音源里严格找回 [seed] 的同一首歌。
  ///
  /// [excludeSourceKeys] 为已尝试来源（调用方 provenance，通常含种子源）；
  /// 全部无命中 / 无可用来源返回 null。
  Future<Track?> findMatch(
    Track seed, {
    Set<String> excludeSourceKeys = const {},
  }) async {
    final descriptors = [
      for (final descriptor in _registry.descriptors)
        if (descriptor.enabled &&
            descriptor.capabilities.search &&
            descriptor.key != seed.id.sourceKey &&
            !excludeSourceKeys.contains(descriptor.key))
          descriptor,
    ];
    if (descriptors.isEmpty) return null;

    final keyword = [
      seed.title,
      ...seed.artists.map((artist) => artist.name),
    ].map((value) => value.trim()).where((value) => value.isNotEmpty).join(' ');

    final pages = await Future.wait([
      for (final descriptor in descriptors) _search(descriptor, keyword),
    ]);

    final candidates = <Track>[
      for (final page in pages)
        for (final track in page)
          if (track.id.uri != seed.id.uri) track,
    ];
    return pickBestSongMatchBy(
      candidates,
      target: _infoOf(seed),
      info: _infoOf,
      requireStrictMatch: true,
    );
  }

  Future<List<Track>> _search(
    SourceDescriptor descriptor,
    String keyword,
  ) async {
    try {
      final page = await _catalog.search(
        descriptor.key,
        SearchQuery(keyword: keyword, limit: perSourceLimit),
      );
      return page.items;
    } catch (_) {
      // 单源失败（引擎重启/网络）：跳过该源，不影响其它源。
      return const [];
    }
  }

  static SongMatchInfo _infoOf(Track track) => SongMatchInfo(
        title: track.title,
        artist: track.artists
            .map((artist) => artist.name)
            .where((name) => name.isNotEmpty)
            .join('、'),
        album: track.album,
        duration: track.duration,
      );
}
