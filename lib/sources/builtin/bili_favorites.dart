/// B 站收藏夹导入：链接 / ID 解析 + 全部分页的资源列表。
///
/// 收藏夹是 bili 唯一的「歌单」形态（不支持歌单浏览 / 搜索），导入入口只
/// 接受收藏夹链接或 media_id。资源列表接口固定 20 条/页，且只给出
/// `media_count` / `has_more`：这里一次拉全（上限 50 页 / 1000 条），避免
/// 导入时只拿到第一页却误以为已经完整。
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../data/http/app_dio.dart';
import '../../domain/models/discover.dart';
import '../../domain/models/failure.dart';
import '../source_search_result.dart' show parseSourceBool, parseSourceCount;
import '../source_track.dart';
import 'bili_api.dart';
import 'bili_track.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'discover_track_mapper.dart';

/// 收藏夹详情里的资源类型：2 = 视频（B 站收藏夹也会混入番剧 / 课程等）。
const int _videoType = 2;

class BiliFavorites {
  BiliFavorites._();

  static const int pageSize = 20;
  static const int maxPages = 50;
  static const int maxItems = 1000;

  static final RegExp _digits = RegExp(r'^\d+$');
  static final RegExp _mediaListPath = RegExp(r'/medialist/detail/ml(\d+)');
  static final RegExp _folderLink =
      RegExp(r'(?:space\.)?bilibili\.com/(\d+)/favlist');
  static final RegExp _shortLinkHost = RegExp(r'(^|\.)b23\.tv$');

  static Dio? _redirectDio;

  /// 短链跳转只读状态码 / Location，不读 body；测试注入替身避免真实网络。
  @visibleForTesting
  static Dio? redirectDioForTest;

  static Dio get _dio =>
      redirectDioForTest ?? (_redirectDio ??= createAppDio());

  /// 解析收藏夹 ID：纯数字 / `fid` / `media_id` / `ml<id>` / b23 短链。
  ///
  /// 返回 null 表示无法识别（调用方统一转成 notFound）。`space.bilibili.com`
  /// 的 favlist 链接不带 `fid` 时尝试取该 UP 的第一个收藏夹（需要多一次请求，
  /// 失败就按无法识别处理，不影响其它链接形态）。
  static Future<String?> parseMediaId(String rawId) async {
    final text = rawId.trim();
    if (text.isEmpty) return null;

    final direct = _parseText(text);
    if (direct != null) return direct;

    final uri = _asUri(text);
    if (uri == null) return null;

    if (_shortLinkHost.hasMatch(uri.host.toLowerCase())) {
      final resolved = await _resolveShortLink(uri);
      if (resolved == null) return null;
      final resolvedId = _parseText(resolved.toString());
      if (resolvedId != null) return resolvedId;
      return _firstFolderOf(resolved.toString());
    }
    return _firstFolderOf(text);
  }

  /// 收藏夹详情：忽略入参 [page]，永远从第 1 页拉全。
  ///
  /// 导入路径只需要一次完整结果；按页返回会让「导入」只导入前 20 条。
  static Future<DiscoverDetail> detail(String rawId, int page) async {
    final mediaId = await parseMediaId(rawId);
    if (mediaId == null) {
      throw const SourceFailure(
        kind: FailureKind.notFound,
        message: 'bili: 收藏夹链接或 ID 无法识别',
        retryable: false,
      );
    }
    try {
      return await _fetchAll(mediaId);
    } on SourceFailure {
      rethrow;
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }

  static Future<DiscoverDetail> _fetchAll(String mediaId) async {
    final session = await BiliApi.session();
    Map? info;
    final tracks = <String, SourceTrack>{};

    var pn = 1;
    while (pn <= maxPages && tracks.length < maxItems) {
      final response = await _fetchPage(session, mediaId, pn);
      final code = BiliApi.codeOf(response);
      if (code != 0) throw _failureForCode(code);

      final data = response is Map ? response['data'] : null;
      if (data is! Map) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: 'bili: 收藏夹响应结构不符',
        );
      }
      // 私密 / 已删除收藏夹没有 info（平台仍回 code=0）。真实响应通常每页
      // 都带 info，但没有必要依赖：第一页拿到后就够构造详情，后续页缺 info
      // 不应让整份导入失败。
      final rawInfo = data['info'];
      if (rawInfo is Map) {
        info ??= rawInfo;
      } else if (info == null) {
        throw const SourceFailure(
          kind: FailureKind.notFound,
          message: 'bili: 收藏夹不存在或不可见',
          retryable: false,
        );
      }

      final medias = data['medias'];
      if (medias is List) {
        for (final item in medias) {
          if (tracks.length >= maxItems) break;
          final track = _trackOf(item);
          if (track == null) continue;
          // 分页边界偶尔重复返回同一条；导入结果不能出现重复曲目。
          tracks.putIfAbsent(track.songId, () => track);
        }
      }

      final mediaCount = parseSourceCount(info['media_count']) ?? 0;
      final hasMore = parseSourceBool(data['has_more']);
      if (hasMore == false) break;
      if (mediaCount > 0 && pn * pageSize >= mediaCount) break;
      if (hasMore != true && mediaCount == 0) break;
      if (medias is! List || medias.isEmpty) break;
      pn++;
    }

