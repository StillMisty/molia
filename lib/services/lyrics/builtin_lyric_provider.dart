/// 通用内置平台歌词 provider：平台在 [BuiltinPlatforms] 同时登记 `search` +
/// `lyric` 适配器即可按名字搜歌并取词。
///
/// 五个音乐平台有各自的专用 provider（QQ / 网易 / 酷狗 / 酷我 / 咪咕：
/// 搜索后要把 `hash` / `mrcUrl` / 数字 songId 等平台字段放进
/// [SongMatch.extra] 才能取词），本类只服务「新渠道 / 视频站」这类
/// 搜索与取词都能直接吃 raw 的平台（首个用户是 B 站字幕）。
library;

import 'package:logging/logging.dart';

import '../../sources/builtin/bili_lyric.dart';
import '../../sources/builtin/bili_session.dart';
import '../../sources/builtin/builtin_platforms.dart';
import '../../sources/builtin/builtin_search.dart';
import '../../sources/source_track.dart';
import 'lyric_provider.dart';

class BuiltinLyricProvider extends LyricProvider {
  BuiltinLyricProvider(this.key, {this.biliSession});

  /// 内置平台 key（`BuiltinPlatforms.byKey` 的键，如 `bili`）。
  final String key;

  /// B 站字幕的账号会话；null = 静态 `BiliLyric.shared`。
  final BiliSession? biliSession;

  final Logger _logger = Logger('molia.builtin_lyric_provider');

  @override
  String get name => key;

  @override
  Future<SongMatch?> search(String title, String artist) async {
    final matches = await searchMultiple(title, artist, limit: 1);
    return matches.isEmpty ? null : matches.first;
  }

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) async {
    final keyword = [
      title,
      artist,
    ].map((value) => value.trim()).where((value) => value.isNotEmpty).join(' ');
    if (keyword.isEmpty) return const [];

    try {
      final tracks = <SourceTrack>[];
      // 平台支持「按歌词搜歌」时优先用它：歌词片段命中的结果比整首标题
      // 关键词更准，且命中项同样自带取词所需的 raw。
      final lyricSearch = BuiltinPlatforms.lyricSearchFor(key);
      if (lyricSearch != null) {
        final page = await lyricSearch(keyword, limit: limit);
        tracks.addAll(page.hits.map((hit) => hit.track));
      } else {
        final result = await BuiltinSearch.searchWithMeta(
          key,
          keyword,
          limit: limit,
        );
        final failure = result.failure;
        if (failure != null) {
          // 失败语义在搜索层已归一（SourceFailure），这里只记日志并返回
          // 空结果：换源页把「无结果」与「请求失败」都表现为该来源没有
          // 可选项，不需要区分（其余来源仍可正常使用）。
          _logger.warning('歌词搜索失败（$key）：${failure.message}');
          return const [];
        }
        tracks.addAll(result.tracks);
      }
      return [for (final track in tracks.take(limit)) _toMatch(track)];
    } catch (e, st) {
      // 按歌词搜歌的适配器以异常表达失败；与其它 provider 一样收口为空，
      // 让 LyricsService / 换源页继续走下一个来源。
      _logger.warning('歌词搜索失败（$key）', e, st);
      return const [];
    }
  }

  static SongMatch _toMatch(SourceTrack track) {
    return SongMatch(
      songId: track.songId,
      title: track.title,
      artist: track.artist,
      album: track.album.isEmpty ? null : track.album,
      duration: track.duration,
      // raw 原样透传：取词（B 站 bvid/cid、其它平台各自字段）只认这份。
      extra: track.raw,
    );
  }

  @override
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async {
    // B 站字幕需要账号会话；经会话实例取词，注册表注入的会话（测试 /
    // 多实例）不落到静态 `BiliLyric.shared`。其它通用渠道仍走注册表适配器。
    final adapter = key == 'bili'
        ? BiliLyric(session: biliSession).fetch
        : BuiltinPlatforms.lyricFor(key);
    if (adapter == null) return null;
    try {
      final info = await adapter(match.extra);
      if (info == null || info.isEmpty) return null;
      return LyricsPayload(
        lyric: info.lyric,
        // 空串按 null 传：UI 用 null 判断「没有扩展行」，空串会渲染出
        // 一行空的翻译 / 罗马音 / 逐字占位。
        translation: _nonEmpty(info.tlyric),
        roma: _nonEmpty(info.rlyric),
        lxlyric: _nonEmpty(info.lxlyric),
      );
    } catch (e, st) {
      // 歌词缺失不阻断换源：失败按「这首歌没有歌词」处理，用户可改选
      // 其它来源；错误对象只进日志，不进 UI。
      _logger.warning('取词失败（$key）', e, st);
      return null;
    }
  }

  /// 通用实现没有搜索响应里的平台字段（B 站要 bvid/cid、酷狗要 hash），
  /// 只有 songId 取不到词；手动换源统一走 [fetchForMatch]（raw 随
  /// [SongMatch.extra] 透传）。
  @override
  Future<String?> fetchLyric(String songId) async => null;

  static String? _nonEmpty(String? text) {
    final trimmed = text?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
