/// 汽水音乐（`qs`）匿名接口的共享传输与解析约定。
///
/// 端点分三类：
/// - **PC 接口**（`api.qishui.com/luna/search/*`、`/luna/pc/comments`、
///   `/luna/playlist/detail`）：`LunaPC` UA + 一组固定的设备参数；
/// - **App 接口**（`/luna/discover/mix`）：`Luna` UA + JSON body；
/// - **分享页 SSR**（`www.qishui.com/share/{track,album,artist,playlist}`）：
///   HTML 里的 `_ROUTER_DATA` 是一次性完整快照，专辑 / 歌手 / 歌单详情只走这里。
///
/// 平台会概率性地返回 `200` + 空 body（实测约半数请求），这不是「没有结果」，
/// 因此所有请求都经 [QsApi] 的空响应重试；正常的空结果由调用方按业务解读。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'builtin_search.dart';
import 'builtin_transport.dart';

abstract final class QsApi {
  static const String pcHost = 'https://api.qishui.com';
  static const String shareHost = 'https://www.qishui.com';

  /// PC 客户端的 UA：搜索 / 评论 / 歌单接口按这个客户端校验参数组合。
  static const String pcUserAgent = 'LunaPC/3.0.0(290101097)';

  /// 分享页只需要一个普通浏览器 UA。
  static const String webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36';

  /// App 接口（发现页）的 UA。
  static const String appUserAgent = 'Luna/19.1.0 Android';

  static const int defaultTries = 3;

  /// 搜索接口的空响应更频繁，多给两次机会。
  static const int searchTries = 5;

  static final math.Random _random = math.Random.secure();

  /// 设备参数只生成一次：每请求换设备号会被平台当成新设备。
  static final String _deviceId = _randomDigits(16);
  static final String _installId = _randomDigits(16);

  static Map<String, String> _pcHeaders() => const {
    'User-Agent': pcUserAgent,
    'Content-Type': 'application/json; charset=utf-8',
  };

  static Map<String, String> _appHeaders() => const {
    'User-Agent': appUserAgent,
    'Content-Type': 'application/json; charset=utf-8',
  };

  /// PC 接口的固定参数（缺一个都会被判 `ERR_INVALID_PARAM`）。
  static Map<String, Object?> get _pcParams => {
    'aid': '386088',
    'app_name': 'luna_pc',
    'region': 'cn',
    'geo_region': 'cn',
    'os_region': 'cn',
    'sim_region': '',
    'device_id': _deviceId,
    'cdid': '',
    'iid': _installId,
    'version_name': '3.0.0',
    'version_code': '30000000',
    'channel': 'official',
    'build_mode': 'master',
    'network_carrier': '',
    'ac': 'wifi',
    'tz_name': 'Asia/Shanghai',
    'resolution': '',
    'device_platform': 'windows',
    'device_type': 'Windows',
    'os_version': 'Windows 11',
    'fp': _deviceId,
  };

  /// GET + JSON。空 body（平台概率性丢弃）与传输异常都按次数重试。
  static Future<dynamic> getJson(
    String path, {
    Map<String, Object?> query = const {},
    int tries = defaultTries,
  }) {
    final uri = Uri.parse('$pcHost$path').replace(
      queryParameters: {
        for (final entry in {..._pcParams, ...query}.entries)
          entry.key: '${entry.value}',
      },
    );
    return _withEmptyRetry(
      tries: tries,
      send: () => lxHttpGet(uri.toString(), headers: _pcHeaders()),
    );
  }

  /// POST + JSON body（发现页接口）。
  static Future<dynamic> postJson(
    String path,
    Object body, {
    int tries = defaultTries,
  }) {
    return _withEmptyRetry(
      tries: tries,
      send: () =>
          lxHttpPost('$pcHost$path', headers: _appHeaders(), body: body),
    );
  }

  /// 分享页 SSR：抓 HTML 并取出 `_ROUTER_DATA.loaderData`。
  ///
  /// 页面结构变化 / 缺 marker 时抛 [BuiltinHttpException]，与传输失败同一条
  /// 重试路径（分享页偶发返回不完整快照）。
  static Future<Map<String, dynamic>> shareLoaderData(
    String path,
    Map<String, String> query, {
    int tries = defaultTries,
  }) async {
    final uri = Uri.https('www.qishui.com', path, query);
    final html = await _withEmptyRetry(
      tries: tries,
      send: () => lxHttpGetText(
        uri.toString(),
        headers: const {'User-Agent': webUserAgent},
      ),
    );
    final loader = _loaderDataOf(html);
    if (loader == null) {
      throw BuiltinHttpException('qs: 分享页缺少 _ROUTER_DATA（$path）');
    }
    return loader;
  }

  static Future<T> _withEmptyRetry<T>({
    required int tries,
    required Future<T> Function() send,
  }) async {
    final maxTries = tries < 1 ? 1 : tries;
    Object? lastError;
    for (var attempt = 0; attempt < maxTries; attempt++) {
      if (attempt > 0) {
        await (BuiltinTransport.retryDelayOverride ??
            BuiltinTransport.retryBackoff)(attempt);
      }
      try {
        return await send();
      } on BuiltinHttpException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? BuiltinHttpException('qs: 请求失败');
  }

  /// 从分享页 HTML 取 `loaderData`（`_ROUTER_DATA = {...}` 的 JSON 对象）。
  static Map<String, dynamic>? _loaderDataOf(String html) {
    const marker = '_ROUTER_DATA = ';
    final index = html.indexOf(marker);
    if (index < 0) return null;
    final start = html.indexOf('{', index + marker.length);
    if (start < 0) return null;
    final text = _balancedJsonAt(html, start);
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final loader = decoded['loaderData'];
      return loader is Map ? Map<String, dynamic>.from(loader) : null;
    } on FormatException {
      return null;
    }
  }

  /// 从 [start] 的 `{` 起按字符串 / 转义规则找到配对的 `}`。
  static String? _balancedJsonAt(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = start; index < text.length; index++) {
      final char = text.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == 0x5C) {
          escaped = true;
        } else if (char == 0x22) {
          inString = false;
        }
        continue;
      }
      if (char == 0x22) {
        inString = true;
      } else if (char == 0x7B) {
        depth++;
      } else if (char == 0x7D) {
        depth--;
        if (depth == 0) return text.substring(start, index + 1);
      }
    }
    return null;
  }

  static String _randomDigits(int length) {
    final buffer = StringBuffer();
    for (var index = 0; index < length; index++) {
      buffer.write(_random.nextInt(10));
    }
    return buffer.toString();
  }
}
