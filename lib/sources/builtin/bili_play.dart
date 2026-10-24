/// B 站音轨取链：视频 cid → WBI playurl → dash 音频流。
///
/// B 站没有独立的「歌曲」直链：取链要先拿视频分 P 的 cid，再请求播放地址；
/// 直链约 120 分钟过期且必须带 `Referer` / `User-Agent`，所以返回
/// [PlayableStream]（headers + expiresIn），由播放与下载链路原样透传。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/failure.dart';
import '../../domain/ports/music_source.dart';
import '../source_search_result.dart' show parseSourceCount;
import '../source_track.dart' show pickQualityFor;
import 'bili_api.dart';
import 'builtin_search.dart';

/// dash.audio[].id → LX 音质标识（B 站匿名只给这三档）。
const Map<int, String> _audioQualityById = {
  30216: '64k',
  30232: '128k',
  30280: '192k',
};

class BiliPlay {
  BiliPlay._();

  /// bvid/aid → cid：同一视频反复取链（切音质 / 重新播放）不必再查分 P。
  static final Map<String, int> _cidCache = {};

  /// 测试隔离：清空 cid 缓存。
  @visibleForTesting
  static void reset() {
    _cidCache.clear();
  }

  static Future<PlayableStream> resolve(
    Map<String, dynamic> raw, {
    String? quality,
  }) async {
    final ids = _idsOf(raw);
    final bvid = ids.bvid;
    final aid = ids.aid;
    _requireIds(bvid, aid);

    try {
      var session = await BiliApi.session();
      final cid = await _cidFor(
        session.apiHeaders,
        raw,
        bvid: bvid,
        aid: aid,
      );

      var response = await _playUrl(
        session,
        bvid: bvid,
        aid: aid,
        cid: cid,
        fnval: 16,
      );
      var code = BiliApi.codeOf(response);
      if (BiliApi.isRiskControl(code)) {
        // WBI 密钥过期是匿名访问的常态：刷新会话后原样重试一次。
        session = await BiliApi.refresh();
        response = await _playUrl(
          session,
          bvid: bvid,
          aid: aid,
          cid: cid,
          fnval: 16,
        );
        code = BiliApi.codeOf(response);
      }
      _throwForCode(code);

      final data = response is Map ? response['data'] : null;
      var audio = _pickDashAudio(data, quality);
      if (audio == null) {
        // 老视频 / 版权限制可能没有 dash：退回 `fnval=1` 的 durl 单文件。
        final fallback = await _playUrl(
          session,
          bvid: bvid,
          aid: aid,
          cid: cid,
          fnval: 1,
        );
        _throwForCode(BiliApi.codeOf(fallback));
        final fallbackData = fallback is Map ? fallback['data'] : null;
        audio = _pickDurlAudio(fallbackData);
      }
      if (audio == null) {
        throw const SourceFailure(
          kind: FailureKind.unsupported,
          message: 'bili: 该视频没有可播放的音轨',
        );
      }

      final uri = Uri.parse(audio.url);
      return PlayableStream(
        uri,
        headers: BiliApi.streamHeaders,
        expiresIn: expiresInOf(uri),
      );
    } on SourceFailure {
      rethrow;
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }

  /// 视频首个分 P 的 cid（raw 带 cid 时直接复用，否则查分 P 并缓存）。
  ///
  /// 取链与 CC 字幕歌词共用这一入口：同一视频只查一次分 P；分 P 缓存
  /// 由 [_cidCache] 承担，歌词失败不影响下一次取链。
  static Future<int> cidOf(Map<String, dynamic> raw) async {
    final fromRaw = parseSourceCount(raw['cid']);
    if (fromRaw != null && fromRaw > 0) return fromRaw;
    final ids = _idsOf(raw);
    _requireIds(ids.bvid, ids.aid);
    // 分 P 接口不需要 WBI / Cookie：字幕歌词即使拿不到会话也能查 cid，
    // 不让 nav 失败拖垮歌词。
    return _cidFor(
      BiliApi.anonymousHeaders,
      raw,
      bvid: ids.bvid,
      aid: ids.aid,
    );
  }

  static ({String bvid, String aid}) _idsOf(Map<String, dynamic> raw) => (
        bvid: _textOf(raw['bvid']),
        aid: _textOf(raw['aid'] ?? raw['avid']),
      );

  static void _requireIds(String bvid, String aid) {
    if (bvid.isEmpty && aid.isEmpty) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: 'bili: 缺少 bvid / aid，无法取链',
      );
    }
  }

  /// 分 P 列表 → 首个 cid（raw 已带 cid 时直接复用）。
  static Future<int> _cidFor(
    Map<String, String> headers,
    Map<String, dynamic> raw, {
    required String bvid,
    required String aid,
  }) async {
    final fromRaw = parseSourceCount(raw['cid']);
    if (fromRaw != null && fromRaw > 0) return fromRaw;

    final cacheKey = bvid.isNotEmpty ? 'bv:$bvid' : 'av:$aid';
    final cached = _cidCache[cacheKey];
    if (cached != null) return cached;

    final query = bvid.isNotEmpty
        ? 'bvid=${Uri.encodeComponent(bvid)}'
        : 'aid=${Uri.encodeComponent(aid)}';
    final response = await BuiltinSearch.transport.getJson(
      '${BiliApi.baseUrl}/x/player/pagelist?$query',
      headers: headers,
    );
    _throwForCode(BiliApi.codeOf(response));

    final data = response is Map ? response['data'] : null;
    final first = data is List && data.isNotEmpty ? data.first : null;
    final cid = first is Map ? parseSourceCount(first['cid']) : null;
    if (cid == null || cid <= 0) {
      throw const SourceFailure(
        kind: FailureKind.notFound,
        message: 'bili: 视频没有可用分 P',
      );
    }
    _cidCache[cacheKey] = cid;
    return cid;
  }

  static Future<dynamic> _playUrl(
    BiliSession session, {
    required String bvid,
    required String aid,
    required int cid,
    required int fnval,
  }) {
    final url = session.signUrl(
      '${BiliApi.baseUrl}/x/player/wbi/playurl',
      {
        if (bvid.isNotEmpty) 'bvid': bvid else 'avid': aid,
        'cid': cid,
        'fnval': fnval,
        'fnver': 0,
        'fourk': 1,
      },
    );
    return BuiltinSearch.transport.getJson(url, headers: session.apiHeaders);
  }

  /// dash 音频选档：只认三档标准音频流 id，按请求音质回退。
  static _BiliAudio? _pickDashAudio(dynamic data, String? quality) {
    final dash = data is Map ? data['dash'] : null;
    final list = dash is Map ? dash['audio'] : null;
    if (list is! List) return null;
    final tracks = <_BiliAudio>[];
    for (final item in list) {
      if (item is! Map) continue;
      final id = parseSourceCount(item['id']);
      final type = id == null ? null : _audioQualityById[id];
      if (type == null) continue;
      final url = _audioUrlOf(item);
      if (url == null) continue;
      tracks.add(_BiliAudio(type: type, url: url));
    }
    if (tracks.isEmpty) return null;
    final picked = pickQualityFor(
      tracks.map((track) => track.type),
      quality ?? '192k',
    );
    return tracks.firstWhere((track) => track.type == picked);
  }

  /// `fnval=1` 回退：`data.durl[]` 是整段视频/音频文件，音质未知。
  static _BiliAudio? _pickDurlAudio(dynamic data) {
    final durl = data is Map ? data['durl'] : null;
    if (durl is! List) return null;
    for (final item in durl) {
      if (item is! Map) continue;
      final url = _audioUrlOf(item);
      if (url != null) return _BiliAudio(type: '128k', url: url);
    }
    return null;
  }

  /// 播放地址优先 `baseUrl/base_url`，缺失时取 `backupUrl` 的首个备选。
  ///
  /// durl（`fnval=1`）文件只有 `url` 字段，和 dash 的 `baseUrl` 不是同一命名。
  static String? _audioUrlOf(Map item) {
    final base = _textOf(item['baseUrl'] ?? item['base_url'] ?? item['url']);
    if (base.isNotEmpty) return base;
    final backup = item['backupUrl'] ?? item['backup_url'];
    if (backup is List) {
      for (final url in backup) {
        final text = _textOf(url);
        if (text.isNotEmpty) return text;
      }
      return null;
    }
    final text = _textOf(backup);
    return text.isEmpty ? null : text;
  }

  /// 直链有效期：B 站把截止时间放在 URL 的 `deadline` 查询参数（秒）。
  @visibleForTesting
  static Duration? expiresInOf(Uri uri) {
    final deadline = int.tryParse(uri.queryParameters['deadline'] ?? '');
    if (deadline == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seconds = deadline - now;
    return seconds > 0 ? Duration(seconds: seconds) : Duration.zero;
  }

  static void _throwForCode(int? code) {
    if (code == 0) return;
    if (code == null) {
      throw const BiliApiException(
        kind: FailureKind.unknown,
        message: 'bili: 播放地址响应非法',
      );
    }
    throw BiliApi.failureForCode(code);
  }

  static String _textOf(Object? value) => value?.toString().trim() ?? '';
}

class _BiliAudio {
  const _BiliAudio({required this.type, required this.url});

  final String type;
  final String url;
}
