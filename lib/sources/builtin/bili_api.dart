/// B 站匿名访问的会话层：buvid Cookie、WBI 签名与统一请求头。
///
/// 公开视频/音频接口都要求浏览器 UA + `Referer: https://www.bilibili.com/`，
/// WBI 接口还要求把参数按时间戳签名；这两件事一旦在各个业务文件里各写一份，
/// 密钥过期、Cookie 缺失与签名顺序漂移会散成难查的 412。这里收成唯一入口：
/// - [BiliSession] 是一次会话的快照（buvid + mixinKey）；
/// - [BiliApi.session] 负责 single-flight 拉取与 1 小时缓存；
/// - [biliSignQuery] 是纯函数，测试用官方文档给出的固定向量钉住算法。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/failure.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';

/// B 站接口错误（继承 [SourceFailure]，边界归一化无需二次转换）。
class BiliApiException extends SourceFailure {
  const BiliApiException({
    required super.kind,
    required super.message,
    super.l10nKey,
    super.cause,
    super.retryable = true,
    super.retryAfter,
  });
}

/// WBI 混淆表（B 站前端常量，顺序不可改）。
///
/// 64 个下标把 `imgKey + subKey` 重新排列，取前 32 位作为 mixinKey；
/// 少一位或顺序不同都会让所有 WBI 接口返回 -403。
const List<int> biliMixinKeyEncTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
  37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
  22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

/// WBI 要求剔除的字符（这些字符会被服务端按不同编码处理，直接删掉）。
final RegExp _wbiSensitiveChars = RegExp(r"[!'()*]");

/// 由 WBI 图片 URL 里的文件名（去 `.png`）拼出 mixinKey。
String biliMixinKey(String imgKey, String subKey) {
  final raw = '$imgKey$subKey';
  final buffer = StringBuffer();
  for (final index in biliMixinKeyEncTab) {
    if (index >= raw.length) break;
    buffer.write(raw[index]);
    if (buffer.length >= 32) break;
  }
  return buffer.toString();
}

/// WBI 签名（纯函数，供请求与测试共用）。
///
/// 顺序必须固定为：加 `wts` → 按键排序 → 值去掉 `!'()*` → URI 编码 →
/// 拼 query + mixinKey → md5 得 `w_rid`。任一步换序都会与 B 站服务端算出的
/// 签名不一致（-403）。
String biliSignQuery(
  Map<String, Object?> params,
  String mixinKey,
  int wts,
) {
  final values = <String, String>{
    for (final entry in params.entries)
      if (entry.value != null)
        entry.key: entry.value.toString().replaceAll(_wbiSensitiveChars, ''),
    'wts': '$wts',
  };
  final keys = values.keys.toList()..sort();
  final query =
      keys.map((key) => '$key=${Uri.encodeComponent(values[key]!)}').join('&');
  final wRid = md5Hex('$query$mixinKey');
  return '$query&w_rid=$wRid';
}

/// 一次 B 站匿名会话（Cookie + WBI 密钥快照）。
class BiliSession {
  const BiliSession({
    required this.buvid3,
    required this.buvid4,
    required this.mixinKey,
  });

  final String buvid3;
  final String buvid4;
  final String mixinKey;

  /// 普通接口请求头（搜索 / 播放地址 / 后续的评论等）。
  Map<String, String> get apiHeaders => {
        'User-Agent': BiliApi.browserUserAgent,
        'Referer': BiliApi.referer,
        'Cookie': 'buvid3=$buvid3; buvid4=$buvid4',
      };

  /// 给 URL 追加 WBI 签名参数（[wts] 仅测试注入，生产取当前秒）。
  String signUrl(
    String base,
    Map<String, Object?> params, {
    int? wts,
  }) {
    final timestamp = wts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final separator = base.contains('?') ? '&' : '?';
    return '$base$separator${biliSignQuery(params, mixinKey, timestamp)}';
  }
}

/// 会话获取的 single-flight + 缓存 + 刷新。
class BiliApi {
  BiliApi._();

  static const String baseUrl = 'https://api.bilibili.com';
  static const String referer = 'https://www.bilibili.com/';

  /// 浏览器 UA：B 站会拒绝 curl/python 等非浏览器 UA（-352 / 412）。
  static const String browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 音频直链只认 UA + Referer（不带 Cookie，避免把会话粘到播放器缓存）。
  static const Map<String, String> streamHeaders = {
    'User-Agent': browserUserAgent,
    'Referer': referer,
  };

  /// 不依赖 WBI / buvid 的匿名接口请求头（评论、榜单等）。
  ///
  /// 评论接口带 buvid Cookie 会返回「3 条热评 + is_end」的降级响应，必须
  /// 用不带 Cookie 的请求；这类接口也不需要 WBI 会话。
  static const Map<String, String> anonymousHeaders = {
    'User-Agent': browserUserAgent,
    'Referer': referer,
  };

