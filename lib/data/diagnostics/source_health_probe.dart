/// 生产健康检查探针：把正常音源搜索 / 取链路径适配成诊断探针。
///
/// 直接走 [SourceRegistry] 的音源适配器，绕过目录缓存与“最近失败”记录；
/// 不启动脚本、不改渠道偏好、不碰播放队列。固定低开销查询、第 1 页、1 条。
library;

import '../../domain/models/catalog.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/source_registry.dart';
import '../../domain/ports/music_source.dart';
import '../../services/diagnostics/source_health_checker.dart';
import '../../sources/source_track.dart' show pickQualityFor;

class CatalogSourceHealthProbe implements SourceHealthProbe {
  CatalogSourceHealthProbe({
    required this._registry,
    this._preferredQuality,
    this.keyword = 'love',
  });

  final SourceRegistry _registry;

  /// 与正常播放同源的偏好音质（组合根注入省流压低后的值）。
  final String Function()? _preferredQuality;
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
    // 与正常播放一致：偏好音质（组合根已叠加省流上限）先按曲目可用档位
    // 收敛，再把同一档位交给取链，避免健康检查绕过省流或绕过回退规则。
    final preferred = _preferredQuality?.call();
    final quality = preferred == null || preferred.isEmpty
        ? null
        : AudioQuality(
            type: pickQualityFor(
              track.qualities.map((quality) => quality.type),
              preferred,
            ),
          );
    await _requireSource(target).resolve(track, preferredQuality: quality);
  }

  MusicSource _requireSource(SourceHealthTarget target) {
    final source = _registry.byKey(target.key);
    if (source == null) {
      throw StateError('Unknown source: ${target.key}');
    }
    return source;
  }
}
