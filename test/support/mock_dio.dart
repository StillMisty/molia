import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:molia/data/http/app_dio.dart';

/// `Dio` 的测试替身：用「请求 → 响应」回调驱动，测试只关心
/// 「命中哪个 URL、发了什么、回什么」。
///
/// 拦截点是 `HttpClientAdapter`（真实 socket 之前），因此不依赖
/// `HttpOverrides`，也不会真的发包；`flutter_test` 里可直接注入
/// `Dio(...)..httpClientAdapter = MockDioAdapter(...)`。
class MockDioAdapter implements HttpClientAdapter {
  MockDioAdapter(this.handler);

  /// 返回 [ResponseBody]（用 [textResponse] / [bytesResponse] 构造）。
  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

  /// 依次记录收到的请求，便于断言 URL / 请求头 / body。
  final List<RequestOptions> requests = [];

  /// 最近一次请求。
  RequestOptions get lastRequest => requests.last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return await handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// 文本响应（UTF-8 字节；dio 在 `ResponseType.bytes` 下不做 charset 猜测，
/// 因此不像 `http.Response(String)` 那样有 latin1 陷阱）。
ResponseBody textResponse(
  String body, {
  int statusCode = 200,
  Map<String, List<String>> headers = const {},
  String? statusMessage,
}) =>
    ResponseBody.fromString(
      body,
      statusCode,
      headers: headers,
      statusMessage: statusMessage,
    );

/// 字节响应（二进制接口 / 非法 UTF-8 场景）。
ResponseBody bytesResponse(
  List<int> bytes, {
  int statusCode = 200,
  Map<String, List<String>> headers = const {},
  String? statusMessage,
}) =>
    ResponseBody.fromBytes(
      bytes,
      statusCode,
      headers: headers,
      statusMessage: statusMessage,
    );

/// 从 [RequestOptions] 里取请求体文本。
///
/// dio 不会改写 `options.data`（`_transformData` 只读它），所以调用点传进去的
/// String / Map 在这里原样可读；非 String 的按 JSON 编码返回，便于断言。
String requestBodyText(RequestOptions options) {
  final data = options.data;
  if (data == null) return '';
  if (data is String) return data;
  return data.toString();
}

/// 便捷构造：直接拿到一个注入了 [MockDioAdapter] 的 `Dio`。
Dio mockDio(FutureOr<ResponseBody> Function(RequestOptions options) handler) =>
    createAppDio(adapter: MockDioAdapter(handler));
