import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 应用统一的 Dio 构造入口，所有 HTTP 调用点都从这里取实例。
///
/// 为什么必须统一而不是各处 `Dio()`：
/// - dio 默认对非 2xx 抛 `DioException`，而各调用点都在读状态码做业务分支
///   （QQ 403/404 换域名重试、WebDAV 的 MKCOL/PUT 成败、LLM 的 401/429 文案…），
///   所以这里放开 `validateStatus`，统一「状态码是数据、不是异常」的约定。
/// - 响应体固定按字节取，配合 [bodyBytes] / [bodyText] 自行解码：空 body、
///   非法 JSON、非 UTF-8 的处理各调用点都有自己的语义，不交给 dio 的
///   自动 JSON 解码。
/// - 超时仍由调用点的 `Future.timeout` 负责：dio 的 connect/send/receive
///   是分段超时，与「整次请求一个截止时间」的旧语义不同，不在这里设。
Dio createAppDio({HttpClientAdapter? adapter}) {
  final dio = Dio(
    BaseOptions(
      validateStatus: (status) => status != null,
      responseType: ResponseType.bytes,
      followRedirects: true,
      maxRedirects: 5,
    ),
  );
  if (adapter != null) {
    dio.httpClientAdapter = adapter;
  }
  return dio;
}

/// 响应状态码的非空读取。
///
/// dio 的 `Response.statusCode` 是 `int?`——只有连接层失败（抛 [DioException]）
/// 时才为 null；本仓库统一放开 `validateStatus`，能走到调用点的响应必有状态码。
/// 用本扩展替代满屏的 `!`。
extension AppHttpResponse on Response<dynamic> {
  int get httpStatus => statusCode ?? 0;
}

/// 响应体字节（[createAppDio] 固定 `ResponseType.bytes`）。
Uint8List bodyBytes(Response<dynamic> response) {
  final data = response.data;
  if (data is Uint8List) return data;
  if (data is List<int>) return Uint8List.fromList(data);
  return Uint8List(0);
}

/// 响应体文本（UTF-8，容忍非法字节：平台接口偶有混合编码响应）。
String bodyText(Response<dynamic> response) =>
    utf8.decode(bodyBytes(response), allowMalformed: true);

/// 响应头扁平化为单值表（同名多值用逗号连接）。
///
/// `lx_engine_native` 会把响应头原样交给音源脚本，脚本按 `headers['content-type']`
/// 这类单值读取，所以要拍平，不能直接暴露 dio 的 `Map<String, List<String>>`。
Map<String, String> flatResponseHeaders(Response<dynamic> response) => response
    .headers
    .map
    .map((key, value) => MapEntry(key, value.join(',')));

/// 流式响应体（请求时显式传 `ResponseType.stream`）。
ResponseBody streamBody(Response<dynamic> response) =>
    response.data as ResponseBody;
