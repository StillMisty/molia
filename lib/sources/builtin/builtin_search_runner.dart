/// 内置平台检索的执行骨架（唯一实现）。
///
/// 五个平台此前各自重抄同一段「构造请求 → 响应级重试 → 非法响应塌成
/// empty → fromPage(...)」；现在变体面（请求、响应判定、解析、总数）收进
/// [BuiltinSearchCall]，骨架与策略（重试预算、空/失败语义、分页推断）只在
/// 这里写一次。
///
/// 语义分界（[SourceSearchResult]）：
/// - **平台返回空**：响应合法但没有结果 → 正常结果（tracks 为空、failure 空）；
/// - **失败**：传输异常（含重试耗尽）或平台业务拒绝 → [SourceSearchResult.failed]
///   （不抛异常；调用方按需消费 failure）。
library;

import '../../domain/models/failure.dart';
import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';

/// 请求方式（POST 的 JSON / 表单编码由 [BuiltinSearchCall.form] 表达）。
enum BuiltinSearchMethod { get, post }

/// 一次内置平台检索的公共变体面：请求 + 响应级重试 + 业务码判定。
///
/// 搜索（[BuiltinSearchCall]）与歌词检索（`BuiltinLyricSearchCall`）共用；
/// 两侧的骨架步骤（发送 / 非法响应归一化）收在 [sendBuiltinCall]。
class BuiltinCall {
  BuiltinCall({
    required this.platform,
    this.method = BuiltinSearchMethod.get,
    required this.url,
    this.headers,
    this.body,
    this.form = false,
    this.retries = BuiltinTransport.defaultRetries,
    bool Function(dynamic response)? retryIf,
    required this.isInvalid,
  }) : retryIf = retryIf ?? isInvalid;

  /// 平台键（错误文案用）。
  final String platform;

  final BuiltinSearchMethod method;
  final String url;
  final Map<String, String>? headers;
  final Object? body;
  final bool form;

  /// 统一重试预算（含首次尝试）：平台搜索共用同一策略。
  final int retries;

  /// 响应级重试判定（平台偶发「总数非 0 但本页为空」/业务码抖动）；
  /// 未显式给出时与 [isInvalid] 同判定（业务拒绝即重试）。
  final bool Function(dynamic response) retryIf;

  /// 响应非法（平台业务拒绝或结构不符）：判为失败，而不是「没有结果」。
  final bool Function(dynamic response) isInvalid;

  /// 经注入的传输实例发起请求（测试注入 `MockClient` 即覆盖本路径）。
  Future<dynamic> send(BuiltinTransport transport) {
    switch (method) {
      case BuiltinSearchMethod.get:
        return transport.getJson(
          url,
          headers: headers,
          retries: retries,
          retryIf: retryIf,
        );
      case BuiltinSearchMethod.post:
        return transport.postJson(
          url,
          headers: headers,
          body: body,
          form: form,
          retries: retries,
          retryIf: retryIf,
        );
    }
  }
}

/// 一次检索的骨架一步：发送 + 非法响应归一化。
///
/// 返回 `(response, failure)`：失败时 response 为 null（传输异常或业务拒绝），
/// 由各 runner 决定失败形态（搜索：`SourceSearchResult.failed`；歌词：抛出）。
Future<({dynamic response, SourceFailure? failure})> sendBuiltinCall(
  BuiltinCall call,
) async {
  final dynamic response;
  try {
    response = await call.send(BuiltinSearch.transport);
  } catch (error) {
    return (response: null, failure: SourceFailure.from(error));
  }
  if (call.isInvalid(response)) {
    return (
      response: null,
      failure: SourceFailure(
        kind: FailureKind.unknown,
        message: '${call.platform}: 搜索响应非法',
        retryable: true,
      ),
    );
  }
  return (response: response, failure: null);
}

/// 一次搜索的变体面：请求 + 响应判定 + 解析（见 [BuiltinCall]）。
class BuiltinSearchCall extends BuiltinCall {
  BuiltinSearchCall({
    required super.platform,
    super.method,
    required super.url,
    super.headers,
    super.body,
    super.form,
    super.retries,
    super.retryIf,
    required super.isInvalid,
    required this.parseItems,
    this.totalOf,
  });

  /// 响应 → 曲目（含平台各自的列表路径）；返回 null 表示响应合法但没有结果页
  /// （按「平台返回空」处理：不带 total/hasMore——如酷狗 `lists` 缺失）。
  final List<SourceTrack>? Function(dynamic response) parseItems;

  /// 响应 → 结果总数（平台只在部分页返回时返回 null）。
  final int? Function(dynamic response)? totalOf;
}

/// 执行一次平台检索：异常与业务拒绝归一为失败结果，「平台返回空」保持正常。
Future<SourceSearchResult> runBuiltinSearch(
  BuiltinSearchCall call, {
  required int page,
  required int limit,
}) async {
  final result = await sendBuiltinCall(call);
  final failure = result.failure;
  if (failure != null) return SourceSearchResult.failed(failure);

  final tracks = call.parseItems(result.response);
  if (tracks == null) return SourceSearchResult.empty;
  return SourceSearchResult.fromPage(
    tracks: tracks,
    page: page,
    limit: limit,
    total: call.totalOf?.call(result.response),
  );
}