  /// 会话有效期：WBI 密钥约一天轮换，1 小时刷新足够避开跨天失效。
  static const Duration sessionTtl = Duration(hours: 1);

  static BiliSession? _session;
  static DateTime? _fetchedAt;
  static Future<BiliSession>? _pending;

  /// 当前会话（缓存过期或未拉取时发起一次请求；并发调用共用同一 Future）。
  static Future<BiliSession> session() {
    final cached = _session;
    final fetchedAt = _fetchedAt;
    if (cached != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < sessionTtl) {
      return Future.value(cached);
    }
    return _pending ??= _startSessionFetch();
  }

  /// 丢弃缓存并重新拉取（-403/-412 风控后的唯一恢复手段）。
  static Future<BiliSession> refresh() {
    _session = null;
    _fetchedAt = null;
    return _pending ??= _startSessionFetch();
  }

  /// 测试隔离：清空缓存与在途请求。
  @visibleForTesting
  static void reset() {
    _session = null;
    _fetchedAt = null;
    _pending = null;
  }

  static Future<BiliSession> _startSessionFetch() {
    final future = _fetchSession().then((session) {
      _session = session;
      _fetchedAt = DateTime.now();
      return session;
    });
    _pending = future;
    // 失败也要清掉在途引用，否则下一次调用会永远复用同一个失败 Future。
    void clearPending() {
      if (identical(_pending, future)) _pending = null;
    }

    future.then<void>(
      (_) => clearPending(),
      onError: (Object _, StackTrace __) => clearPending(),
    );
    return future;
  }

  static Future<BiliSession> _fetchSession() async {
    final baseHeaders = {
      'User-Agent': browserUserAgent,
      'Referer': referer,
    };
    final spi = await BuiltinSearch.transport.getJson(
      '$baseUrl/x/frontend/finger/spi',
      headers: baseHeaders,
    );
    final spiData = _dataOf(spi);
    final buvid3 =
        spiData is Map ? spiData['b_3']?.toString().trim() ?? '' : '';
    final buvid4 =
        spiData is Map ? spiData['b_4']?.toString().trim() ?? '' : '';
    if (buvid3.isEmpty) {
      throw const BiliApiException(
        kind: FailureKind.unknown,
        message: 'bili: 获取 buvid 失败',
      );
    }

    final nav = await BuiltinSearch.transport.getJson(
      '$baseUrl/x/web-interface/nav',
      headers: {
        ...baseHeaders,
        'Cookie': 'buvid3=$buvid3; buvid4=$buvid4',
      },
    );
    // 未登录时 code 为 -101，但 data.wbi_img 仍然返回（匿名访问的正常分支）。
    final code = _codeOf(nav);
    if (code != 0 && code != -101) {
      throw BiliApiException(
        kind: FailureKind.unknown,
        message: 'bili: 获取 WBI 密钥失败（code=$code）',
      );
    }
    final wbi = _dataOf(nav) is Map ? (_dataOf(nav) as Map)['wbi_img'] : null;
    final imgUrl = wbi is Map ? wbi['img_url']?.toString() ?? '' : '';
    final subUrl = wbi is Map ? wbi['sub_url']?.toString() ?? '' : '';
    final imgKey = _wbiKeyOf(imgUrl);
    final subKey = _wbiKeyOf(subUrl);
    if (imgKey.isEmpty || subKey.isEmpty) {
      throw const BiliApiException(
        kind: FailureKind.unknown,
        message: 'bili: WBI 密钥为空',
      );
    }

    return BiliSession(
      buvid3: buvid3,
      buvid4: buvid4,
      mixinKey: biliMixinKey(imgKey, subKey),
    );
  }

  /// `https://i0.hdslb.com/bfs/wbi/abc123.png` → `abc123`。
  static String _wbiKeyOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final name = path.split('/').last;
    final dot = name.indexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  /// 从响应里读业务码（非 Map 返回 null）。
  static int? codeOf(dynamic response) => _codeOf(response);

  static int? _codeOf(dynamic response) {
    if (response is! Map) return null;
    final code = response['code'];
    if (code is int) return code;
    if (code is num) return code.toInt();
    return int.tryParse('$code');
  }

  static dynamic _dataOf(dynamic response) =>
      response is Map ? response['data'] : null;

  /// 风控码：需要刷新会话后重试。
  static bool isRiskControl(int? code) => code == -403 || code == -412;

  /// 业务失败 → [SourceFailure]（-404 归 notFound，其余按可重试 unknown）。
  static SourceFailure failureForCode(int code, {String? message}) {
    if (code == -404) {
      return BiliApiException(
        kind: FailureKind.notFound,
        message: message ?? 'bili: 内容不存在（code=-404）',
        retryable: false,
      );
    }
    return BiliApiException(
      kind: FailureKind.unknown,
      message: message ?? 'bili: 接口拒绝（code=$code）',
      retryable: true,
    );
  }
}
