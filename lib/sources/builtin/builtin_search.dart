import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../source_search_result.dart';
import '../source_track.dart';
import 'kg_search.dart';
import 'kw_search.dart';
import 'mg_search.dart';
import 'tx_search.dart';
import 'wy_search.dart';

/// 内置平台搜索调度（与 lx-music 内置音源一致：kw/kg/tx/wy/mg）。
///
/// 说明：官方 LX 自定义源只负责取链（musicUrl/lyric/pic），搜索由宿主内置实现，
/// 因此这里把 lx-music 的平台搜索接口移植为 Dart，产出与 LX `musicInfo` 一致的
/// 结构，供自定义源脚本取链使用。
class BuiltinSearch {
  BuiltinSearch._();

  static const Map<String, String> platforms = {
    'kw': '酷我音乐',
    'kg': '酷狗音乐',
    'tx': 'QQ音乐',
    'wy': '网易音乐',
    'mg': '咪咕音乐',
  };

  static bool isBuiltin(String sourceKey) => platforms.containsKey(sourceKey);

  static String displayName(String sourceKey) => platforms[sourceKey] ?? sourceKey;

  static const Duration defaultTimeout = Duration(seconds: 15);

  static const Map<String, String> defaultHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
  };

  /// 分页搜索（返回曲目与 total/hasMore 等分页信息）。
  static Future<SourceSearchResult> searchWithMeta(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) {
    switch (sourceKey) {
      case 'kw':
        return KwSearch.searchWithMeta(keyword, page: page, limit: limit);
      case 'kg':
        return KgSearch.searchWithMeta(keyword, page: page, limit: limit);
      case 'tx':
        return TxSearch.searchWithMeta(keyword, page: page, limit: limit);
      case 'wy':
        return WySearch.searchWithMeta(keyword, page: page, limit: limit);
      case 'mg':
        return MgSearch.searchWithMeta(keyword, page: page, limit: limit);
      default:
        throw UnsupportedError('不支持的内置音源: $sourceKey');
    }
  }
}

/// 发起 GET 请求并解析 JSON。
Future<dynamic> lxHttpGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = BuiltinSearch.defaultTimeout,
}) async {
  final response = await http.get(
    Uri.parse(url),
    headers: {...BuiltinSearch.defaultHeaders, ...?headers},
  ).timeout(timeout);
  return _decodeBody(response);
}

/// 发起 GET 请求并返回文本（HTML 页面等非 JSON 响应）。
Future<String> lxHttpGetText(
  String url, {
  Map<String, String>? headers,
  Duration timeout = BuiltinSearch.defaultTimeout,
}) async {
  final response = await http.get(
    Uri.parse(url),
    headers: {...BuiltinSearch.defaultHeaders, ...?headers},
  ).timeout(timeout);
  return utf8.decode(response.bodyBytes, allowMalformed: true);
}

/// 发起 POST 请求并解析 JSON。
Future<dynamic> lxHttpPost(
  String url, {
  Map<String, String>? headers,
  Object? body,
  bool form = false,
  Duration timeout = BuiltinSearch.defaultTimeout,
}) async {
  final requestHeaders = {...BuiltinSearch.defaultHeaders, ...?headers};
  Object? encodedBody;
  if (form) {
    requestHeaders.putIfAbsent(
      'Content-Type',
      () => 'application/x-www-form-urlencoded',
    );
    if (body is Map) {
      encodedBody = body.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key.toString())}=${Uri.encodeQueryComponent(e.value.toString())}')
          .join('&');
    } else {
      encodedBody = body?.toString();
    }
  } else {
    requestHeaders.putIfAbsent('Content-Type', () => 'application/json');
    encodedBody = body is String ? body : jsonEncode(body);
  }
  final response = await http
      .post(Uri.parse(url), headers: requestHeaders, body: encodedBody)
      .timeout(timeout);
  return _decodeBody(response);
}

dynamic _decodeBody(http.Response response) {
  final text = utf8.decode(response.bodyBytes, allowMalformed: true);
  if (text.trim().isEmpty) {
    throw StateError('HTTP ${response.statusCode}: empty body');
  }
  try {
    return jsonDecode(text);
  } catch (_) {
    throw StateError('HTTP ${response.statusCode}: invalid JSON body');
  }
}

/// 从 `_types` 风格的数据构建音质列表。
List<SourceQuality> buildQualities(Map<String, Map<String, dynamic>> types) {
  final list = <SourceQuality>[];
  for (final type in kLxQualityOrder) {
    final info = types[type];
    if (info == null) continue;
    list.add(SourceQuality(
      type: type,
      size: info['size']?.toString(),
      hash: info['hash']?.toString(),
    ));
  }
  return list;
}
