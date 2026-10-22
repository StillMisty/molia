import 'dart:async';
import 'dart:typed_data';

import '../../domain/models/failure.dart';
import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_platforms.dart';
import 'builtin_transport.dart';

/// 内置平台搜索调度（与 lx-music 内置音源一致：tx/wy/kg/kw/mg）。
///
/// 说明：官方 LX 自定义源只负责取链（musicUrl/lyric/pic），搜索由宿主内置实现，
/// 因此这里把 lx-music 的平台搜索接口移植为 Dart，产出与 LX `musicInfo` 一致的
/// 结构，供自定义源脚本取链使用。
class BuiltinSearch {
  BuiltinSearch._();

  /// 平台展示名（键顺序同 [BuiltinPlatforms.keys]）。
  ///
  /// 保留该名字是为了兼容既有调用点；矩阵本体在 [BuiltinPlatforms]。
  static final Map<String, String> platforms = BuiltinPlatforms.displayNames;

  static bool isBuiltin(String sourceKey) =>
      BuiltinPlatforms.isSupported(sourceKey);

  static String displayName(String sourceKey) =>
      BuiltinPlatforms.displayName(sourceKey);

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
    final adapter = BuiltinPlatforms.searchFor(sourceKey);
    if (adapter == null) {
      throw UnsupportedError('不支持的内置音源: $sourceKey');
    }
    return adapter(keyword, page: page, limit: limit);
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

/// 发起 GET 请求并返回原始字节（二进制歌词响应）。
Future<Uint8List> lxHttpGetBytes(
  String url, {
  Map<String, String>? headers,
  Duration timeout = BuiltinTransport.defaultTimeout,
  int retries = 1,
}) {
  return BuiltinSearch.transport.getBytes(
    url,
    headers: headers,
    timeout: timeout,
    retries: retries,
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

/// 平台业务拒绝 / 缺少字段的统一失败（可重试：多为平台抖动或字段缺失）。
///
/// 专辑 / 歌手 / 歌词等内置平台接口共用同一口径；各模块的旧助手
/// （`albumPlatformFailure` / `artistPlatformFailure`）保留名字并委托到这里。
SourceFailure builtinPlatformFailure(String platform, String reason) =>
    SourceFailure(
      kind: FailureKind.unknown,
      message: '$platform: $reason',
      retryable: true,
    );

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
