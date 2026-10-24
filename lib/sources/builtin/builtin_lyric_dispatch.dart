/// 内置平台原生取词的派发入口（wy / tx / kg / kw / mg / bili）。
///
/// 从 `SourceManager` 拆出：6 路 switch（曲目 raw 字段 → 各 `*_lyric.dart`
/// 的取词接口）、结果归一化（空歌词 → null）与 5 分钟 TTL 缓存
/// （key `{track.id}:lyric`）在这里只有一处实现；`SourceManager.fetchLyric`
/// 的脚本回退只调用 [fetch]。
///
/// 失败语义与迁移前逐条一致：
/// - 非内置平台 / 平台缺少取词所需字段 → null；
/// - 取词链路抛错 → null（交由上层歌词源继续回退）；失败不进缓存
///   （下次调用会重试，见 `RequestCache` 的契约）。
library;

import '../../data/cache/request_cache.dart';
import '../lx/lx_engine_types.dart';
import '../source_track.dart';
import 'bili_lyric.dart';
import 'builtin_search.dart';
import 'kg_lyric.dart';
import 'kw_lyric.dart';
import 'lyric_result.dart';
import 'mg_lyric.dart';
import 'tx_lyric.dart';
import 'wy_lyric.dart';

class BuiltinLyricDispatch {
  BuiltinLyricDispatch({RequestCache? cache})
      : _cache = cache ??
            RequestCache(maxEntries: 64, ttl: const Duration(minutes: 5));

  /// 曲目原生取词缓存（key `{track.id}:lyric`）。
  final RequestCache _cache;

  /// 内置平台原生歌词回退（不支持 / 失败返回 null）。
  Future<LxLyricResult?> fetch(SourceTrack track) async {
    if (!BuiltinSearch.isBuiltin(track.sourceKey)) return null;
    try {
      return await _cache.getOrCreate<LxLyricResult?>('${track.id}:lyric',
          () async {
        final info = await _fetchFor(track);
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

  /// 派发到各内置平台的原生取词实现。
  static Future<BuiltinLyricResult?> _fetchFor(SourceTrack track) {
    final raw = track.raw;
    switch (track.sourceKey) {
      case 'wy':
        final songId = raw['songmid'] ?? raw['id'];
        if (songId == null) return Future.value(null);
        return WyLyric.fetch(songId.toString()).then(
          (info) => BuiltinLyricResult(
            lyric: info.lyric,
            tlyric: info.tlyric,
            rlyric: info.rlyric,
            lxlyric: info.lxlyric,
          ),
        );
      case 'tx':
        return TxLyric.fetch(
          songId: raw['songId']?.toString(),
          songMid: raw['songmid']?.toString(),
        );
      case 'kg':
        final hash = raw['hash']?.toString();
        final name = raw['name']?.toString();
        if (hash == null || hash.isEmpty || name == null || name.isEmpty) {
          return Future.value(null);
        }
        return KgLyric.fetch(
          name: name,
          hash: hash,
          timelengthSeconds: _intervalSecondsOf(raw),
        );
      case 'kw':
        final songmid = raw['songmid']?.toString();
        if (songmid == null || songmid.isEmpty) return Future.value(null);
        return KwLyric.fetch(songmid);
      case 'mg':
        return MgLyric.fetch(
          songId: raw['songmid']?.toString(),
          mrcUrl: raw['mrcUrl']?.toString(),
          lrcUrl: raw['lrcUrl']?.toString(),
          trcUrl: raw['trcUrl']?.toString(),
        );
      case 'bili':
        return BiliLyric.fetch(raw);
      default:
        return Future.value(null);
    }
  }

  /// 曲目时长（秒）：优先 `_interval`，否则解析 `mm:ss` 文本。
  static int _intervalSecondsOf(Map<String, dynamic> raw) {
    final rawInterval = raw['_interval'];
    if (rawInterval is num) return rawInterval.toInt();
    if (rawInterval is String) {
      final parsed = int.tryParse(rawInterval);
      if (parsed != null) return parsed;
    }
    final interval = raw['interval']?.toString() ?? '';
    final match = RegExp(r'^(\d{1,3}):(\d{2})').firstMatch(interval);
    if (match == null) return 0;
    return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