    if (info == null) {
      throw const SourceFailure(
        kind: FailureKind.notFound,
        message: 'bili: 收藏夹不存在或不可见',
        retryable: false,
      );
    }
    return _detailOf(mediaId, info, tracks.values.toList());
  }

  static Future<dynamic> _fetchPage(
    BiliSession session,
    String mediaId,
    int pn,
  ) {
    final uri = Uri.parse('${BiliApi.baseUrl}/x/v3/fav/resource/list')
        .replace(queryParameters: {
      'media_id': mediaId,
      'pn': '$pn',
      'ps': '$pageSize',
      'order': 'mtime',
      'type': '0',
      'platform': 'web',
    });
    return BuiltinSearch.transport.getJson(
      uri.toString(),
      headers: session.apiHeaders,
      retries: BuiltinTransport.defaultRetries,
    );
  }

  /// 单条收藏 → 曲目；非视频 / 失效条目在这里过滤掉。
  static SourceTrack? _trackOf(dynamic item) {
    if (item is! Map) return null;
    if (parseSourceCount(item['type']) != _videoType) return null;
    // attr 非 0 表示失效 / 私有；缺省（null）按平台旧版本处理为有效。
    final attr = item['attr'];
    if (attr != null && parseSourceCount(attr) != 0) return null;
    final bvid = item['bvid']?.toString().trim() ?? '';
    if (bvid.isEmpty) return null;
    // 标题交给 biliTrackFromItem 统一清洗（只解码一次 HTML 实体）。
    final title = item['title']?.toString() ?? '';
    if (biliText(title).isEmpty) return null;

    final upper = item['upper'] is Map ? item['upper'] as Map : const {};
    return biliTrackFromItem(
      item,
      title: title,
      cover: item['cover']?.toString(),
      author: upper['name']?.toString(),
      authorMid: upper['mid']?.toString(),
      duration: item['duration'],
      aid: item['id'],
      bvid: bvid,
    );
  }

  static DiscoverDetail _detailOf(
    String mediaId,
    Map info,
    List<SourceTrack> tracks,
  ) {
    final upper = info['upper'] is Map ? info['upper'] as Map : const {};
    var playCount = 0;
    for (final track in tracks) {
      final raw = track.raw;
      final cntInfo = raw['cnt_info'];
      playCount += cntInfo is Map
          ? parseSourceCount(cntInfo['play']) ?? 0
          : parseSourceCount(raw['play']) ?? 0;
    }
    final mediaCount = parseSourceCount(info['media_count']) ?? tracks.length;
    final ctime = parseSourceCount(info['ctime']);
    final intro = biliText(info['intro']);
    return DiscoverDetail(
      info: DiscoverPlaylist(
        id: mediaId,
        name: biliText(info['title']),
        coverUrl: biliCoverUrl(info['cover']),
        author: upper['name']?.toString() ?? '',
        playCount: playCount,
        trackCount: mediaCount,
        description: intro.isEmpty ? null : intro,
        createdAt: ctime == null ? null : _formatDate(ctime),
      ),
      tracks: [for (final track in tracks) discoverTrackOf(track)],
    );
  }

  static SourceFailure _failureForCode(int? code) {
    if (code == -403 || code == -404) {
      return SourceFailure(
        kind: FailureKind.notFound,
        message: 'bili: 收藏夹不存在或不可见（code=$code）',
        retryable: false,
      );
    }
    return SourceFailure(
      kind: FailureKind.unknown,
      message: 'bili: 获取收藏夹失败（code=${code ?? '非 JSON'}）',
      retryable: true,
    );
  }

  /// 纯文本形态：数字 / query 参数 / ml 路径。
  static String? _parseText(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (_digits.hasMatch(text)) return text;

    final uri = _asUri(text);
    if (uri != null) {
      for (final key in const ['fid', 'media_id']) {
        final value = uri.queryParameters[key]?.trim() ?? '';
        if (_digits.hasMatch(value)) return value;
      }
      final match = _mediaListPath.firstMatch(uri.path);
      if (match != null) return match.group(1);
    }
    final match = _mediaListPath.firstMatch(text);
    return match?.group(1);
  }

  /// `space.bilibili.com/<mid>/favlist`（不带 fid）→ 该 UP 的第一个收藏夹。
  static Future<String?> _firstFolderOf(String text) async {
    final match = _folderLink.firstMatch(text);
    if (match == null) return null;
    return _firstFolderId(match.group(1)!);
  }

  static Future<String?> _firstFolderId(String upMid) async {
    try {
      final session = await BiliApi.session();
      final uri =
          Uri.parse('${BiliApi.baseUrl}/x/v3/fav/folder/created/list-all')
              .replace(queryParameters: {'up_mid': upMid});
      final response = await BuiltinSearch.transport.getJson(
        uri.toString(),
        headers: session.apiHeaders,
      );
      if (BiliApi.codeOf(response) != 0) return null;
      final data = response is Map ? response['data'] : null;
      final list = data is Map ? data['list'] : null;
      if (list is! List) return null;
      for (final item in list) {
        if (item is! Map) continue;
        final id = (item['id'] ?? item['fid'])?.toString().trim() ?? '';
        if (_digits.hasMatch(id)) return id;
      }
    } catch (_) {
      // 取第一个收藏夹只是便利回退，失败按无法识别处理。
    }
    return null;
  }

  /// 跟随 b23 短链。真实 adapter 会自己跟随并给出 `realUri`；测试替身
  /// 只回 302 时再按 Location 手动跟一跳。
  ///
  /// 短链目标是普通 HTML 页（体积不小），这里只关心状态码 / Location，
  /// 用 `bytes` 让 dio 读完即释放，避免 `stream` 响应体无人关闭泄漏连接。
  /// 请求头与 B 站 API 一致：浏览器 UA + Referer，短链服务对匿名脚本 UA 会
  /// 返回验证页而不是跳转。
  static Future<Uri?> _resolveShortLink(Uri uri) async {
    var current = uri;
    try {
      for (var hop = 0; hop < 5; hop++) {
        final response = await _dio
            .getUri<dynamic>(
              current,
              options: Options(
                method: 'GET',
                headers: const {
                  'User-Agent': BiliApi.browserUserAgent,
                  'Referer': BiliApi.referer,
                  'Accept': 'text/html,application/xhtml+xml',
                },
                followRedirects: true,
                maxRedirects: 5,
                responseType: ResponseType.bytes,
              ),
            )
            .timeout(BuiltinSearch.defaultTimeout);
        final realUri = response.realUri;
        if (realUri != current) return realUri;

        final status = response.statusCode ?? 0;
        final location = response.headers.value('location');
        if (status >= 300 &&
            status < 400 &&
            location != null &&
            location.isNotEmpty) {
          current = current.resolve(location);
          continue;
        }
        return current;
      }
      return current;
    } catch (_) {
      return null;
    }
  }

  static Uri? _asUri(String text) {
    final direct = Uri.tryParse(text);
    if (direct != null && direct.hasScheme) return direct;
    return Uri.tryParse('https://$text');
  }

  static String _formatDate(int seconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }
}
