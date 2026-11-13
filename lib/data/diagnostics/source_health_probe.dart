/// 生产健康检查探针：把正常目录搜索 / 取链路径适配成诊断探针。
///
/// 只调用 [CatalogService]（与用户搜索同一实现），不启动脚本、不改渠道偏好、
/// 不碰播放队列。固定低开销查询、第 1 页、1 条结果。
library;

import '../../domain/models/catalog.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/source_registry.dart';
import '../../domain/ports/music_source.dart';
import '../../services/diagnostics/source_health_checker.dart';

class CatalogSourceHealthProbe implements SourceHealthProbe {
  CatalogSourceHealthProbe({required this._registry, this.keyword = 'love'});

  final SourceRegistry _registry;
  final String keyword;

  @override
  List<SourceHealthTarget> get targets => [
    for (final descriptor in _registry.descriptors)
      if (descriptor.enabled && descriptor.capabilities.search)
        SourceHealthTarget(
          key: descriptor.key,
          displayName: descriptor.displayName,
          canResolve: descriptor.capabilities.resolveUrl,
        ),
  ];

  @override
  Future<Track?> search(SourceHealthTarget target) async {
    // 直接走音源适配器：不经过 CatalogService 的搜索缓存，也不把健康检查
    // 失败写进“最近问题”（结果只在本轮健康检查里）。
    final source = _requireSource(target);
    final result = await source.search(
      SearchQuery(keyword: keyword, page: 1, limit: 1),
    );
    return result.items.isEmpty ? null : result.items.first;
  }

  @override
  Future<void> resolve(SourceHealthTarget target, Track track) async {
    // 不指定音质：由 SourceManager 按用户当前偏好决定，与正常播放一致。
    await _requireSource(target).resolve(track);
  }

  MusicSource _requireSource(SourceHealthTarget target) {
    final source = _registry.byKey(target.key);
    if (source == null) {
      throw StateError('Unknown source: ${target.key}');
    }
    return source;
  }
}
