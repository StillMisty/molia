/// 内置平台原生取词的派发入口（wy / tx / kg / kw / mg / bili）。
///
/// 平台矩阵只在 [BuiltinPlatforms] 声明：本文件按 `lyric` 适配器查表，
/// 不再维护六路 switch。这样 `SourceCapabilities.lyrics` 与真实派发共用
/// 同一条目——平台没登记取词适配器时，能力位为 false，派发也自然返回 null。
///
/// 结果归一化（空歌词 → null）与 5 分钟 TTL 缓存（key `{track.id}:lyric`）
/// 仍只在这里实现；`SourceManager.fetchLyric` 的脚本回退只调用 [fetch]。
///
/// 失败语义与迁移前逐条一致：
/// - 非内置平台 / 平台缺少取词所需字段 → null；
/// - 取词链路抛错 → null（交由上层歌词源继续回退）；失败不进缓存
///   （下次调用会重试，见 `RequestCache` 的契约）。
library;

import '../../data/cache/request_cache.dart';
import '../lx/lx_engine_types.dart';
import '../source_track.dart';
import 'builtin_platforms.dart';

class BuiltinLyricDispatch {
  BuiltinLyricDispatch({RequestCache? cache})
      : _cache = cache ??
            RequestCache(maxEntries: 64, ttl: const Duration(minutes: 5));

  /// 曲目原生取词缓存（key `{track.id}:lyric`）。
  final RequestCache _cache;

  /// 内置平台原生歌词回退（不支持 / 失败返回 null）。
  Future<LxLyricResult?> fetch(SourceTrack track) async {
    // 注册表同时承担「是不是内置平台」判定：没有取词适配器的 key 直接退出。
    final adapter = BuiltinPlatforms.lyricFor(track.sourceKey);
    if (adapter == null) return null;
    try {
      return await _cache.getOrCreate<LxLyricResult?>('${track.id}:lyric',
          () async {
        final info = await adapter(track.raw);
        if (info == null || info.isEmpty) return null;
        return LxLyricResult(
          lyric: info.lyric,
          tlyric: _nonEmpty(info.tlyric),
          rlyric: _nonEmpty(info.rlyric),
          lxlyric: _nonEmpty(info.lxlyric),
        );
      });
    } catch (_) {
      return null;
    }
  }

  /// 清掉某个平台的原生取词缓存（登录态变化后由组合根调用）。
  ///
  /// 缓存 key 形如 `bili:BVxxx:lyric`；同时清掉缓存过的 null，否则 B 站
  /// 登录后 5 分钟内仍会命中「无字幕」的旧结果。
  void invalidateSource(String sourceKey) {
    _cache.invalidatePrefix('$sourceKey:');
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
