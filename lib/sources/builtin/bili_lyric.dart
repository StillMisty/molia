/// B 站 CC 字幕歌词：`/x/player/wbi/v2` 选轨 → 字幕 JSON → 行级 LRC。
///
/// B 站没有音乐平台那种「歌词」实体，歌词就是视频字幕：接口按 `lan`
/// 返回多轨（`ai-zh` 为自动生成中文），这里中文优先、其余语言兜底。
/// `subtitle_url` 可能是协议相对地址（`//host/...`），统一补 `https:`。
/// 字幕 JSON 的 `from` 是秒（double），转成 `[mm:ss.mmm]`。
///
/// **登录态**：`/x/player/v2` 未登录时 `subtitles` 恒为空（buvid 也没用），
/// 所以没有账号 Cookie 时直接返回 null，不再发无效请求；登录后走
/// `/x/player/wbi/v2`（WBI + 账号 Cookie），失败再退回 unsigned 版本。
/// 字幕文件本身是公开 CDN，请求保持匿名，**绝不带账号 Cookie**。
/// 任何失败都返回 null，歌词缺失不能阻断播放。
library;

import '../../domain/models/failure.dart';
import 'bili_account.dart';
import 'bili_client.dart';
import 'bili_play.dart';
import 'lyric_result.dart';

class BiliLyric {
  BiliLyric._();

  /// 中文轨判定：`lan` 命中平台已知标识，或 `lan_doc` 含「中文」。
  static const Set<String> _chineseLans = {'zh-Hans', 'zh-CN', 'zh', 'ai-zh'};

  /// 获取字幕歌词；未登录 / 无字幕 / 请求失败返回 null。
  ///
  /// 不在这里缓存：失败若被缓存，用户重试或重新播放会一直拿不到歌词。
  static Future<BuiltinLyricResult?> fetch(Map<String, dynamic> raw) async {
    try {
      final store = BiliAccountStore.instance;
      await store.ready;
      final cookie = store.cookieHeader;
      if (cookie == null || cookie.isEmpty || !store.isLoggedIn) return null;

      final bvid = raw['bvid']?.toString().trim() ?? '';
      final aid = (raw['aid'] ?? raw['avid'])?.toString().trim() ?? '';
      if (bvid.isEmpty && aid.isEmpty) return null;

      // 与取链共用 cid 缓存：raw 有 cid 时连分 P 都不查。
      final cid = await BiliPlay.cidOf(raw);
      final query = <String, Object?>{
        if (bvid.isNotEmpty) 'bvid': bvid else 'aid': aid,
        'cid': '$cid',
      };

      dynamic response;
      try {
        response = await BiliClient.shared.get(
          '/x/player/wbi/v2',
          query: query,
          auth: BiliAuth.accountSession,
        );
      } on SourceFailure {
        // WBI 签名 / 风控失败时退回 unsigned 账号接口；两条都失败由外层
        // catch 收口为 null。
        response = await BiliClient.shared.get(
          '/x/player/v2',
          query: query,
          auth: BiliAuth.account,
        );
      }

      final subtitle = _subtitleOf(response);
      if (subtitle == null) return null;
      final url = _subtitleUrlOf(subtitle['subtitle_url']);
      if (url == null) return null;

      // 字幕文件是没有业务码的静态 JSON：只复用匿名传输，不校验 code，
      // 也不带账号 Cookie。
      final body = await BiliClient.shared.get(
        url,
        codePolicy: BiliCodePolicy.none,
      );
      final lyric = _lrcOf(body);
      return lyric == null ? null : BuiltinLyricResult(lyric: lyric);
    } catch (_) {
      return null;
    }
  }

  /// 选轨：第一条可用中文轨；没有中文时取第一条有地址的字幕。
  static Map? _subtitleOf(dynamic response) {
    final data = response is Map ? response['data'] : null;
    final subtitle = data is Map ? data['subtitle'] : null;
    final list = subtitle is Map ? subtitle['subtitles'] : null;
    if (list is! List) return null;

    Map? fallback;
    for (final item in list) {
      if (item is! Map) continue;
      if (_subtitleUrlOf(item['subtitle_url']) == null) continue;
      if (_isChinese(item)) return item;
      fallback ??= item;
    }
    return fallback;
  }

  static bool _isChinese(Map item) {
    final lan = item['lan']?.toString().trim() ?? '';
    if (_chineseLans.contains(lan)) return true;
    return (item['lan_doc']?.toString() ?? '').contains('中文');
  }

  /// 字幕地址归一化：协议相对地址补 `https:`，空值视为不可用。
  static String? _subtitleUrlOf(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    return raw.startsWith('//') ? 'https:$raw' : raw;
  }

  /// `body[{from,content}]` → LRC：按开始时间排序，空行与空文本跳过。
  ///
  /// 同一条字幕里的换行按多行输出（时间相同），保留字幕自身的断行节奏；
  /// 先按字幕条目排序再拆行，避免同一时间戳的多行被排序打乱。
  static String? _lrcOf(dynamic body) {
    final list = body is Map ? body['body'] : null;
    if (list is! List || list.isEmpty) return null;

    final cues = <({double from, String content})>[];
    for (final item in list) {
      if (item is! Map) continue;
      final from = _secondsOf(item['from']);
      if (from == null) continue;
      cues.add((from: from, content: item['content']?.toString() ?? ''));
    }
    if (cues.isEmpty) return null;
    cues.sort((a, b) => a.from.compareTo(b.from));

    final buffer = StringBuffer();
    for (final cue in cues) {
      final time = msFormat((cue.from * 1000).round());
      for (final part in cue.content.split('\n')) {
        final text = part.trim();
        if (text.isEmpty) continue;
        buffer.writeln('$time$text');
      }
    }
    final lyric = buffer.toString().trim();
    return lyric.isEmpty ? null : lyric;
  }

  static double? _secondsOf(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}
