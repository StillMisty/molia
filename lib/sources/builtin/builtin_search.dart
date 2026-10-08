import 'dart:async';

import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_transport.dart';
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

  /// 内置请求传输：测试注入 `MockClient` 覆盖 fetch 路径（唯一入口）。
  static BuiltinTransport transport = BuiltinTransport();

  // 兼容别名：发现适配器仍直接引用（与传输层同一常量）。
  static const Duration defaultTimeout = BuiltinTransport.defaultTimeout;
  static const Map<String, String> defaultHeaders =
      BuiltinTransport.defaultHeaders;

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

/// 发起 GET 请求并解析 JSON（传输统一入口；[retryIf] 为响应级重试判定）。
Future<dynamic> lxHttpGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = BuiltinTransport.defaultTimeout,
  int retries = 1,
  bool Function(dynamic json)? retryIf,
}) {
  return BuiltinSearch.transport.getJson(
    url,
    headers: headers,
    timeout: timeout,
    retries: retries,
    retryIf: retryIf,
  );
}

/// 发起 GET 请求并返回文本（HTML 页面等非 JSON 响应）。
Future<String> lxHttpGetText(
  String url, {
  Map<String, String>? headers,
  Duration timeout = BuiltinTransport.defaultTimeout,
}) {
  return BuiltinSearch.transport.getText(
    url,
    headers: headers,
    timeout: timeout,
  );
}

/// 发起 POST 请求并解析 JSON（表单或 JSON body）。
Future<dynamic> lxHttpPost(
  String url, {
  Map<String, String>? headers,
  Object? body,
  bool form = false,
  Duration timeout = BuiltinTransport.defaultTimeout,
  int retries = 1,
  bool Function(dynamic json)? retryIf,
}) {
  return BuiltinSearch.transport.postJson(
    url,
    headers: headers,
    body: body,
    form: form,
    timeout: timeout,
    retries: retries,
    retryIf: retryIf,
  );
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
