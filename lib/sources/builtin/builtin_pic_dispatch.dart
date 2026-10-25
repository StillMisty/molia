/// 内置平台原生取图的派发入口（五个音乐平台 + B 站：wy / tx / kg / kw / mg / bili）。
///
/// 平台矩阵只在 [BuiltinPlatforms] 声明：本文件按 `pic` 适配器查表，不再
/// 维护六路 switch；`SourceCapabilities.artwork` 与真实派发读取同一条目。
///
/// 结果归一化与 5 分钟 TTL 缓存（key `{track.id}:pic`）仍只在这里实现；
/// `SourceManager.fetchPic` 的脚本回退只调用 [fetch]。
///
/// 失败语义与迁移前逐条一致：
/// - 非内置平台 / 平台缺少拼图所需字段 → null；
/// - 取图链路抛错 → null（交由上层继续回退）；失败不进缓存
///   （下次调用会重试，见 `RequestCache` 的契约）。
library;

import '../../data/cache/request_cache.dart';
import '../source_track.dart';
import 'builtin_platforms.dart';

class BuiltinPicDispatch {
  BuiltinPicDispatch({RequestCache? cache})
      : _cache = cache ??
            RequestCache(maxEntries: 128, ttl: const Duration(minutes: 5));

  /// 曲目原生取图缓存（key `{track.id}:pic`）。
  final RequestCache _cache;

  /// 内置平台原生封面回退（不支持 / 失败返回 null）。
  Future<String?> fetch(SourceTrack track) async {
    final adapter = BuiltinPlatforms.picFor(track.sourceKey);
    if (adapter == null) return null;
    try {
      return await _cache.getOrCreate<String?>(
          '${track.id}:pic', () => adapter(track.raw));
    } catch (_) {
      return null;
    }
  }
}
